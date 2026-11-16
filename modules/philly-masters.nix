{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.extra-services.philly-masters;
  app = pkgs.callPackage ../packages/philly-masters.nix { inherit inputs; };
  stateDir = "/var/lib/philly-masters";

  # What the service actually runs, and the only thing an app release has to
  # change. The profile is a symlink to a store path; `nix-env --set` moves it,
  # leaving the previous generations on disk and registered as GC roots. The unit
  # names the profile, not a version, so the system build does not change when the
  # application does — and an unrelated rebuild cannot silently roll the app back.
  #
  # It is seeded from `cfg.package` when it does not exist, which is what a fresh
  # host needs; after that, deploys move it and `cfg.package` is only the starting
  # point — it stays in the system closure as the version a brand new host would
  # come up on, not necessarily the one running. A `nix flake update` here still
  # rebuilds the application, but changes nothing on a host that has been deployed.
  #
  # Rolling the profile back does NOT undo a migration: a release that changed the
  # schema leaves the old code running against a newer database. Snapshot the
  # database before deploying, which scripts/deploy.sh in the application repo
  # does.
  profile = "/nix/var/nix/profiles/philly-masters";
  profileBin = "${profile}/bin/philly-masters-pool";
  # The signing secret is generated here rather than declared, because nobody
  # needs to know it: it keys sessions, so a fresh one costs only a re-login. It
  # lives in the state directory, which survives reinstalls and is not in the
  # store — a secret in the Nix store is a secret in every build log and every
  # cache upload, and sops would mean an operator handling a value that exists
  # only to be random.
  secretFile = "${stateDir}/auth-secret.env";

  # The launcher owns the secret, so the first start is the same path as every
  # later start. An ExecStartPre that creates the file while `EnvironmentFile`
  # has already been read means the first boot has no AUTH_SECRET and dies into
  # a restart — worked around by an accident of timing rather than by design.
  #
  # The secret is written once and left alone: regenerating it invalidates every
  # live session.
  launcher = pkgs.writeShellScript "philly-masters-run" ''
    set -eu
    # Generated only when the file is absent. A file that exists and carries no
    # secret is a fault — truncated by a full disk, or written by hand — and
    # regenerating it would silently log every session out and hide the fault.
    if [ ! -e ${secretFile} ]; then
      umask 077
      secret=$(${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0)
      printf 'AUTH_SECRET=%s\n' "$secret" > ${secretFile}.new
      ${pkgs.coreutils}/bin/mv ${secretFile}.new ${secretFile}
    fi
    # Parsed, not sourced: an environment file is data, and a shell would run
    # whatever a corrupted line contained.
    AUTH_SECRET=$(${pkgs.gnused}/bin/sed -n 's/^AUTH_SECRET=//p' ${secretFile})
    if [ -z "$AUTH_SECRET" ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' \
        "philly-masters: ${secretFile} exists but has no AUTH_SECRET; refusing to start rather than rotating the signing key" >&2
      exit 78
    fi
    export AUTH_SECRET
    # The profile is created by activation on the first switch; if it is missing
    # here, saying so beats the shell's "No such file or directory".
    if [ ! -x ${profileBin} ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' \
        "philly-masters: ${profileBin} is missing; the profile was not seeded" >&2
      exit 78
    fi
    ${profileBin}
  '';
in
{
  options.extra-services.philly-masters = {
    enable = lib.mkEnableOption "the Philly Masters Pool application";

    package = lib.mkOption {
      type = lib.types.package;
      default = app;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/philly-masters.nix { inherit inputs; }";
      description = ''
        The application version a host comes up on when it has no profile yet, which
        is its first switch.

        It is set as the profile's first generation by activation and then left
        alone: the service runs whatever the profile points at, and a deploy moves
        that. So neither setting this option nor bumping the flake input it defaults
        from (`nix flake update`) changes a host whose profile already exists,
        whether that profile was seeded by the first switch or moved by a deploy.
        Both rebuild the application; the running version only moves on a deploy.
        That is the point: application releases no longer need a commit here.
      '';
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        The address the server listens on. The default is loopback: no peer
        elsewhere on the network can connect to this port, and public traffic
        reaches the server only through the reverse proxy on this host.

        That closes remote forgery of the X-Forwarded-For header the rate limits
        are keyed on. It does not close host-local access — a process running on
        this machine can connect to the port and write its own header, which is
        the trust every service on the host already extends to the others. It is
        also not a socket: setting this to a path configures nothing, because the
        adapter binds a TCP address.

        Nothing else in the module narrows the field: the server has no way to
        tell a proxied request from a host-local one, so the header it trusts is
        exactly as trustworthy as the host.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3440;
      description = "Port the application listens on. The reverse proxy on the same host uses it.";
    };

    publicOrigin = lib.mkOption {
      type = lib.types.str;
      default = "https://phillymasters.montycasa.com";
      description = ''
        The browser-facing origin. Two things depend on it: link and form targets
        SvelteKit builds, and the origin check that refuses cross-site form posts.
        It must match the hostname Caddy serves, or every POST is refused.
      '';
    };

    adminEmails = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "demo-one@example.com" "demo-two@example.com" ];
      description = ''
        The two administrator addresses. The application refuses to start with
        any other number, because the pool's operating model is two people who
        can both do everything. Administration is configuration only: an address
        here is an administrator, and no membership row can grant it.

        The defaults are placeholders for the demo. The demo page is public and
        needs no account, so nothing is lost until real addresses replace them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.adminEmails == 2;
        message = "extra-services.philly-masters.adminEmails must hold exactly two addresses";
      }
    ];

    users.groups.philly-masters = { };
    users.users.philly-masters = {
      isSystemUser = true;
      group = "philly-masters";
      home = stateDir;
      description = "Philly Masters Pool application";
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 philly-masters philly-masters -"
    ];

    # Seed the profile once. Doing it here rather than in the unit means the switch
    # leaves the host in a state where the service can start, and a host that
    # already has a deploy is left alone: this never overwrites a version that was
    # put there by a deploy.
    system.activationScripts.philly-masters-profile = ''
      if [ ! -e ${profile} ]; then
        ${config.nix.package}/bin/nix-env -p ${profile} --set ${cfg.package}
      fi
    '';

    systemd.services.philly-masters = {
      description = "Philly Masters Pool";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOST = cfg.bindAddress;
        PORT = toString cfg.port;
        ORIGIN = cfg.publicOrigin;
        PUBLIC_ORIGIN = cfg.publicOrigin;
        # The address the rate limits are keyed on. One proxy deep: the Caddy on
        # this host terminates TLS and adds the client address. A process
        # already running on this host can forge the header; nothing else can.
        ADDRESS_HEADER = "X-Forwarded-For";
        XFF_DEPTH = "1";
        DATABASE_PATH = "${stateDir}/pool.sqlite";
        ADMIN_EMAILS = lib.concatStringsSep "," cfg.adminEmails;
        # The demo has no members to mail, and the outbox is not a silent
        # fallback: the application refuses to use it in production unless it is
        # asked for by name. Swap for EMAIL_PROVIDER=zeptomail, its API key and
        # sender when logins become real. Until then, no login email is sent.
        EMAIL_PROVIDER = "outbox";
        ALLOW_OUTBOX = "1";
        # With no provider, the outbox keeps its messages in memory and nobody can read
        # them — including whoever is testing the login or the address-change link. The
        # file sink makes those links readable by the service's user only. It holds live
        # bearer links, so it is a credential store: unset it the day a provider is
        # configured, and it is never set for zeptomail.
        OUTBOX_FILE = "${stateDir}/outbox.jsonl";
      };

      serviceConfig = {
        ExecStart = launcher;
        User = "philly-masters";
        Group = "philly-masters";
        WorkingDirectory = stateDir;
        StateDirectory = "philly-masters";
        StateDirectoryMode = "0750";

        Restart = "always";
        RestartSec = 3;

        # A single-purpose server: it needs its state directory, the network,
        # and nothing else on the host.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        # MemoryDenyWriteExecute is deliberately absent: V8 compiles JavaScript
        # to machine code at runtime, so the sandbox would kill the server on
        # the first request.
      };
    };

  };
}
