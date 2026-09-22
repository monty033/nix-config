{ config, lib, pkgs, inputs, ... }:
with lib; let
  cfg = config.extra-services.nookbridge;
  nookbridge = pkgs.callPackage ../packages/nookbridge.nix { inherit inputs; };
  serviceConfig = builtins.fromJSON (builtins.readFile ./nookbridge/service.json);
  settingsSpec = import ./nookbridge/settings.nix { inherit lib; };
  credentialPath = config.sops.secrets."nookbridge-db-key".path;
  settingsPath = "/etc/nookbridge/settings.json";
  settingsContent =
    if cfg.settings != null
    then settingsSpec.renderSettings cfg.settings
    else if cfg.settingsFile != null then builtins.readFile cfg.settingsFile else "";
  settingsSource =
    if cfg.settings != null
    then pkgs.writeText "nookbridge-settings.json" settingsContent
    else cfg.settingsFile;
  provisionCommand = pkgs.writeShellScriptBin "nookbridge-provision" ''
    set -eu
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' 'nookbridge-provision: must be run as root' >&2
      exit 77
    fi
    exec ${pkgs.systemd}/bin/systemd-run \
      --quiet --wait --collect --pty \
      --unit=nookbridge-provision.service \
      --uid=nookbridge \
      --gid=nookbridge-clients \
      --property=WorkingDirectory=/var/lib/nookbridge \
      --property=Environment=HOME=/var/lib/nookbridge \
      --property=Environment=PATH=${pkgs.coreutils}/bin \
      --setenv=NOOKBRIDGE_ENABLE_LIVE_AUTH=1 \
      --property=LoadCredential=nookbridge-db-key:${credentialPath} \
      --property=ProtectSystem=strict \
      --property=ProtectHome=yes \
      --property=PrivateTmp=yes \
      --property=PrivateDevices=yes \
      --property=NoNewPrivileges=yes \
      --property=RestrictAddressFamilies='AF_UNIX AF_INET AF_INET6' \
      --property=RestrictNamespaces=yes \
      --property=ProtectKernelTunables=yes \
      --property=ProtectKernelModules=yes \
      --property=ProtectControlGroups=yes \
      --property=LockPersonality=yes \
      --property=RestrictRealtime=yes \
      --property=RestrictSUIDSGID=yes \
      --property=CapabilityBoundingSet= \
      --property=AmbientCapabilities= \
      --property=SystemCallArchitectures=native \
      --property=ReadWritePaths=/var/lib/nookbridge \
      --property=UMask=0077 \
      --property=TimeoutStartSec=10min \
      --property=RuntimeMaxSec=10min \
      ${nookbridge}/bin/nookbridge-provision-cli
  '';
  syncCommand = pkgs.writeShellScriptBin "nookbridge-sync" ''
    set -eu
    if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' 'nookbridge-sync: must be run as root' >&2
      exit 77
    fi
    exec ${pkgs.systemd}/bin/systemd-run \
      --quiet --wait --collect --pty \
      --unit=nookbridge-sync.service \
      --uid=nookbridge \
      --gid=nookbridge-clients \
      --property=WorkingDirectory=/var/lib/nookbridge \
      --property=Environment=HOME=/var/lib/nookbridge \
      --property=Environment=PATH=${pkgs.coreutils}/bin \
      --setenv=NOOKBRIDGE_ENABLE_LIVE_SYNC=1 \
      --property=LoadCredential=nookbridge-db-key:${credentialPath} \
      --property=ProtectSystem=strict \
      --property=ProtectHome=yes \
      --property=PrivateTmp=yes \
      --property=PrivateDevices=yes \
      --property=NoNewPrivileges=yes \
      --property=RestrictAddressFamilies='AF_UNIX AF_INET AF_INET6' \
      --property=RestrictNamespaces=yes \
      --property=ProtectKernelTunables=yes \
      --property=ProtectKernelModules=yes \
      --property=ProtectControlGroups=yes \
      --property=LockPersonality=yes \
      --property=RestrictRealtime=yes \
      --property=RestrictSUIDSGID=yes \
      --property=CapabilityBoundingSet= \
      --property=AmbientCapabilities= \
      --property=SystemCallArchitectures=native \
      --property=ReadWritePaths=/var/lib/nookbridge \
      --property=UMask=0077 \
      --property=TimeoutStartSec=10min \
      --property=RuntimeMaxSec=10min \
      ${nookbridge}/bin/nookbridge-sync-cli
  '';
in {
  options.extra-services.nookbridge = {
    enable = mkEnableOption "NookBridge read-write Unix-socket service with settings-gated delete";

    settings = mkOption {
      type = types.nullOr settingsSpec.settingsType;
      default = null;
      description = ''
        Inline NookBridge settings rendered to the service JSON file. Set
        `settingsFile = null` when using this source. The schema is closed to
        the daemon's version-1 defaults and override fields.
      '';
    };

    settingsFile = mkOption {
      type = types.nullOr types.path;
      default = ./nookbridge/settings.json;
      description = ''
        Declarative JSON settings file copied to /etc/nookbridge/settings.json.
        Set this to null when using inline `settings`. The file is still
        validated fail-closed by nookd before runtime construction.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      nookbridge
      provisionCommand
      syncCommand
    ];

    users.groups.nookbridge = {};
    users.groups.nookbridge-clients = {};
    users.groups.nookbridge-operators = {};
    users.users.nookbridge = {
      isSystemUser = true;
      group = "nookbridge";
      home = "/var/lib/nookbridge";
      createHome = false;
      shell = "${pkgs.shadow}/bin/nologin";
      extraGroups = [ "nookbridge-clients" ];
    };

    # The source secret is root-readable only. systemd reads it as the
    # manager, then presents a private copy through $CREDENTIALS_DIRECTORY;
    # the daemon never receives the sops-nix path or a credential in argv/env.
    sops.secrets."nookbridge-db-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "nookd.service" ];
    };

    environment.etc."nookbridge/service.json" = {
      source = ./nookbridge/service.json;
      mode = "0644";
    };

    environment.etc."nookbridge/settings.json" = {
      source = settingsSource;
      user = "root";
      group = "root";
      mode = "0640";
    };

    systemd.services.nookd = {
      description = "NookBridge read-write Unix-socket service with settings-gated delete";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      restartTriggers = [
        nookbridge
        (builtins.readFile ./nookbridge/service.json)
        settingsContent
      ];
      serviceConfig = {
        Type = "simple";
        User = "nookbridge";
        Group = "nookbridge-clients";
        WorkingDirectory = "/var/lib/nookbridge";
        Environment = "HOME=/var/lib/nookbridge";
        # The source credential is intentionally root-only. systemd's
        # LoadCredential= reads it as the manager and presents the daemon's
        # private copy; checking credentialPath here would run as nookbridge
        # and reject the correctly protected 0400 source file.
        ExecStartPre = [
          "${pkgs.coreutils}/bin/test -r /etc/nookbridge/service.json"
        ];
        ExecStart = "${nookbridge}/bin/nookd --config /etc/nookbridge/service.json";
        LoadCredential = [
          "nookbridge-db-key:${credentialPath}"
          "nookbridge-settings:${settingsPath}"
        ];
        StateDirectory = "nookbridge";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "nookbridge";
        RuntimeDirectoryMode = "0750";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallArchitectures = "native";
        ReadWritePaths = [ "/var/lib/nookbridge" "/run/nookbridge" ];
        # Keep the socket private from other users while allowing the
        # nookbridge-clients group to connect.
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "15s";
      };
    };

    assertions = [
      {
        assertion = serviceConfig.stateDir == "/var/lib/nookbridge";
        message = "NookBridge stateDir is fixed to /var/lib/nookbridge";
      }
      {
        assertion = serviceConfig.socketPath == "/run/nookbridge/nookbridge.sock";
        message = "NookBridge socketPath is fixed to /run/nookbridge/nookbridge.sock";
      }
      {
        assertion = serviceConfig.socketGroup == "nookbridge-clients";
        message = "NookBridge socketGroup is fixed to nookbridge-clients";
      }
      {
        assertion = serviceConfig.backend == "systemd-credential";
        message = "NookBridge backend is fixed to systemd-credential";
      }
      {
        assertion = serviceConfig.credentialName == "nookbridge-db-key";
        message = "NookBridge credentialName is fixed to nookbridge-db-key";
      }
      {
        assertion = serviceConfig.settingsBackend == "nix";
        message = "NookBridge settingsBackend is fixed to nix";
      }
      {
        assertion = settingsSpec.sourceSelectionValid cfg.settings cfg.settingsFile;
        message = "Configure exactly one of extra-services.nookbridge.settings or settingsFile";
      }
      {
        assertion = serviceConfig.readPolicy == [ "notes.search" "notes.status" "notes.list_notebooks" "notes.get" "notes.path_diagnostic" "notes.create" "notes.append" "notes.update" "notes.delete" "notes.sync" ];
        message = "NookBridge readPolicy is fixed to the read-write-with-bounded-delete MCP RPC methods";
      }
    ] ++ map (message: {
      assertion = false;
      inherit message;
    }) (settingsSpec.inlineSettingsErrors cfg.settings);
  };
}
