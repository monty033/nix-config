{ config, lib, pkgs, ... }:

let
  cfg = config.services.pihole-native;
  ftl = config.services.pihole-ftl;
  listPayloads = map (
    list:
    builtins.toJSON {
      type = list.type;
      enabled = list.enabled;
      address = list.url;
      comment = list.description;
      groups = list.groups;
    }
  ) cfg.lists;
  listManifest = builtins.toJSON (map (
    list: {
      type = list.type;
      enabled = list.enabled;
      address = list.url;
      comment = list.description;
      groups = list.groups;
    }
  ) cfg.lists);
  policyRuntime = pkgs.runCommand "pihole-policy-runtime" { } ''
    mkdir -p $out/scripts/pihole
    cp ${../../scripts/pihole/__init__.py} $out/scripts/pihole/__init__.py
    cp ${../../scripts/pihole/live_reconcile.py} $out/scripts/pihole/live_reconcile.py
    cp ${../../scripts/pihole/live_dry_run_remote.py} $out/scripts/pihole/live_dry_run_remote.py
  '';
  policyApply = pkgs.writeShellApplication {
    name = "pihole-policy-apply";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${lib.getExe pkgs.python3} ${policyRuntime}/scripts/pihole/live_dry_run_remote.py
    '';
  };
  # Root-owned advisory lockfile serialises the owner-scoped policy apply
  # and the list/gravity setup so a cooperative second actor cannot slip in
  # between group resolution and list mutation. Non-blocking probe; both
  # writers acquire it exclusively with a short bounded wait.
  policyLockPath = "${cfg.stateDirectory}/.pihole-policy.lock";
  setupScript = ''
    # This intentionally mirrors the pinned NixOS 26.05 native setup behavior
    # while making list registration idempotent. Re-review this override when
    # the nixpkgs Pi-hole module or package input changes.
    set +u
    set -eo pipefail
    acquirePolicyLock() {
      local attempts=20
      # Open the persistent lock file via flock(1) for an atomic, race-free
      # exclusive acquisition. Opening with `>>` creates the file when
      # absent and never truncates, so an existing holder's fd stays bound
      # to the same inode while we attempt our non-blocking flock. The
      # lockfile itself persists across writer invocations; flock is the
      # only mutual-exclusion signal.
      $install -d -m 0770 "${ftl.stateDirectory}" 2>/dev/null || true
      # The persistent lockfile may have been created by the policy apply
      # (which runs as root over SSH) with mode 0600. Relax it so the
      # setup service, which runs as the pihole user, can take the flock.
      if [ -e "$lock_path" ]; then
        $chmod 0660 "$lock_path" 2>/dev/null || true
      fi
      while [ "$attempts" -gt 0 ]; do
        if eval "exec $lockfd>>\"$lock_path\"" 2>/dev/null && $flock -n "$lockfd"; then
          trap '$flock -u "$lockfd" 2>/dev/null; $rm -f "$macvendor_tmp"' EXIT
          return 0
        fi
        eval "exec $lockfd>&-" 2>/dev/null || true
        # The lockfile is intentionally persistent. flock(-n) is the only
        # signal that another actor holds the lock; if it failed while the
        # file exists, another writer is currently in flight. Retry briefly
        # in case the previous holder just released.
        attempts=$((attempts - 1))
        ${lib.getExe' pkgs.coreutils "sleep"} .25s
      done
      echo "Pi-hole policy lock is unavailable"
      exit 1
    }
    # This intentionally mirrors the pinned NixOS 26.05 native setup behavior
    # while making list registration idempotent. Re-review this override when
    # the nixpkgs Pi-hole module or package input changes.
    set +u
    set -eo pipefail
    pihole="${lib.getExe ftl.piholePackage}"
    jq="${lib.getExe pkgs.jq}"
    curl="${lib.getExe pkgs.curl}"
    dig="${lib.getExe' pkgs.bind.dnsutils "dig"}"
    mktemp="${lib.getExe' pkgs.coreutils "mktemp"}"
    mv="${lib.getExe' pkgs.coreutils "mv"}"
    rm="${lib.getExe' pkgs.coreutils "rm"}"
    install="${lib.getExe' pkgs.coreutils "install"}"
    chmod="${lib.getExe' pkgs.coreutils "chmod"}"
    flock="${lib.getExe' pkgs.util-linux "flock"}"
    macvendor_url=${lib.escapeShellArg ftl.macvendorURL}
    desired_lists=${lib.escapeShellArg listManifest}
    desired_lists_resolved=""
    pending_marker="${ftl.stateDirectory}/.pihole-ftl-lists-pending"
    lists_changed=false
    any_failed=0
    lock_path="${ftl.stateDirectory}/.pihole-policy.lock"
    lockfd=9
    # Acquire the shared advisory policy lock after tools are resolved so
    # the function and its call site can both reference $install/$mv/$rm.
    acquirePolicyLock

    # Validate local file-backed lists before any destructive API operation.
    while IFS= read -r file_url; do
      [ -z "$file_url" ] && continue
      file_path="''${file_url#file://}"
      if [ ! -f "$file_path" ] || [ ! -r "$file_path" ] || [ ! -s "$file_path" ]; then
        echo "A declared local Pi-hole list is missing, unreadable, or empty"
        exit 1
      fi
    done < <($jq -r '.[] | select(.address | startswith("file://")) | .address' <<< "$desired_lists")

    macvendor_tmp=$($mktemp "${ftl.stateDirectory}/macvendor.db.XXXXXX")
    # Preserve the lock-cleanup trap set in acquirePolicyLock; chain the
    # macvendor_tmp cleanup so it does not overwrite the lock release.
    # The lockfile itself is intentionally persistent: dropping it would
    # create a new inode and break the advisory lock shared with
    # live_apply. Only the flock is released.
    trap '$flock -u "$lockfd" 2>/dev/null; $rm -f "$macvendor_tmp"' EXIT
    if $curl --fail --retry 3 --retry-delay 5 "$macvendor_url" \
      -o "$macvendor_tmp"; then
      $mv -f "$macvendor_tmp" "${ftl.stateDirectory}/macvendor.db"
    else
      echo "Failed to download the Pi-hole MAC database"
      any_failed=1
      if [ ! -s "${ftl.stateDirectory}/macvendor.db" ]; then
        echo "No existing Pi-hole MAC database is available"
      fi
    fi

    # Source api.sh for the helpers we actually use (GetFTLData, PostFTLData,
    # LogoutAPI) but NOT TestAPIAvailability or LoginAPI: the upstream
    # helpers exit the shell on failure, which would defeat our retry loop
    # and bypass our SOPS auth branch.
    . ${ftl.piholePackage}/share/pihole/advanced/Scripts/api.sh
    . ${ftl.piholePackage}/share/pihole/advanced/Scripts/utils.sh

    # Inline Pi-hole API readiness check, modelled on upstream
    # `TestAPIAvailability` but returning a clean 0/1 status so it can
    # participate in a retry loop without exiting the oneshot. Discovers
    # the FTL-reported API URLs via the CHAOS TXT record `local.api.ftl`
    # and probes each URL with curl; sets $API_URL and $needAuth in the
    # calling shell on success. We hardcode the DNS port to 53 because
    # upstream's TestAPIAvailability also defaults to the FTL-published
    # port, which is 53 unless the operator reconfigured it, and the
    # helper that reads FTL's config (`getFTLConfigValue`) is only
    # defined inside `TestAPIAvailability` itself. Using `dig +short -p 53`
    # avoids the awk/PATH complication Luna flagged while still working
    # against the standard FTL configuration.
    checkPiHoleApiReady() {
      local api_urls url auth_response auth_status
      api_urls=$($dig +short -p 53 chaos txt local.api.ftl @127.0.0.1) || return 1
      if [ -z "$api_urls" ] || [ "''${api_urls#;;}" != "$api_urls" ]; then
        return 1
      fi
      for url in $api_urls; do
        url="''${url%\"}"
        url="''${url#\"}"
        auth_response=$($curl --connect-timeout 2 -skS -w ">>%{http_code}" "''${url}auth" 2>/dev/null) || continue
        auth_status=''${auth_response#*>>}
        case "$auth_status" in
          200)
            API_URL="$url"
            needAuth=false
            return 0
            ;;
          401)
            API_URL="$url"
            needAuth=true
            return 0
            ;;
          *)
            continue
            ;;
        esac
      done
      return 1
    }

    api_ready=false
    for _ in 1 2 3; do
      if checkPiHoleApiReady; then
        api_ready=true
        break
      fi
      echo "Retrying API shortly..."
      ${lib.getExe' pkgs.coreutils "sleep"} .5s
    done
    if [ "$api_ready" != true ]; then
      echo "Pi-hole API did not become available"
      exit 1
    fi

    # Authenticate using the SOPS-rendered runtime API credential when the
    # EnvironmentFile mounted by pihole-ftl-setup.service provides one.
    # Otherwise fall back to Pi-hole's upstream LoginAPI path (CLI password,
    # loopback disposable, or pre-rotation state). This restores a single
    # credential source-of-truth without breaking the disposable-test path.
    # The password is encoded into the JSON body via `jq --arg` so quotes,
    # backslashes, and control characters in the credential cannot inject
    # JSON structure or alter the request payload.
    if [ -n "''${FTLCONF_webserver_api_password:-}" ] && [ "''${needAuth:-false}" = true ]; then
      auth_body=$($jq -nc --arg p "$FTLCONF_webserver_api_password" \
        '{password: $p, totp: null}') || {
          echo "Failed to build Pi-hole authentication payload"
          exit 1
        }
      auth_response=$($curl --connect-timeout 2 -skS -X POST "''${API_URL}auth" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data "$auth_body") || {
          echo "Pi-hole API authentication request failed"
          exit 1
        }
      auth_session=$($jq -c '.session // empty' <<< "$auth_response" 2>/dev/null) || {
        echo "Pi-hole authentication response was not valid JSON"
        exit 1
      }
      if [ "$($jq -r '.valid // false' <<< "$auth_session")" != "true" ]; then
        echo "Pi-hole authentication failed using the SOPS API credential"
        exit 1
      fi
      SID=$($jq -r '.sid // empty' <<< "$auth_session")
      if [ -z "$SID" ]; then
        echo "Pi-hole authentication succeeded without a session id"
        exit 1
      fi
      validSession=true
      export SID validSession
    else
      LoginAPI
    fi

    # Group membership is policy-owned runtime state. Resolve the declared
    # names only after API authentication, and fail before gravity or list
    # mutation if the group API is malformed, ambiguous, or incomplete.
    validateDeclaredGroups() {
      local group_data
      if group_data=$(GetFTLData "groups"); then
        :
      else
        echo "Unable to read current Pi-hole groups"
        exit 1
      fi
      if ! $jq -e '
        type == "object" and (.error == null) and (.groups | type == "array")
        and all(.groups[];
          (type == "object")
          and ((.name | type) == "string")
          and (.name | length) > 0
          and ((.id | type) == "number")
          and (.id == (.id | floor))
          and (.id >= 0)
        )
        and (([.groups[] | .name] | length) == ([.groups[] | .name] | unique | length))
        and (([.groups[] | .id] | length) == ([.groups[] | .id] | unique | length))
      ' >/dev/null <<< "$group_data"; then
        echo "Unable to parse Pi-hole groups (unexpected or ambiguous shape)"
        exit 1
      fi
      if ! group_name_to_id=$($jq -c 'reduce (.groups[]) as $g ({}; .[$g.name] = $g.id)' <<< "$group_data"); then
        echo "Unable to parse Pi-hole groups"
        exit 1
      fi
      desired_lists_resolved=$($jq -c --argjson gm "$group_name_to_id" '
        map(
          .groups = ([.groups[]?] | map($gm[.] // error("unknown Pi-hole group: " + (. // "<null>"))))
        )
      ' <<< "$desired_lists") || {
        echo "Pi-hole list references a group not present on this instance"
        exit 1
      }
    }

    # Validate the group contract before initial gravity, so a fresh instance
    # with missing or ambiguous groups remains untouched.
    validateDeclaredGroups

    if [ ! -f "${ftl.stateDirectory}/gravity.db" ]; then
      $pihole -g
      main_pid=$(systemctl show --property MainPID --value ${config.systemd.services.pihole-ftl.name})
      if [ -z "$main_pid" ]; then
        echo "Unable to determine the Pi-hole FTL process ID"
        exit 1
      fi
      case "$main_pid" in
        0|*[!0-9]*)
          echo "Unable to determine the Pi-hole FTL process ID"
          exit 1
          ;;
        *)
          ${lib.getExe' pkgs.procps "kill"} -s SIGRTMIN "$main_pid"
          ;;
      esac
    fi

    reconcileLists() {
      local current_lists current_signature desired_signature delete_payload response status result error id
      if current_lists=$(GetFTLData "lists"); then
        :
      else
        echo "Unable to read current Pi-hole lists"
        exit 1
      fi
      # Pi-hole v6 returns `groups` as a sorted list of integer group IDs
      # (e.g. [0, 1]). Validate the shape and that each entry is a non-negative
      # integer rather than dereferencing `.id` on what are actually numbers.
      if ! $jq -e '
        type == "object"
        and (.error == null)
        and (.lists | type == "array")
        and all(.lists[];
          (type == "object")
          and ((.type | type) == "string")
          and ((.address | type) == "string")
          and ((.enabled | type) == "boolean")
          and ((.comment == null) or ((.comment | type) == "string"))
          and ((.groups | type) == "array")
          and all(.groups[]; ((. | type) == "number") and (. == (. | floor)) and (. >= 0))
        )
      ' >/dev/null <<< "$current_lists"; then
        echo "Unable to read current Pi-hole lists"
        exit 1
      fi

      # Revalidate immediately before any destructive list mutation, so a
      # concurrent group change cannot redirect a list to another cohort.
      validateDeclaredGroups

      current_signature=$($jq -c '
        [.lists[] | {type, address, enabled, comment: (if .comment == null then "" else .comment end), groups: (.groups | sort)}]
        | sort_by(.type, .address)
      ' <<< "$current_lists")
      desired_signature=$($jq -c '
        [.[] | {type, address, enabled, comment: (if .comment == null then "" else .comment end), groups: (.groups | sort)}]
        | sort_by(.type, .address)
      ' <<< "$desired_lists_resolved")
      if [ "$current_signature" = "$desired_signature" ] && [ ! -e "$pending_marker" ]; then
        echo "Pi-hole lists already match the declared configuration"
        return 0
      fi

      if ! $install -D -m 0600 /dev/null "$pending_marker"; then
        echo "Unable to create the Pi-hole list reconciliation marker"
        exit 1
      fi
      # Revalidate immediately after the destructive batchDelete so a
      # concurrent group change cannot influence the IDs each list POST
      # would otherwise reuse.
      validateDeclaredGroups
      lists_changed=true
      delete_payload=$($jq -c '[.lists[] | {item: .address, type: .type}]' <<< "$current_lists")
      if [ "$delete_payload" != "[]" ]; then
        echo "Resetting Pi-hole lists to the declared configuration"
        response=$(PostFTLData "lists:batchDelete" "$delete_payload" status) || {
          echo "Pi-hole API request failed while resetting lists"
          exit 1
        }
        status=''${response: -3}
        case "$status" in
          204) ;;
          *)
            echo "Pi-hole API returned HTTP $status while resetting lists"
            exit 1
            ;;
        esac
      fi

      ensureList() {
        local payload="$1" response status result error id body
        # Re-resolve group names immediately before each POST, so a concurrent
        # group change cannot redirect this list to an obsolete ID set.
        validateDeclaredGroups
        local resolved
        resolved=$($jq -c --argjson gm "$group_name_to_id" '
          .groups = ([.groups[]?] | map($gm[.] // error("unknown Pi-hole group: " + (. // "<null>"))))
          | del(.type)
        ' <<< "$payload") || {
          echo "Pi-hole list references a group not present on this instance"
          exit 1
        }
        body="$resolved"
        if response=$(PostFTLData "lists?type=$($jq -r '.type' <<< "$payload")" "$body" status); then
          :
        else
          echo "Pi-hole API request failed while adding a declared list"
          exit 1
        fi
        status=''${response: -3}
        result=''${response%???}
        case "$status" in
          2??) ;;
          *)
            echo "Pi-hole API returned HTTP $status while adding a declared list"
            exit 1
            ;;
        esac
        if ! $jq -e 'type == "object" and (.error == null)' >/dev/null <<< "$result"; then
          echo "Pi-hole API rejected a declared list"
          exit 1
        fi
        id=$($jq -r '.lists[]?.id // .list.id // empty' <<< "$result")
        if [ -z "$id" ]; then
          echo "Pi-hole API returned no list ID for a declared list"
          exit 1
        fi
      }

      ${lib.concatMapStringsSep "\n" (payload: "ensureList ${lib.escapeShellArg payload}") listPayloads}
    }

    verifyLists() {
      local actual
      # Re-resolve names for every verification. A concurrent group change
      # cannot turn stale numeric IDs into a successful reconciliation.
      validateDeclaredGroups
      actual=$(GetFTLData "lists") || {
        echo "Unable to read Pi-hole lists for post-rebuild verification"
        exit 1
      }
      $jq -e --argjson desired "$desired_lists_resolved" '
        (type == "object" and (.error == null) and (.lists | type == "array"))
        and all(.lists[];
          (type == "object")
          and ((.type | type) == "string")
          and ((.address | type) == "string")
          and ((.enabled | type) == "boolean")
          and ((.comment == null) or ((.comment | type) == "string"))
          and ((.groups | type) == "array")
          and all(.groups[]; ((. | type) == "number") and (. == (. | floor)) and (. >= 0))
        )
        and (
          ([.lists[] | {type, address, enabled, comment: (if .comment == null then "" else .comment end), groups: (.groups | sort)}]
           | sort_by(.type, .address))
          == ($desired
              | map({type, address, enabled, comment: (if .comment == null then "" else .comment end), groups: (.groups | sort)})
              | sort_by(.type, .address))
        )
      ' <<< "$actual" >/dev/null || {
        echo "Pi-hole list state did not converge to the declared configuration"
        exit 1
      }
    }

    reconcileLists
    if [ "$lists_changed" != true ]; then
      exit $any_failed
    fi
    verifyLists
    if ! $pihole -g; then
      echo "Pi-hole gravity run failed; leaving the reconciliation marker for retry"
      exit 1
    fi
    verifyLists
    $rm -f "$pending_marker"
    exit $any_failed
  '';
in
{
  options.services.pihole-native = {
    enable = lib.mkEnableOption "native Pi-hole FTL and Web services";

    lists = lib.mkOption {
      type = with lib.types; listOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "URL of the domain list.";
          };
          type = lib.mkOption {
            type = lib.types.enum [ "allow" "block" ];
            default = "block";
            description = "Whether domains on this list are explicitly allowed or blocked.";
          };
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether this list is enabled.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Description of the list.";
          };
          groups = lib.mkOption {
            type = with lib.types; listOf (lib.types.enum [ "Default" "normal" "kids" "unfiltered" ]);
            default = [ "Default" ];
            description = "Pi-hole groups this list applies to. Must match group names declared in inventory policy.groups.";
          };
        };
      });
      default = [ ];
      description = "Domain lists synced to both Pi-hole instances, with per-list group assignment.";
      example = [
        {
          url = "https://big.oisd.nl";
          description = "OISD big — comprehensive ad/tracker/malware list";
          groups = [ "Default" "normal" "kids" ];
        }
      ];
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Network interface on which Pi-hole accepts DNS queries.";
    };

    listeningMode = lib.mkOption {
      type = lib.types.enum [
        "LOCAL"
        "SINGLE"
        "BIND"
        "ALL"
        "NONE"
      ];
      default = "BIND";
      description = "Pi-hole FTL DNS listening mode.";
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Upstream DNS servers used by Pi-hole FTL; required per host.";
    };

    webHostName = lib.mkOption {
      type = lib.types.str;
      default = "pi.hole";
      description = "Pi-hole Web virtual host name.";
    };

    webPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port for the Pi-hole Web interface and API.";
    };

    webListenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address for the Pi-hole Web/API listener.";
    };

    apiPasswordEnvironmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime EnvironmentFile containing FTLCONF_webserver_api_password.
        The file should be rendered by sops-nix and must never be committed
        in plaintext. Required when Web/API is bound beyond loopback. The
        corresponding sops template must restart pihole-ftl.service when it
        changes.
      '';
    };

    openFirewallDNS = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the host firewall for DNS.";
    };

    privacyLevel = lib.mkOption {
      type = lib.types.ints.between 0 3;
      default = 0;
      description = "Pi-hole FTL statistics privacy level.";
    };

    dnssec = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Pi-hole FTL validates DNS replies with DNSSEC.";
    };

    queryLogging = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Pi-hole FTL logs DNS queries and replies.";
    };

    blockingMode = lib.mkOption {
      type = lib.types.enum [ "NULL" "IP_NODATA_AAAA" "IP" "NX" "NODATA" ];
      default = "NULL";
      description = "Response mode for blocked DNS queries.";
    };

    resolver = {
      resolveIPv4 = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether FTL resolves IPv4 client addresses to hostnames.";
      };

      resolveIPv6 = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether FTL resolves IPv6 client addresses to hostnames.";
      };

      networkNames = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether FTL uses network-table names for client attribution.";
      };

      refreshNames = lib.mkOption {
        type = lib.types.enum [ "IPV4_ONLY" "ALL" "UNKNOWN" "NONE" ];
        default = "IPV4_ONLY";
        description = "How FTL refreshes client and upstream hostnames.";
      };
    };

    database = {
      maxDBdays = lib.mkOption {
        type = lib.types.ints.between 0 3650;
        default = 91;
        description = "Number of days FTL retains query history locally.";
      };

      DBinterval = lib.mkOption {
        type = lib.types.ints.between 0 86400;
        default = 60;
        description = "Seconds between FTL query-history database writes.";
      };

      useWAL = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether FTL uses SQLite write-ahead logging.";
      };

      networkExpire = lib.mkOption {
        type = lib.types.ints.between 1 3650;
        default = 91;
        description = "Number of days FTL retains network-table addresses locally.";
      };
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/pihole";
      description = "Persistent Pi-hole state directory.";
    };

    logDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/pihole";
      description = "Persistent Pi-hole log directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.upstreams != [ ];
        message = "services.pihole-native.upstreams must be set explicitly for each Pi-hole host.";
      }
      {
        assertion =
          cfg.privacyLevel == 0
          && cfg.dnssec == false
          && cfg.queryLogging == true
          && cfg.blockingMode == "NULL"
          && cfg.resolver.resolveIPv4 == true
          && cfg.resolver.resolveIPv6 == true
          && cfg.resolver.networkNames == true
          && cfg.resolver.refreshNames == "IPV4_ONLY"
          && cfg.database.maxDBdays == 91
          && cfg.database.DBinterval == 60
          && cfg.database.useWAL == true
          && cfg.database.networkExpire == 91;
        message = "Pi-hole shared FTL baseline settings are fixed and must be identical on both instances.";
      }
      {
        assertion =
          cfg.webListenAddress == "127.0.0.1"
          || (cfg.apiPasswordEnvironmentFile != null && cfg.apiPasswordEnvironmentFile != "");
        message = "services.pihole-native.apiPasswordEnvironmentFile is required when Web/API is bound beyond loopback.";
      }
      {
        assertion = lib.all (list: builtins.match ".*://[^/]*@.*" list.url == null) cfg.lists;
        message = "Pi-hole list URLs must not contain embedded credentials.";
      }
    ];

    services.pihole-ftl = {
      enable = true;
      privacyLevel = cfg.privacyLevel;
      openFirewallDNS = cfg.openFirewallDNS;
      # NOTE: list loading is handled entirely by our setup script (which reads
      # services.pihole-native.lists, a typed option that carries group
      # assignments). We intentionally do NOT bind native lists into
      # services.pihole-ftl.lists because the upstream option type rejects the
      # `groups` field. The upstream module's own list loader is overridden by
      # our mkForce setup script below.
      # settings.webserver.port to "host:port" which breaks the NixOS
      # firewall parser's toInt call. Instead, open the port directly.
      openFirewallWebserver = false;
      stateDirectory = cfg.stateDirectory;
      logDirectory = cfg.logDirectory;
      settings = {
        dns = {
          inherit (cfg) interface listeningMode upstreams dnssec queryLogging;
          replyWhenBusy = "ALLOW";
          bogusPriv = true;
          blocking = {
            active = true;
            mode = cfg.blockingMode;
            edns = "TEXT";
          };
          specialDomains = {
            mozillaCanary = true;
            iCloudPrivateRelay = true;
            designatedResolver = true;
          };
        };
        dhcp.active = false;
        ntp = {
          ipv4.active = false;
          ipv6.active = false;
          sync.active = false;
        };
        resolver = {
          inherit (cfg.resolver) resolveIPv4 resolveIPv6 networkNames refreshNames;
        };
        database = {
          DBimport = true;
          inherit (cfg.database) maxDBdays DBinterval useWAL;
          network = {
            parseARPcache = true;
            expire = cfg.database.networkExpire;
          };
        };
        webserver.api = {
          # Required by the native list setup service. Keep this ephemeral
          # credential separate from the eventual reconciler credential.
          cli_pw = true;
          app_sudo = false;
        };
      };
    };

    # Immutable Pi-hole-local apply wrapper. It reads the SOPS runtime secret
    # only on the target; Hermes sends inventory and the secret file path.
    environment.etc."pihole/live-policy-apply" = {
      source = "${policyApply}/bin/pihole-policy-apply";
      mode = "0555";
    };

    systemd.services.pihole-ftl.serviceConfig.EnvironmentFile =
      lib.optional
        (cfg.apiPasswordEnvironmentFile != null && cfg.apiPasswordEnvironmentFile != "")
        cfg.apiPasswordEnvironmentFile;

    # Keep the setup unit enabled even when the declared list is empty so a
    # stale runtime list is still removed by the next reconciliation.
    systemd.services.pihole-ftl-setup.enable = lib.mkForce cfg.enable;
    systemd.services.pihole-ftl-setup.script = lib.mkForce setupScript;
    # Mount the same SOPS-rendered runtime API credential that pihole-ftl
    # uses, so the setup oneshot authenticates with the same source-of-truth
    # password. Without this, the setup script falls back to Pi-hole's
    # auto-generated /etc/pihole/cli_pw, which never matches the SOPS
    # credential and causes the list/gravity reconcile to fail.
    systemd.services.pihole-ftl-setup.serviceConfig.EnvironmentFile =
      lib.optional
        (cfg.apiPasswordEnvironmentFile != null && cfg.apiPasswordEnvironmentFile != "")
        cfg.apiPasswordEnvironmentFile;

    # Open the web interface port when binding beyond loopback.
    # Cannot use pihole-ftl's openFirewallWebserver because pihole-web.nix
    # sets settings.webserver.port to "host:port" which breaks the NixOS
    # firewall parser's toInt call.
    networking.firewall.allowedTCPPorts =
      lib.optionals (cfg.webListenAddress != "127.0.0.1") [ cfg.webPort ];

    services.pihole-web = {
      enable = true;
      hostName = cfg.webHostName;
      ports = [ "${cfg.webListenAddress}:${toString cfg.webPort}" ];
    };

    # FTL appends every query to pihole.log, and nothing rotates it on NixOS:
    # the upstream installer's /etc/pihole/logrotate hook has no equivalent
    # here, and FTL only rotates its own FTL.log. Left unrotated the file grew
    # to 21 GB. Where a container's rootfs is on non-snapshot storage, vzdump
    # falls back to suspend mode and re-copies the whole log while the guest is
    # frozen, which keeps the resolver down for the length of that sync.
    # Rotate daily and keep a week so that delta stays small.
    #
    # copytruncate keeps the inode and FTL's open append handle valid, so no
    # reopen or restart is needed; the cost is that queries logged during the
    # copy window are dropped, which is acceptable for a diagnostic log.
    services.logrotate.settings.pihole-query-log = {
      files = "${cfg.logDirectory}/pihole.log";
      frequency = "daily";
      rotate = 7;
      compress = true;
      delaycompress = true;
      copytruncate = true;
      missingok = true;
      notifempty = true;
    };
  };
}
