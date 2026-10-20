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
  };

  imports = [
    ../secrets
  ];

  config = mkIf cfg.enable {
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
      useRoutingFeatures = "client";
      permitCertUid = "caddy";
      extraUpFlags = [
        "--force-reauth"
        "--reset"
        "--ssh"
        "--accept-routes"
      ] ++ (optionals cfg.lxc [
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

    # Fix for local network routing conflict with Tailscale in LXC
    # Timer to periodically check and remove the route
    systemd.timers.fix-tailscale-local-routing = mkIf cfg.lxc {
      description = "Timer for removing local subnet route from Tailscale routing table";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "30s";
        Unit = "fix-tailscale-local-routing.service";
      };
    };

    systemd.services.fix-tailscale-local-routing = mkIf cfg.lxc {
      description = "Remove local subnet route from Tailscale routing table";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Check if Tailscale interface exists
        if ! ${pkgs.iproute2}/bin/ip link show tailscale0 > /dev/null 2>&1; then
          echo "Tailscale interface not yet up, skipping"
          exit 0
        fi

        # Delete the problematic route if it exists
        if ${pkgs.iproute2}/bin/ip route show table 52 | ${pkgs.gnugrep}/bin/grep -q "192.168.86.0/24 dev tailscale0"; then
          ${pkgs.iproute2}/bin/ip route del 192.168.86.0/24 dev tailscale0 table 52 2>/dev/null && \
            echo "$(date): Removed 192.168.86.0/24 route from Tailscale routing table"
        fi
      '';
    };
  };
}