{ lib }:

let
  inherit (lib) mkOption types;
  operationNames = [ "read" "edit" "create" "delete" ];
  defaultFor = name: name == "read";

  settingsDefaultsType = types.submodule {
    options = builtins.listToAttrs (map (name: {
      inherit name;
      value = mkOption {
        type = types.bool;
        default = defaultFor name;
        description = "Default permission for the ${name} operation.";
      };
    }) operationNames);
  };

  settingsOverrideType = types.submodule {
    options = {
      notebooks = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Notebook glob selectors for this settings override.";
      };
      notes = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Note glob selectors for this settings override.";
      };
      read = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Optional read permission override.";
      };
      edit = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Optional edit permission override.";
      };
      create = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Optional create permission override.";
      };
      delete = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Optional delete permission override.";
      };
    };
  };

  settingsType = types.submodule {
    options = {
      upload = mkOption {
        type = types.enum [ "attributed" "allow" ];
        default = "attributed";
        description = ''
          Whether a sync may upload queued changes that cannot be attributed to
          the MCP writer. `attributed` keeps the strict marker gate; `allow`
          releases the queue, which uploads the vault as a whole.
        '';
      };
      defaults = mkOption {
        type = settingsDefaultsType;
        default = { };
        description = "Default permissions for all notes.";
      };
      overrides = mkOption {
        type = types.listOf settingsOverrideType;
        default = [ ];
        description = "Ordered, notebook- or note-scoped permission overrides.";
      };
    };
  };

  cleanNullAttrs = attrs: lib.filterAttrs (_name: value: value != null) attrs;
  overrideHas = name: override:
    builtins.hasAttr name override && builtins.getAttr name override != null;
  selectorNames = [ "notebooks" "notes" ];
  overrideOperationNames = operationNames;
  selectorCount = override:
    builtins.length (builtins.filter (value: value) (map (name: overrideHas name override) selectorNames));
  operationCount = override:
    builtins.length (builtins.filter (value: value) (map (name: overrideHas name override) overrideOperationNames));

  inlineSettingsErrors = settings:
    if settings == null then [ ] else
      lib.concatLists (map (override:
        (lib.optional (selectorCount override != 1)
          "Each NookBridge settings override must specify exactly one of notebooks or notes.")
        ++ (lib.optional (operationCount override < 1)
          "Each NookBridge settings override must set at least one permission operation.")
      ) settings.overrides);

  sourceSelectionValid = settings: settingsFile:
    (settings != null) == (settingsFile == null);

  renderSettings = settings:
    let
      defaults = settings.defaults;
      overrides = builtins.toJSON (map cleanNullAttrs settings.overrides);
    in
    (builtins.concatStringsSep "\n" [
      "{"
      "  \"version\": 1,"
      "  \"upload\": ${builtins.toJSON settings.upload},"
      "  \"defaults\": {"
      "    \"read\": ${builtins.toJSON defaults.read},"
      "    \"edit\": ${builtins.toJSON defaults.edit},"
      "    \"create\": ${builtins.toJSON defaults.create},"
      "    \"delete\": ${builtins.toJSON defaults.delete}"
      "  },"
      "  \"overrides\": ${overrides}"
      "}"
    ]) + "\n";
in
{
  inherit settingsType renderSettings inlineSettingsErrors sourceSelectionValid;
}
