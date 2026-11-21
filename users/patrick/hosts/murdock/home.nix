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
  # Hermes Desktop as a remote-only client of the dashboard on the Hermes host.
  # This installs the pinned package directly instead of enabling
  # programs.hermes-agent or services.hermes-agent, so this Nix config enables no
  # local backend service and ships exactly one launcher and desktop entry. The
  # remote connection is saved in Desktop's own connection config (remote mode,
  # OAuth auth). Desktop starts a local backend only when no saved remote
  # connection exists, so that saved connection must stay in place. Do not
  # inject HERMES_DESKTOP_REMOTE_URL or HERMES_DESKTOP_REMOTE_TOKEN at launch:
  # when the URL variable is set, Desktop overrides the saved connection and
  # falls back to token mode, which the dashboard rejects with no_cookie on REST
  # calls.
  #
  # v0.23.0 replaced the desktop package's hand-pinned Electron headers hash
  # with nixpkgs' `electron.headers`, so the old fetchurl shim is gone. The
  # flake input follows nixpkgs-unstable, so the package's default `electron` is
  # already the unstable one and needs no override.
  hermes-desktop-remote =
    inputs.nix-hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;
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
    hermes-desktop-remote
    pkgs-unstable.opencode-desktop
    # pkgs-unstable.freecad
    pkgs-unstable.telegram-desktop
  ];

  services.flatpak.enable = true;

  # Declaring `remotes` replaces the module's flathub default, so flathub has to be
  # listed explicitly or Notesnook loses its origin. The Kyllene remote points at the
  # published .flatpakrepo, which carries the repo's GPG key inline — no separate
  # gpg-import needed. Key fingerprint 91339D076D09F4C359CD676740144D773675CED0.
  services.flatpak.remotes = [
    {
      name = "flathub";
      location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
    }
    {
      name = "kyllene";
      location = "https://kyllene.app/kyllene.flatpakrepo";
    }
  ];

  services.flatpak.packages = [
    "com.notesnook.Notesnook"
    # Auto-updating (Patrick's choice): no `commit` pin, so the daily update job
    # picks up new Kyllene releases along with everything else.
    {
      appId = "app.kyllene.Kyllene";
      origin = "kyllene";
    }
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
