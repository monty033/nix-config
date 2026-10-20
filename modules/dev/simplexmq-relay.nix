{ config, lib, pkgs, ... }:

with lib; let
  cfg = config.extra-services.simplexmq-relay;

  simplexConfig = pkgs.writeText "smp-server.ini" ''
    [STORE_LOG]
    log_dir: ${cfg.stateDir}/logs
    
    [SERVER]
    ${optionalString (cfg.host != null) "host: ${cfg.host}"}
    port: ${toString cfg.port}
    enable_tls: off
    ${optionalString (cfg.bindAddress != null) "bind: ${cfg.bindAddress}"}
    
    [TRANSPORT]
    ${optionalString cfg.enableWebsockets ''
    websockets: on
    ws_port: ${toString cfg.websocketPort}
    ''}
    
    [STORE]
    store_dir: ${cfg.stateDir}/messages
    msg_retention: ${toString cfg.messageRetention}
    ${optionalString (cfg.maxMessageSize != null) "max_msg_size: ${toString cfg.maxMessageSize}"}
    
    [CONTROL]
    ${optionalString (cfg.controlPort != null) "control_port: ${toString cfg.controlPort}"}
    
    [INACTIVE_CLIENTS]
    disconnect: ${toString cfg.inactiveClientDisconnect}
    ttl: ${toString cfg.inactiveClientTTL}
    
    ${cfg.extraConfig}
  '';
in
{
  options.extra-services.simplexmq-relay = {
    enable = mkEnableOption "SimpleX MQ relay server";

    host = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "smp.example.com";
      description = "Public hostname/domain for the SMP server";
    };

    port = mkOption {
      type = types.port;
      default = 5223;
      description = "Port for SMP protocol";
    };

    bindAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "0.0.0.0";
      description = "Address to bind to. null binds to all interfaces";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/simplexmq";
      description = "Directory for SimpleX MQ state and data";
    };

    enableWebsockets = mkOption {
      type = types.bool;
      default = false;
      description = "Enable WebSocket support";
    };

    websocketPort = mkOption {
      type = types.port;
      default = 5224;
      description = "Port for WebSocket connections";
    };

    messageRetention = mkOption {
      type = types.int;
      default = 1814400; # 21 days in seconds
      description = "Message retention period in seconds";
    };

    maxMessageSize = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 16384;
      description = "Maximum message size in bytes";
    };

    controlPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      example = 5225;
      description = "Control port for server management";
    };

    inactiveClientDisconnect = mkOption {
      type = types.int;
      default = 3600;
      description = "Disconnect inactive clients after this many seconds";
    };

    inactiveClientTTL = mkOption {
      type = types.int;
      default = 86400;
      description = "TTL for inactive client data in seconds";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports for SMP server";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        [CUSTOM_SECTION]
        custom_option: value
      '';
      description = "Extra configuration to append to smp-server.ini";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.simplexmq-relay = {
      description = "SimpleX Chat Relay Server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "simplexmq";
        Group = "simplexmq";

        StateDirectory = "simplexmq";
        StateDirectoryMode = "0750";

        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}/logs"
          "${pkgs.coreutils}/bin/mkdir -p ${cfg.stateDir}/messages"
          "${pkgs.coreutils}/bin/ln -sf ${simplexConfig} ${cfg.stateDir}/smp-server.ini"
        ];

        WorkingDirectory = cfg.stateDir;

        ExecStart = "${pkgs.haskellPackages.simplexmq}/bin/smp-server start -c ${cfg.stateDir}/smp-server.ini";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.stateDir ];

        Restart = "on-failure";
        RestartSec = "10s";
      };
    };

    users.users.simplexmq = {
      isSystemUser = true;
      group = "simplexmq";
      description = "SimpleX MQ relay service user";
      home = cfg.stateDir;
      createHome = true;
    };

    users.groups.simplexmq = {};

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ]
        ++ optional cfg.enableWebsockets cfg.websocketPort
        ++ optional (cfg.controlPort != null) cfg.controlPort;
    };

    environment.systemPackages = [ pkgs.haskellPackages.simplexmq ];

    services.logrotate.settings.simplexmq = {
      files = "${cfg.stateDir}/logs/*.log";
      frequency = "daily";
      rotate = 7;
      compress = true;
      delaycompress = true;
      missingok = true;
      notifempty = true;
    };
  };
}