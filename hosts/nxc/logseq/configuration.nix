{ config, pkgs, modulesPath, inputs, outputs, ... }:

let
  # One definition of "the newest dump is healthy", used both by the 06:00 unit and
  # by the endpoint an external monitor polls, so the two can never disagree about
  # what a failure looks like. Exits 0 and prints "ok: <dump> (<n>h old)", or exits
  # non-zero with the reason on the first line of stderr.
  backupCheck = pkgs.writeShellScript "logseq-sync-backup-check" ''
    set -euo pipefail

    root=/var/lib/logseq-sync/backups
    # The dump runs at 00:30 local and the scheduled check at 06:00: last night's
    # dump is 4.5-6.5h old there, the one before it at least 28.5h. A check run late
    # by Persistent sees at most 25h, so 27h fails a single missed night and nothing
    # healthy.
    max_age_h=27

    newest=$(find "$root" -mindepth 1 -maxdepth 1 -type d \
               -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' \
               -printf '%f\n' | sort -r | head -1)
    if [ -z "$newest" ]; then
      echo "no dump in $root" >&2
      exit 1
    fi

    # Age comes from the name, not the mtime: opening an old dump moves its mtime.
    iso=$(printf '%s' "$newest" | sed -E \
      's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6Z/')
    age_s=$(( $(date +%s) - $(date -d "$iso" +%s) ))
    age=$(( age_s / 3600 ))
    # A stamp from the future means the clock moved. It also sorts above every real
    # dump, so retention never prunes it and it would read as fresh indefinitely.
    if [ "$age_s" -lt -300 ]; then
      echo "newest dump is stamped in the future: $newest" >&2
      exit 1
    fi
    if [ "$age_s" -gt $(( max_age_h * 3600 )) ]; then
      echo "newest dump is ''${age}h old: $newest" >&2
      exit 1
    fi

    # The glob guard below is for an empty graphs/ directory; without this the index
    # would be skipped too and an empty dump would pass.
    if [ ! -s "$root/$newest/index.sqlite" ]; then
      echo "no index in $root/$newest" >&2
      exit 1
    fi

    for db in "$root/$newest/index.sqlite" "$root/$newest"/graphs/*.sqlite; do
      [ -e "$db" ] || continue
      # Capture sqlite's own complaint too: on a corrupted file it refuses before
      # printing a result, and that message does not name the file.
      if ! result=$(${pkgs.sqlite}/bin/sqlite3 -bail "file:$db?mode=ro" 'pragma integrity_check;' 2>&1); then
        echo "cannot read $db: $result" >&2
        exit 1
      fi
      if [ "$result" != "ok" ]; then
        echo "integrity check failed for $db: $result" >&2
        exit 1
      fi
    done

    echo "ok: $newest (''${age}h old)"
  '';

  # The endpoint the external monitor polls. It runs the same check on request rather
  # than caching, so the answer is never older than the moment it was asked for, and
  # it maps the result onto HTTP: 200 with "ok: …" when the dump is healthy, 503 with
  # "down: …" and the reason when it is not. Every request costs one integrity check
  # of two small databases, which is milliseconds.
  #
  # It binds to the LAN address only, and the firewall admits one source: the monitor
  # host. Nothing here holds a credential, so there is no token to rotate or leak.
  backupStatus = pkgs.writeScript "logseq-backup-status" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import subprocess
    import sys

    BIND = "192.168.86.141"
    PORT = 8089
    CHECK = "${backupCheck}"

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "logseq-backup-status"
        # A half-open connection (the monitor host rebooting mid-request) would
        # otherwise hold a thread forever.
        timeout = 30

        def do_GET(self):
            if self.path.split("?", 1)[0] not in ("/", "/status"):
                self.send_error(404)
                return
            try:
                done = subprocess.run([CHECK], capture_output=True, text=True,
                                      errors="replace", timeout=60)
                healthy = done.returncode == 0
                # Success: the check's own "ok: ..." line, without repeating the prefix.
                # Failure: the first stderr line is the check's message naming the file;
                # sqlite's own complaint can run to many lines after it.
                if healthy:
                    lines = done.stdout.strip().splitlines()
                    detail = lines[-1].removeprefix("ok: ") if lines else "no output"
                else:
                    lines = done.stderr.strip().splitlines()
                    detail = lines[0] if lines else "exit %d, no output" % done.returncode
            except Exception as exc:  # noqa: BLE001 - the monitor wants a reason
                detail, healthy = "check failed to run: %s" % exc, False
            body = ("ok: " if healthy else "down: ") + detail + "\n"
            payload = body.encode()
            self.send_response(200 if healthy else 503)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, fmt, *args):
            sys.stderr.write("status: " + fmt % args + "\n")

    http.server.ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
  '';
in
{
  imports = [
    # Autogenerated configuration specific to the iso, and not included in repo
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # Host name and address come from Proxmox, not from this file: the pinned LXC
  # module defaults manageNetwork and manageHostName to false and then forces
  # networking.hostName to the empty string inside that branch, so a hostName
  # set here would be silently ignored. Assigned at creation: name logseq,
  # 192.168.86.141/24 (VMID 141, last octet matches the VMID), gateway
  # 192.168.86.1, outside the .210-.254 DHCP pool.

  environment.systemPackages = with pkgs; [
    sqlite
  ];

  extra-services.tailscale = {
    enable = true;
    lxc = true;
  };
  extra-services.host-checkin.enable = true;

  services.openssh.enable = true;

  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # Self-hosted Logseq sync server: the community packaging of Logseq's own
  # deps/db-sync Node adapter. One container holding SQLite metadata plus a
  # filesystem asset store. Pinned by tag AND digest: the image publishes weekly
  # builds under dated tags and no semver releases, so the digest is what makes a
  # bump deliberate. Deliberately no --pull=always, which exists to follow a
  # moving tag; this image is frozen until someone decides otherwise.
  virtualisation.oci-containers = {
    backend = "podman";

    containers.logseq-sync = {
      image = "ghcr.io/yshalsager/logseq-selfhost-sync:20261115-69da7e2@sha256:edd664f49cf82801d6063f9ac1171feb2e2baae071448726603fa28c5e2c118e";

      volumes = [
        "/var/lib/logseq-sync/data:/app/data"
      ];

      environment = {
        DB_SYNC_PORT = "8787";
        # This is baked into the asset links the clients fetch, so it must equal
        # the URL clients are configured with. Changing it means re-pointing
        # every synced device.
        DB_SYNC_BASE_URL = "https://logseq.montycasa.com";
        DB_SYNC_DATA_DIR = "/app/data";
        DB_SYNC_STORAGE_DRIVER = "sqlite";
        DB_SYNC_ASSETS_DRIVER = "filesystem";
        DB_SYNC_LOG_LEVEL = "info";

        # Clients authenticate against Logseq's own identity pool. These are
        # public identifiers, not secrets, and they are restated here so that a
        # rotation shows up as a visible change rather than a silent image drift.
        COGNITO_ISSUER = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8";
        COGNITO_CLIENT_ID = "69cs1lgme7p8kbgld8n5kseii6";
        COGNITO_JWKS_URL = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8/.well-known/jwks.json";
      };

      extraOptions = [
        # Host networking so the listener is a normal host socket behind INPUT:
        # nixos-fw admits 8787 on eth0 only from the LAN (see below), and ts-input
        # accepts tailscale0. A published port instead of this would be DNATed
        # through the podman bridge, which does not pass through INPUT at all.
        # Precedent for host networking on an LXC: hosts/nxc/paperless-ngx.
        "--network=host"
        "--read-only"
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        # The image runs as this uid/gid; the data directory is chowned to match.
        "--user=65532:65532"
        # The memory controller is delegated into this container, so the cap is
        # enforced by cgroup v2 rather than refused by the runtime.
        "--memory=512m"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/logseq-sync 0750 root root -"
    "d /var/lib/logseq-sync/data 0750 65532 65532 -"
    "d /var/lib/logseq-sync/backups 0750 root root -"
  ];

  # A consistent logical copy of the sync data every night, half an hour before the
  # Proxmox snapshot runs over this guest. Both databases run in WAL mode, so the
  # files are copied through sqlite's own backup path rather than with cp: a plain
  # copy of a live WAL database can be torn, while `.backup` takes a consistent
  # snapshot of it.
  #
  # This is not a substitute for the Proxmox backup, which is retried, deduplicated
  # and off-host. It is the thing that proves the data is readable: every copy is put
  # through an integrity check here, so a corrupt source fails tonight instead of on
  # the day someone restores it, and each dumped database is self-contained enough to
  # open without this container.
  #
  # Assets are hard-linked rather than copied. They are content-addressed blobs the
  # service only ever adds, so a link costs no space, survives the service deleting
  # the original, and stays inside the retention window. If they are ever rewritten
  # in place, this stops being a backup of them and has to become a copy.
  #
  # A directory named like a dump is only ever produced by a run that passed every
  # check: the work happens in a dot-directory that is renamed into place at the end,
  # so a dump left half-written can never be mistaken for a good one.
  systemd.services.logseq-sync-backup = {
    description = "Consistent dump of the Logseq sync data";
    path = [ pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      # The index carries key material.
      UMask = "0077";
      # Without this a hung run stays "activating" forever and every later timer
      # firing is a no-op, so backups would stop silently. Fails well before 01:00.
      TimeoutStartSec = "25min";
      ExecStart = pkgs.writeShellScript "logseq-sync-backup" ''
        set -euo pipefail

        src=/var/lib/logseq-sync/data
        root=/var/lib/logseq-sync/backups
        keep=14
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        out="$root/$stamp"
        tmp="$root/.partial-$stamp"

        rm -rf "$root"/.partial-*
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$tmp/graphs"

        sql() {
          # No busy timeout by default, so a checkpoint at the wrong moment would
          # fail the run; ride it out instead.
          ${pkgs.sqlite}/bin/sqlite3 -bail -cmd '.timeout 30000' "$@"
        }

        dump() {
          # sqlite3 happily creates a database at a path that does not exist, and an
          # empty database passes integrity_check, so a missing source is fatal here
          # rather than a silently empty dump.
          if [ ! -s "$1" ]; then
            echo "source missing or empty: $1" >&2
            exit 1
          fi
          sql "$1" ".backup '$2'"
          # The copy inherits the WAL flag, which makes opening it need write access
          # next to it. Rewriting the header makes it a standalone file.
          sql "$2" 'pragma journal_mode=delete;' > /dev/null
        }

        check() {
          result=$(sql "$1" 'pragma integrity_check;')
          if [ "$result" != "ok" ]; then
            echo "integrity check failed for $1: $result" >&2
            exit 1
          fi
          tables=$(sql "$1" 'select count(*) from sqlite_master;')
          if [ "$tables" -eq 0 ]; then
            echo "no schema in $1" >&2
            exit 1
          fi
          # Name the file as it will be once the dump is renamed into place, not the
          # partial path it lives at while being checked.
          echo "ok: ''${1#"$tmp/"}"
        }

        # Graph directories, by name, so a graph is dumped or the run fails: the
        # previous glob silently skipped any directory without a database in it.
        graphs() {
          if [ -d "$src/graphs" ]; then
            find "$src/graphs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
          fi
        }

        before=$(graphs)
        dump "$src/index.sqlite" "$tmp/index.sqlite"
        n=0
        for graph in $before; do
          dump "$src/graphs/$graph/db.sqlite" "$tmp/graphs/$graph.sqlite"
          n=$((n + 1))
        done
        # Index and graphs are separate files taken one after another. If the set of
        # graphs moved in between they are not one moment, so leave it to tomorrow.
        if [ "$(graphs)" != "$before" ]; then
          echo "graph set changed during the dump" >&2
          exit 1
        fi

        if [ -d "$src/assets" ]; then
          cp -al "$src/assets" "$tmp/assets"
        else
          echo "no assets directory yet"
        fi

        check "$tmp/index.sqlite"
        for db in "$tmp"/graphs/*.sqlite; do
          [ -e "$db" ] || continue
          check "$db"
        done

        mv -T "$tmp" "$out"
        trap - EXIT
        echo "dump complete: $out ($n graphs)"

        # Newest first by name, which is the UTC timestamp. Only directories this
        # script named are counted or removed, so a stray directory of one's own is
        # neither mistaken for a dump nor deleted.
        find "$root" -mindepth 1 -maxdepth 1 -type d \
            -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' \
            -printf '%f\n' \
          | sort -r | tail -n +$((keep + 1)) \
          | while read -r old; do rm -rf -- "$root/$old"; done
      '';
    };
  };

  systemd.timers.logseq-sync-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # This host is on America/New_York, so 00:30 here precedes the 01:00 snapshot.
      OnCalendar = "*-*-* 00:30:00";
      # Catch up after a missed window rather than silently skipping a night.
      Persistent = true;
    };
  };

  # The dump proves itself only on the nights it runs. A night where the unit never
  # started at all looks exactly like a quiet one, so this checks the result: the
  # newest dump must exist, be from last night, and still open.
  # Anything else is a failed unit, which is what makes silence distinguishable
  # from success without reading a log.
  systemd.services.logseq-sync-backup-check = {
    description = "Check that the newest dump of the sync data is recent and intact";
    path = [ pkgs.coreutils pkgs.findutils ];
    # Both timers catch up after a boot, so without this the check could start before
    # the dump and report the previous dump as stale. After= orders them when both are
    # queued and never starts a dump on its own.
    after = [ "logseq-sync-backup.service" ];
    serviceConfig = {
      Type = "oneshot";
      # As for the dump: a hung check stays "activating" and every later firing is a
      # no-op, which would switch the check off silently.
      TimeoutStartSec = "10min";
      ExecStart = backupCheck;
    };
  };

  systemd.timers.logseq-sync-backup-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After the dump and the snapshot, before the day starts.
      OnCalendar = "*-*-* 06:00:00";
      # A missed check is worth running late: its whole job is to notice gaps.
      Persistent = true;
    };
  };

  # What the external monitor polls. The scheduled check above is what makes a failure
  # a failed unit on this guest; this is what makes it a DOWN in something that can
  # tell somebody, which a unit on a quiet machine cannot do by itself.
  systemd.services.logseq-backup-status = {
    description = "Report the newest sync dump's health over HTTP for an external monitor";
    wantedBy = [ "multi-user.target" ];
    # No network-online ordering: Proxmox assigns the address before init, and if it is
    # ever missing the bind fails and Restart retries it.
    serviceConfig = {
      ExecStart = backupStatus;
      Restart = "always";
      RestartSec = 30;
      # Reads root-owned dumps as root: owner permissions suffice, so no capabilities,
      # and the port is above 1024 so binding needs none either.
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      ProtectHome = true;
      # The live data, key material included, is never this service's business.
      InaccessiblePaths = [ "/var/lib/logseq-sync/data" ];
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      MemoryMax = "128M";
    };
  };

  # The LAN may reach the sync server directly; the guest and IoT VLANs may not.
  #
  # Scoped by source address rather than just opening the port, because the router
  # is not the only thing standing in the way. OPNsense blocks those two VLANs from
  # private networks with negated-destination rules, so they only get internet
  # traffic — but two of its rules pass *any* destination for named devices (one
  # guest host and the shelly plugs), and those would reach this port the moment it
  # were open to everyone. Matching on source keeps the boundary here even if those
  # router rules change, provided the router never rewrites sources into
  # 192.168.86.0/24 and the VLANs stay separate: a forged source address alone gets
  # the reply sent to whoever really owns that LAN address, so the connection never
  # opens.
  #
  # This host filters with iptables, not nftables, so the rule is written for that
  # backend. networking.firewall.extraInputRules exists only in the nftables module,
  # where it is silently ignored under this backend. extraCommands runs after the
  # standard rules and before the final nixos-fw-log-refuse, and the chain is rebuilt
  # on every reload, so this neither piles up nor gets jumped past. The rule itself is
  # inserted at the top of the chain, which is equivalent here because it matches one
  # port from one source. Target nixos-fw-accept follows hosts/nxc/heimdall. IPv4
  # only, as there: a LAN client arriving over IPv6 is still refused.
  #
  # Tailscale is unaffected: ts-input is jumped ahead of nixos-fw and admits traffic
  # arriving on tailscale0, which is why there is no tailscale0 rule below (it would
  # filter nothing — see the note in hosts/nix-fury). The internet still has no path:
  # nothing forwards or publishes this port, and the public route is bifrost reaching
  # http://logseq:8787 over the tailnet.
  # The status endpoint is narrower still: one source, the monitor host. It answers an
  # unauthenticated GET, so on eth0 the source address is the whole authorization — and
  # it authorizes the host, not the process: anything that leaves 192.168.86.106 as that
  # address, containers NATed through it included, is "the monitor". tailscale0 is
  # admitted by ts-input ahead of this chain, which reaches nothing here because the
  # listener is bound to the LAN address, unless this guest ever advertises the LAN as a
  # subnet route.
  networking.firewall.extraCommands = ''
    iptables -w -I nixos-fw 1 -s 192.168.86.0/24 -p tcp --dport 8787 -j nixos-fw-accept
    iptables -w -I nixos-fw 1 -s 192.168.86.106 -p tcp --dport 8089 -j nixos-fw-accept
  '';

  system.stateVersion = "26.05";
}
