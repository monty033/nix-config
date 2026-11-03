{ lib, pkgs }:

let
  spec = import ../modules/nookbridge/settings.nix { inherit lib; };
  inline = {
    upload = "allow";
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
      {
        notes = [ "note-1" ];
        edit = true;
      }
    ];
  };
  rendered = builtins.fromJSON (spec.renderSettings inline);
  validErrors = spec.inlineSettingsErrors inline;
  invalidErrors = spec.inlineSettingsErrors {
    defaults = inline.defaults;
    overrides = [
      {
        notebooks = [ "Financial" ];
        notes = [ "note-1" ];
      }
    ];
  };
  renderedText = spec.renderSettings inline;
  expectedDefaultsOrder = ''
    {
      "version": 1,
      "upload": "allow",
      "defaults": {
        "read": true,
        "edit": true,
        "create": false,
        "delete": false
      },
      "overrides": [{"delete":false,"notebooks":["Financial"]},{"edit":true,"notes":["note-1"]}]
    }
  '';
in
pkgs.runCommand "nookbridge-settings-module-check" { } ''
  test ${builtins.toString (if rendered.version == 1 then 1 else 0)} = 1
  test ${builtins.toString (if rendered.upload == "allow" then 1 else 0)} = 1
  test ${builtins.toString (if rendered.defaults.edit then 1 else 0)} = 1
  test ${builtins.toString (if rendered.overrides == [
    { notebooks = [ "Financial" ]; delete = false; }
    { notes = [ "note-1" ]; edit = true; }
  ] then 1 else 0)} = 1
  test ${builtins.toString (if validErrors == [ ] then 1 else 0)} = 1
  test ${builtins.toString (if invalidErrors != [ ] then 1 else 0)} = 1
  test ${builtins.toString (if builtins.match ".*null.*" renderedText == null then 1 else 0)} = 1
  test ${builtins.toString (if renderedText == expectedDefaultsOrder then 1 else 0)} = 1
  touch $out
''
