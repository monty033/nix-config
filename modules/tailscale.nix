/*
 For installation on LXC, add these lines to /etc/pve/lxc/ID.conf:
 lxc.cgroup2.devices.allow: c 10:200 rwm
 lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
 For LXC, run:
 tailscale up --ssh --accept-dns=false
 For other, run:
 tailscale up --ssh
 */
{config, lib, pkgs, inputs, ...}:
with lib; let
  cfg = config.extra-services.tailscale;
  # The reconcile unit below is the only writer of the configured value.
  # `tailscale up --reset` resets the preference to the default, so `up` must not
  # carry the flag: it runs at enrolment, before the guard rules exist.
  acceptRoutesArg = "--accept-routes=${if cfg.acceptRoutes then "true" else "false"}";
  # Rules this unit owns live in prefs 5000-5099, a range nothing else on these
  # hosts uses. Clearing them before re-adding makes a changed or emptied
  # localSubnets list take effect instead of leaving stale rules behind, and the
  # same clearing runs on stop so the rules do not outlive their configuration.
  clearLocalRules = ''
    for pref in $(${pkgs.iproute2}/bin/ip rule show | ${pkgs.gawk}/bin/awk '/^50[0-9][0-9]:/ && /lookup main/ {sub(":","",$1); print $1}'); do
      ${pkgs.iproute2}/bin/ip rule del pref "$pref" 2>/dev/null || true
    done
  '';
in {
  options.extra-services.tailscale = {
    enable = mkEnableOption "enable tailscale config";
    userspace-networking = mkOption {
      type = types.bool;
      default = false;
      description = "Enable userspace networking";
    };
    lxc = mkOption {
      type = types.bool;
      default = false;
      description = "Enable LXC-specific fixes for local network routing";
    };
    tags = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "tag:server" "tag:web" ];
      description = "Tailscale tags to apply to this node";
    };
    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "--advertise-routes=192.168.1.0/24" "--netfilter-mode=off" ];
      description = "Additional flags to pass to tailscale up";
    };
    ephemeral = mkOption {
      type = types.bool;
      default = false;
      description = "Use the ephemeral auth key instead of the standard auth key";
    };
    acceptRoutes = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Accept routes advertised by other tailnet nodes.

        This is on by default because hosts need it to reach subnets that exist
        only behind the tailnet, such as the wakanda site. Accepting routes alone
        is not enough to keep local traffic correct: a host that answers devices
        on another VLAN would send the reply out the tailnet interface instead of
        back through the router. localSubnets below fixes that by keeping the
        local subnets on the main routing table.

        Set this to false on a host that never needs the remote site; it accepts
        no advertised routes at all. The value is applied on boot by
        tailscale-accept-routes.service, not at enrolment, so a node enrolled by
        hand after boot picks it up at its next boot or when
        `systemctl restart tailscale-accept-routes` is run. Hosts running
        tailscale in userspace mode are excluded: neither routing unit is
        installed there, so the value has no effect on them.
      '';
    };
    advertiseRoutes = mkOption {
      type = types.listOf (types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}");
      default = [ ];
      example = [ "192.168.86.0/24" "192.168.10.0/24" ];
      description = ''
        Subnets to advertise into the tailnet, making this host a subnet router.
        Each still needs approval in the Tailscale admin console. Advertising
        gives remote devices access to a subnet; accepting routes is a separate
        per-host decision (see acceptRoutes).
      '';
    };
    localSubnets = mkOption {
      type = types.listOf (types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}");
      default = [ "192.168.86.0/24" "192.168.10.0/24" "192.168.20.0/24" ];
      example = [ "192.168.86.0/24" ];
      description = ''
        Subnets this host shares with its LAN neighbours, reachable through the
        router. Traffic to them is looked up in the main routing table before
        the tailnet table, so replies to devices on another VLAN (IoT, guest)
        return the way they came. Without it the tailnet route wins, the reply
        never reaches the client, and services look healthy while clients get
        nothing.

        The defaults are this LAN's subnets, which is right for every host here.
        A host that lives somewhere else, such as at a remote site, must set this
        to [ ] or its own subnets; otherwise its traffic to these subnets would
        be handed to its local router instead of the tailnet.
      '';
    };
  };

  imports = [
    ../secrets
  ];

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = length cfg.localSubnets <= 100;
        message = "extra-services.tailscale.localSubnets: at most 100 entries (rules occupy prefs 5000-5099)";
      }
    ];
    sops = {
      secrets = {
        "tailscale_auth_key" = {};
      } // (optionalAttrs cfg.ephemeral {
        "tailscale_ephemeral_key" = {};
      });
    };

    services.tailscale = {
      enable = true;
      package = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.tailscale;
      openFirewall = true;
      # Only use userspace networking if LXC mode is enabled
      interfaceName = mkIf cfg.userspace-networking "userspace-networking";
      authKeyFile = if cfg.ephemeral
        then config.sops.secrets.tailscale_ephemeral_key.path
        else config.sops.secrets.tailscale_auth_key.path;
      useRoutingFeatures = if cfg.advertiseRoutes != [ ] then "server" else "client";
      permitCertUid = "caddy";
      extraUpFlags = [
        "--force-reauth"
        "--reset"
        "--ssh"
      ]
      ++ optional (cfg.advertiseRoutes != [ ])
        "--advertise-routes=${concatStringsSep "," cfg.advertiseRoutes}"
      ++ (optionals cfg.lxc [
        "--accept-dns=false"
      ]) ++ (optionals (!cfg.lxc) [
        "--accept-dns=true"
      ]); #++ (optionals (cfg.tags != []) [
      #   "--advertise-tags=${concatStringsSep "," cfg.tags}"
      # ]) ++ cfg.extraFlags;
    };

    # Make tailscaled-autoconnect non-blocking to prevent boot delays on desktop systems
    # For LXC containers (servers), we want it to auto-start
    # For desktops, we disable auto-start to save ~50 seconds on boot
    # systemd.services.tailscaled-autoconnect = mkIf (!cfg.lxc) {
    #   wantedBy = mkForce [ ];  # Remove from boot dependencies (desktop only)
    #   after = [ "multi-user.target" ];  # Run after boot is complete
    # };

    # # Service to update Tailscale when tags or flags change
    # systemd.services.tailscale-update-config = let
    #   # Create a config file that changes when tags/flags change
    #   configFile = pkgs.writeText "tailscale-config" ''
    #     tags=${lib.concatStringsSep "," cfg.tags}
    #     extraFlags=${lib.concatStringsSep " " cfg.extraFlags}
    #   '';
    # in {
    #   description = "Update Tailscale configuration when settings change";
    #   after = [ "tailscaled.service" ];
    #   wants = [ "tailscaled.service" ];
    #   wantedBy = [ "multi-user.target" ];

    #   # This ensures the service only runs when the config actually changes
    #   restartIfChanged = true;

    #   serviceConfig = {
    #     Type = "oneshot";
    #     RemainAfterExit = true;
    #   };

    #   script = let
    #     tailscaleBin = "${config.services.tailscale.package}/bin/tailscale";
    #     upFlags = lib.escapeShellArgs config.services.tailscale.extraUpFlags;
    #   in ''
    #     # Reference the config file to ensure service restarts when it changes
    #     cat ${configFile} > /dev/null

    #     # Wait for tailscaled to be ready
    #     for i in {1..30}; do
    #       if ${tailscaleBin} status &>/dev/null; then
    #         break
    #       fi
    #       sleep 1
    #     done

    #     # Run tailscale up with the configured flags
    #     ${tailscaleBin} up ${upFlags}
    #   '';
    # };

    # LXC-specific fixes
    networking.firewall.checkReversePath = mkIf cfg.lxc "loose";

    # LXC-specific DNS configuration
    # Disable systemd-resolved and resolvconf, use static resolv.conf instead
    # This prevents the LXC host from overriding DNS settings
    services.resolved.enable = mkIf cfg.lxc false;
    networking.resolvconf.enable = mkIf cfg.lxc false;
    environment.etc = mkIf cfg.lxc {
      "resolv.conf".text = ''
        # Tailscale MagicDNS
        nameserver 100.100.100.100
        nameserver 1.1.1.1
        search skink-galaxy.ts.net
        options edns0
      '';
    };

    # Non-LXC DNS configuration uses standard networking options
    networking.nameservers = mkIf (!cfg.lxc) [ "100.100.100.100" "1.1.1.1" ];
    networking.search = mkIf (!cfg.lxc) [ "skink-galaxy.ts.net" ];

    # `--accept-routes` is only read when a node enrols. A node that is already
    # registered keeps whatever preference it last had, so a rebuild or a reboot
    # does not move it and the option above would be decorative on every host
    # that exists today. Reconcile it against the daemon on every boot.
    #
    # Advertising is deliberately not touched here: several hosts advertise
    # through other tooling, and clearing an unset list would remove their
    # routes from the tailnet.
    systemd.services.tailscale-accept-routes =
      mkIf (!cfg.userspace-networking) {
        description = "Reconcile the tailscale accept-routes preference with the configuration";
        wantedBy = [ "multi-user.target" ];
        after = [ "tailscaled.service" "tailscaled-autoconnect.service" "tailscale-local-route-priority.service" ];
        # Requires, not Wants: `after` only orders, so a failed guard would still
        # let acceptance switch on with no rules protecting the return path. It is
        # required only when turning acceptance on, so disabling can never be
        # blocked by a broken guard.
        requires = optional cfg.acceptRoutes "tailscale-local-route-priority.service";
        # A switch that re-runs the enrolment unit (a changed advertise list, for
        # example) resets the preference, so restart this one alongside it.
        partOf = [ "tailscaled-autoconnect.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # A hung CLI must end as a failed unit, not a unit that never finishes.
          # 200s covers the worst case of the loop below: 15 calls at the 10s
          # timeout plus 14 two-second sleeps.
          TimeoutStartSec = "200s";
        };
        # Residual risk: a switch that restarts the guard unit reinstalls the
        # rules while acceptance is already on. The window is milliseconds and
        # the rules are re-added before any new connection is routed.
        script = ''
          ts=${config.services.tailscale.package}/bin/tailscale
          last=
          for attempt in $(${pkgs.coreutils}/bin/seq 1 15); do
            if last=$(${pkgs.coreutils}/bin/timeout 10 "$ts" set ${acceptRoutesArg} 2>&1); then
              echo "accept-routes applied"
              exit 0
            fi
            [ "$attempt" = 15 ] || sleep 2
          done
          # The daemon never answered. Report success only when the node is
          # genuinely unenrolled: the value is applied at the next boot, or when
          # this unit is restarted after enrolment. NoState is the daemon still
          # starting, so a daemon wedged there is a failure, not an unenrolled node.
          backend=$(${pkgs.coreutils}/bin/timeout 10 "$ts" status --json 2>/dev/null | ${pkgs.gnugrep}/bin/grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' | ${pkgs.coreutils}/bin/head -n1 || true)
          case "$backend" in
            *NeedsLogin*)
              echo "not enrolled yet; the preference is applied at the next boot, or by restarting this unit after enrolment"
              exit 0
              ;;
          esac
          echo "could not apply ${acceptRoutesArg} after 15 attempts: $last"
          exit 1
        '';
      };

    # Traffic for the subnets this host shares with its LAN neighbours must be
    # resolved by the main table, not by the routes Tailscale accepts from other
    # nodes. Without this a reply to a device on another VLAN leaves through the
    # tailnet interface and never comes back, which is what took guest DNS down
    # twice (2026-10-05, 2026-11-09) while the resolver looked healthy.
    #
    # An explicit route via tailscale0 does NOT work as a substitute: tailscaled
    # drops packets for a subnet it has not accepted (measured 2026-11-09, 100%
    # loss with both a main-table and a table-52 route). The accepted routes stay
    # in place and the lookup order is changed instead, which keeps the remote
    # site reachable and sends local traffic back through the router.
    systemd.services.tailscale-local-route-priority =
      mkIf (!cfg.userspace-networking) {
        description = "Route local subnets through the main routing table, not the tailnet";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "systemd-networkd.service" ];
        # networkd treats foreign policy rules as its own to manage and drops them
        # when it reconfigures (ManageForeignRoutingPolicyRules defaults to yes),
        # so a networkd restart has to re-run this unit.
        partOf = [ "systemd-networkd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${clearLocalRules}
          ${concatStringsSep "\n" (imap0 (i: subnet: ''
            ${pkgs.iproute2}/bin/ip rule add to ${escapeShellArg subnet} lookup main pref ${toString (5000 + i)}
            echo "routed ${subnet} through the main table"
          '') cfg.localSubnets)}
        '';
        # Runs when the unit is stopped, including on a switch that removes it,
        # so the rules do not outlive the configuration that asked for them.
        postStop = clearLocalRules;
      };

    # Note: forwarding (net.ipv4.ip_forward, and the loose reverse-path filter a
    # subnet router needs) comes from services.tailscale.useRoutingFeatures =
    # "server" above, which is set automatically when advertiseRoutes is used.

  };
}