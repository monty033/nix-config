{ lib, pkgs, inputs }:

let
  baseModules = [
    inputs.sops-nix.nixosModules.sops
    ../modules/nookbridge.nix
  ];
  inlineSystem = lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit inputs; };
    modules = baseModules ++ [
      ({ ... }: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        extra-services.nookbridge.enable = true;
        extra-services.nookbridge.settingsFile = null;
        extra-services.nookbridge.settings = {
          defaults = {
            read = true;
            edit = true;
            create = false;
            delete = false;
          };
          overrides = [
            {
              notebooks = [ "Financial" ];
              delete = false;
            }
          ];
        };
      })
    ];
  };
  fileSystem = lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit inputs; };
    modules = baseModules ++ [
      ({ ... }: {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        extra-services.nookbridge.enable = true;
        extra-services.nookbridge.settings = null;
        extra-services.nookbridge.settingsFile = ../modules/nookbridge/settings.json;
      })
    ];
  };
  inlineCfg = inlineSystem.config;
  fileCfg = fileSystem.config;
  inlineSettings = inlineCfg.extra-services.nookbridge;
  inlineSettingsEtc = inlineCfg.environment.etc."nookbridge/settings.json";
  fileSettingsEtc = fileCfg.environment.etc."nookbridge/settings.json";
  inlineSettingsContent = sourceSpec.renderSettings inlineSettings.settings;
  fileSettingsContent = builtins.readFile ../modules/nookbridge/settings.json;
  inlineJson = builtins.fromJSON inlineSettingsContent;
  allowJson = builtins.fromJSON (
    sourceSpec.renderSettings (inlineSettings.settings // { upload = "allow"; })
  );
  fileJson = builtins.fromJSON (builtins.readFile fileSettingsEtc.source);
  inlineRestartTriggers = inlineCfg.systemd.services.nookd.restartTriggers;
  fileRestartTriggers = fileCfg.systemd.services.nookd.restartTriggers;
  sourceSpec = import ../modules/nookbridge/settings.nix { inherit lib; };
  inlineSourceValid = sourceSpec.sourceSelectionValid { } null;
  fileSourceValid = sourceSpec.sourceSelectionValid null ../modules/nookbridge/settings.json;
  bothSourcesValid = sourceSpec.sourceSelectionValid { } ../modules/nookbridge/settings.json;
  noSourceValid = sourceSpec.sourceSelectionValid null null;
  invalidOverrideErrors = sourceSpec.inlineSettingsErrors {
    defaults = { };
    overrides = [
      {
        notebooks = [ "Financial" ];
        notes = [ "note-1" ];
      }
    ];
  };
  invalidOperationErrors = sourceSpec.inlineSettingsErrors {
    defaults = { };
    overrides = [
      { notebooks = [ "Financial" ]; }
    ];
  };
in
pkgs.runCommand "nookbridge-settings-module-integration-check" {
  nativeBuildInputs = [ pkgs.jq ];
} ''
  test ${builtins.toString (if inlineSettings.settingsFile == null then 1 else 0)} = 1
  test ${builtins.toString (if inlineJson.defaults.edit then 1 else 0)} = 1
  ${pkgs.jq}/bin/jq -e '
    .version == 1 and
    .upload == "attributed" and
    .defaults == {read: true, edit: true, create: false, delete: false} and
    .overrides == [{notebooks: ["Financial"], delete: false}]
  ' ${inlineSettingsEtc.source} > /dev/null
  test ${builtins.toString (if allowJson.upload == "allow" then 1 else 0)} = 1
  ${pkgs.jq}/bin/jq -e '.upload == null' ${fileSettingsEtc.source} > /dev/null
  test ${builtins.toString (if fileJson.defaults.delete then 1 else 0)} = 1
  ${pkgs.jq}/bin/jq -e '.overrides == [{notebooks: ["Financial"], delete: false}]' ${fileSettingsEtc.source} > /dev/null
  test ${builtins.toString (if builtins.elem inlineSettingsContent inlineRestartTriggers then 1 else 0)} = 1
  test ${builtins.toString (if builtins.elem fileSettingsContent fileRestartTriggers then 1 else 0)} = 1
  test ${builtins.toString (if inlineSourceValid then 1 else 0)} = 1
  test ${builtins.toString (if fileSourceValid then 1 else 0)} = 1
  test ${builtins.toString (if !bothSourcesValid then 1 else 0)} = 1
  test ${builtins.toString (if !noSourceValid then 1 else 0)} = 1
  test ${builtins.toString (if invalidOverrideErrors != [ ] then 1 else 0)} = 1
  test ${builtins.toString (if invalidOperationErrors != [ ] then 1 else 0)} = 1
  test ${lib.escapeShellArg inlineSettingsEtc.user} = root
  test ${lib.escapeShellArg inlineSettingsEtc.group} = root
  test ${lib.escapeShellArg inlineSettingsEtc.mode} = 0640
  test ${lib.escapeShellArg fileSettingsEtc.user} = root
  test ${lib.escapeShellArg fileSettingsEtc.group} = root
  test ${lib.escapeShellArg fileSettingsEtc.mode} = 0640
  touch $out
''
