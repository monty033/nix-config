{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.extra-services.simplex-smp-server;
in
{
  options.extra-services.simplex-smp-server = {
    enable = mkEnableOption "SimpleX SMP server relay";

    image = mkOption {
      type = types.str;
      default = "simplexchat/smp-server:latest";
      description = "Docker image to use for SimpleX SMP server";
    };

    port = mkOption {
      type = types.port;
      default = 5223;
      description = "Port to expose for SMP protocol";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/simplex-relay";
      description = "Directory to store SimpleX relay data";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/var/lib/simplex-relay/env";
      description = "Path to environment file containing configuration";
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [];
      example = [ "/var/lib/simplex-relay/env" "/run/secrets/simplex" ];
      description = "List of environment files containing configuration";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open the firewall for the SMP port";
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to start the container automatically";
    };
  };

  config = mkIf cfg.enable {
    # Enable Podman
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    # Enable the OCI container for SimpleX relay
    virtualisation.oci-containers = {
      backend = "podman";

      containers.simplex-relay = {
        image = cfg.image;

        ports = [
          "${toString cfg.port}:5223"
        ];

        volumes = [
          "${cfg.dataDir}/config:/etc/opt/simplex"
          "${cfg.dataDir}/logs:/var/opt/simplex"
        ];

        environmentFiles =
          (optional (cfg.environmentFile != null) cfg.environmentFile)
          ++ cfg.environmentFiles;

        autoStart = cfg.autoStart;
      };
    };

    # Create necessary directories
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/config 0755 root root -"
      "d ${cfg.dataDir}/logs 0755 root root -"
    ];

    # Open firewall for SimpleX relay
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}