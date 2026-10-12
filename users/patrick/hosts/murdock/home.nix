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
  # This overrides the pinned package instead of enabling programs.hermes-agent
  # or services.hermes-agent, so Murdock runs no local backend and ships exactly
  # one launcher and desktop entry. The package's own `extraRun` hook exists for
  # this: the token is read at launch from the sops-managed file, never passed
  # through `--set` (which would write it to the Nix store), an argument, or a
  # log. The launcher stops rather than starting a local backend on failure.
  hermesDesktopTokenFile = "/run/secrets/hermes-desktop-session-token";
  # The pinned v2026.9.24 desktop package has a stale fixed hash for this
  # versioned Electron headers URL. Repackage the matching headers already
  # pinned by nixpkgs, preserving the archive root expected by upstream.
  electronHeadersArchive = pkgs-unstable.runCommandLocal "electron-${pkgs-unstable.electron.version}-nodedir-headers.tar.gz" { } ''
    set -euo pipefail
    mkdir -p node_headers
    cp -a ${pkgs-unstable.electron.headers}/. node_headers/
    tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner -cf - node_headers | ${pkgs-unstable.gzip}/bin/gzip -n > "$out"
  '';
  hermesDesktopBuildPkgs = pkgs-unstable // {
    fetchurl = args:
      if (args.url or null) == "https://artifacts.electronjs.org/headers/dist/v${pkgs-unstable.electron.version}/node-v${pkgs-unstable.electron.version}-headers.tar.gz"
        && (args.sha256 or null) == "sha256-f8bSbLRmtbP93CJAvEBs+sHWDZ1xP2bcpLhC1EnOmZU="
      then electronHeadersArchive
      else pkgs-unstable.fetchurl args;
  };
  hermes-desktop-remote = inputs.nix-hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop.override {
    pkgs = hermesDesktopBuildPkgs;
    electron = pkgs-unstable.electron;
    extraEnv.HERMES_DESKTOP_REMOTE_URL = "http://hermes.skink-galaxy.ts.net:9119";
    extraRun = [
      ''
        if [ ! -r ${lib.escapeShellArg hermesDesktopTokenFile} ]; then
          echo "hermes-desktop: cannot read the session token at ${hermesDesktopTokenFile}." >&2
          exit 1
        fi
        HERMES_DESKTOP_REMOTE_TOKEN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < ${lib.escapeShellArg hermesDesktopTokenFile})"
        if [ -z "$HERMES_DESKTOP_REMOTE_TOKEN" ]; then
          echo "hermes-desktop: the session token at ${hermesDesktopTokenFile} is empty." >&2
          exit 1
        fi
        export HERMES_DESKTOP_REMOTE_TOKEN
      ''
    ];
  };
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
