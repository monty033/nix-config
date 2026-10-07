{ lib, config, pkgs, inputs, outputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  opencode-v2 = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-v2;
  opencode-goal-plugin = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-goal-plugin;
  # Connects the OpenCode TUI to the Hermes server over Tailscale. The
  # password is read at run time from a sops-managed file, never from Nix.
  opencode-hermes = pkgs.writeShellScriptBin "opencode-hermes" ''
    set -eu
    exec ${pkgs.systemd}/bin/systemd-run --user --same-dir --pty --wait --collect \
      --property=EnvironmentFile=/run/secrets/opencode-server-env \
      -- ${pkgs.runtimeShell} -c '
        if [ -z "''${OPENCODE_SERVER_PASSWORD:-}" ]; then
          printf "%s\n" "OpenCode server password missing or empty" >&2
          exit 1
        fi
        export OPENCODE_PASSWORD="$OPENCODE_SERVER_PASSWORD"
        exec "$@"
      ' opencode-hermes ${opencode-v2}/bin/opencode --server http://hermes.skink-galaxy.ts.net:4096 "$@"
  '';
in
{
  imports = [ ../../common/home.nix ];

  xdg.configFile."discoverrc".text = ''
    [Global]
    UseUnattendedUpdates=true
  '';

  home.packages = with pkgs; [
    kdePackages.kate
    google-chrome
    signal-desktop
    simplex-chat-desktop
    obsidian
    nixos-generators
    pkgs-unstable.code-cursor
    pkgs-unstable.claude-code
    pkgs-unstable.nodejs_22
    pkgs-unstable.codex
    opencode-v2
    opencode-goal-plugin
    opencode-hermes
    pkgs-unstable.opencode-desktop
    # pkgs-unstable.freecad
    pkgs-unstable.telegram-desktop
  ];

  services.flatpak.enable = true;

  services.flatpak.packages = [
    "com.notesnook.Notesnook"
  ];

  services.flatpak.update.auto = {
    enable = true;
    onCalendar = "daily";
  };

  services.syncthing = {
    enable = true;
    settings.gui = {
      user = "patrick";
      password = "$2b$05$HyI3HBR7.6RpSjKnXJVXgOVfq/Kvmc6sDOpnYJ8EbY5U199kmLKZG";
    };
  };

  programs.plasma = {
    enable = true;

    workspace = {
      theme = "breeze-dark";
    };

    panels = [
      {
        location = "bottom";
        widgets = [
          "org.kde.plasma.kickoff"
          {
            name = "org.kde.plasma.icontasks";
            config = {
              General = {
                launchers = [
                  "applications:org.kde.dolphin.desktop"
                  "applications:org.kde.konsole.desktop"
                  "applications:firefox.desktop"
                  "applications:codium.desktop"
                  "applications:com.notesnook.Notesnook.desktop"
                ];
              };
            };
          }
          "org.kde.plasma.marginsseparator"
          "org.kde.plasma.systemtray"
          "org.kde.plasma.digitalclock"
        ];
      }
    ];

    configFile = {
      kcminputrc = {
        Keyboard = {
          NumLock = 0;
        };
      };
      ksmserverrc = {
        General = {
          loginMode = "restorePreviousLogout";
        };
      };
    };
  };

  programs.vscodium = {
    enable = true;
    package = pkgs-unstable.vscodium;
    profiles.default.extensions = with pkgs.vscode-extensions; [
      jnoortheen.nix-ide
      redhat.ansible
      redhat.vscode-yaml
      ms-python.python
      samuelcolvin.jinjahtml
    ];
  };
}
