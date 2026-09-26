{ config, pkgs, lib, modulesPath, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  nookbridge = pkgs.callPackage ../../../packages/nookbridge.nix { inherit inputs; };
  hermesBasePkgs = import inputs.nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  hermesBasePython = hermesBasePkgs.python312.pkgs;
  fastembed = hermesBasePython.fastembed.overridePythonAttrs (old: {
    # Hermes's full sealed environment already supplies the rest of
    # FastEmbed's runtime dependencies. Add only packages absent there to
    # avoid collisions in nix-hermes-agent's extraPythonPackages guard.
    dependencies = builtins.filter
      (dep: builtins.elem (lib.getName dep) [
        "loguru"
        "mmh3"
        "py-rust-stemmers"
        "pystemmer"
        "snowballstemmer"
      ])
      old.dependencies;
    dontCheckRuntimeDeps = true;
    pythonImportsCheck = [];
  });
  sqliteVec = hermesBasePython.sqlite-vec.overridePythonAttrs (_: {
    # nixpkgs 26.05 omits NumPy from sqlite-vec's runtime-check inputs;
    # Mnemosyne propagates NumPy explicitly below.
    dontCheckRuntimeDeps = true;
  });
  python312 = pkgs.python312.override {
    packageOverrides = _self: super: {
      sse-starlette = super.sse-starlette.overridePythonAttrs (_: { dontCheckRuntimeDeps = true; });
      aiohttp = super.aiohttp.overridePythonAttrs (_: {
        doCheck = false;
        doInstallCheck = false;
      });
      pymupdf = super.pymupdf.overridePythonAttrs (_: { doCheck = false; });
      pdfplumber = super.pdfplumber.overridePythonAttrs (_: { doCheck = false; });
      # SciPy's upstream suite launches six xdist workers and exhausts the
      # 8GB build host; runtime artifacts are unaffected by skipping checks.
      scipy = super.scipy.overridePythonAttrs (_: { doCheck = false; });
      # Use the official CPython 3.12 manylinux wheel. Building mypy 1.20.1
      # from source invokes mypyc and OOMs even with a serialized build on this
      # host; the wheel already contains the compiled extension.
      mypy = super.mypy.overridePythonAttrs (_: {
        version = "1.20.1";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/b2/c6/75e969781c2359b2f9c15b061f28ec6d67c8b61865ceda176e85c8e7f2de/mypy-1.20.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl";
          hash = "sha256-7zRhsa1c1EblQAFukLWYRlft2jn5gvTMRcoxe2KPWjc";
        };
        format = "wheel";
        pyproject = null;
        propagatedBuildInputs = with _self; [
          typing-extensions
          mypy-extensions
          pathspec
          librt
        ];
        doCheck = false;
      });
      pypdfium2 = super.pypdfium2.overridePythonAttrs (_: { doCheck = false; doInstallCheck = false; });
      apscheduler = super.apscheduler.overridePythonAttrs (_: { doCheck = false; });
      black = super.black.overridePythonAttrs (_: { doCheck = false; });
      httpx = super.httpx.overridePythonAttrs (_: { doCheck = false; });
      httpbin = super.httpbin.overridePythonAttrs (_: { doCheck = false; });
      flasgger = super.flasgger.overridePythonAttrs (_: { doCheck = false; });
      starlette = super.starlette.overridePythonAttrs (_: { doCheck = false; });
      fastapi = super.fastapi.overridePythonAttrs (_: { doCheck = false; });
      fastapi-cli = super.fastapi-cli.overridePythonAttrs (_: { doCheck = false; });
      ipython = super.ipython.overridePythonAttrs (_: { doCheck = false; });
      baize = super.baize.overridePythonAttrs (_: { doCheck = false; });
    };
  };
  hermesPython = lib.getOutput "out" (python312.withPackages (ps: [
    ps.pandas
    ps.pdfplumber
    ps.openpyxl
    ps.reportlab
    ps.fastapi
    ps.uvicorn
    ps.ptyprocess
    ps.python-telegram-bot
    ps.mcp
    ps.icalendar
    ps.pymupdf
    ps.pytesseract
    ps.pillow
    ps.darkdetect
    agentmail
  ]));
  agentmail = python312.pkgs.buildPythonPackage rec {
    pname = "agentmail";
    version = "0.5.0";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/d9/f0/4c7dbbd1db1b820eb1206636b6be146655cff497a6d7739669432d8f0553/agentmail-0.5.0-py3-none-any.whl";
      hash = "sha256-ALyfhuTG/i9aMibBZg3boq3LgGPIBUD+Pp5WT+KFsjM=";
    };
    format = "wheel";
    propagatedBuildInputs = with python312.pkgs; [
      httpx pydantic websockets
    ];
    doCheck = false;
  };
  # Mnemosyne is not in the pinned nixpkgs set. Build both wheels from source.
  # Include the embeddings extra because mnemosyne-hermes declares it as a
  # runtime dependency. The host now has enough RAM and swap for this closure;
  # retain the prebuilt mypy wheel and serialized build settings as safeguards.
  mnemosyneMemory = hermesBasePython.buildPythonPackage rec {
    pname = "mnemosyne-memory";
    version = "3.15.1";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/48/1b/d1ee3346df25396f9aea6aff2518823a815142b2a92638d06c9cd7c5015c/mnemosyne_memory-3.15.1-py3-none-any.whl";
      hash = "sha256-vHmmJ30hlbulkSMpKSTo/1QhNXxY7lQ6IwVLjdl9dIQ=";
    };
    format = "wheel";
    propagatedBuildInputs = [
      sqliteVec
      fastembed
    ];
    doCheck = false;
    dontCheckRuntimeDeps = true;
  };
  mnemosyneHermes = hermesBasePython.buildPythonPackage rec {
    pname = "mnemosyne-hermes";
    version = "0.5.0";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/5d/64/12c46a5dcc02ad23c7c37d0a6b55a8dfc3cfbdc6d64c3cdeaa2b52e23e99/mnemosyne_hermes-0.5.0-py3-none-any.whl";
      hash = "sha256-z6vtLygWxr+ypkBJjLMzjo3r1p4XiqCrYZV2iJljaL8=";
    };
    format = "wheel";
    propagatedBuildInputs = [
      mnemosyneMemory
    ];
    doCheck = false;
    dontCheckRuntimeDeps = true;
  };
  mnemosyneHermesPlugin = pkgs.runCommand "mnemosyne-hermes-plugin" { } ''
    mkdir -p $out
    cp -r ${mnemosyneHermes}/lib/python3.12/site-packages/mnemosyne_hermes/* $out/
    chmod -R a+rX $out
  '';
  # Claude Subscription DirectSDK (experimental) — routes Hermes inference
  # through the official Claude Code CLI so a Claude Pro/Max subscription can
  # serve as a conversation model. Pinned by COMMIT, not version: upstream
  # 0.3.0 spans materially different prompt-cache implementations, so the tag
  # alone is not a safe pin.
  #
  # The plugin declares no Python dependencies and Hermes' plugin loader
  # imports the directory directly (verified by running it from a plugin
  # directory with no PYTHONPATH changes), so no extraPythonPackages entry is
  # needed. Runtime prerequisites are the `claude` CLI — provided above as
  # pkgs-unstable.claude-code — and a logged-in subscription in the hermes
  # user's ~/.claude. It is enabled only as an ADDITIONAL selectable route;
  # model.default/model.provider stay on openai-codex.
  claudeSubscriptionDirectsdkSrc = pkgs.fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-plugin-claude-subscription-directsdk";
    rev = "602393b6d3ea148bc618cd23da1a13fa332e1433";
    hash = "sha256-Ll0bmt+UJONvDPrfFTECVvlut/MgQIBmInYgtjYAoC0=";
  };
  claudeSubscriptionDirectsdkPlugin =
    pkgs.runCommand "claude-subscription-directsdk-hermes-plugin" { } ''
      cp -r ${claudeSubscriptionDirectsdkSrc} $out
      chmod -R a+rX $out
    '';
  # Hermes' sealed venv does not include external plugin packages. Keep the
  # closure on PYTHONPATH for the gateway only; do not alter global Python state.
  mnemosynePythonPath = lib.makeSearchPath python312.sitePackages
    (python312.pkgs.requiredPythonModules [ mnemosyneMemory mnemosyneHermes ]);
  hermes-scripts = pkgs.runCommandLocal "hermes-scripts" { } ''
    mkdir -p $out/dns_migration
    install -m 0555 ${../../../scripts/bernie/model_worker.py} $out/model_worker.py
    install -m 0555 ${../../../scripts/dns_migration/switch_dns_path.py} $out/dns_migration/switch_dns_path.py
  '';
  calendarPython = python312.withPackages (ps: [ ps.icalendar ]);
  familyCalendarSource = ../../../scripts/calendar-publish/family-calendar-router;
  familyCalendarPublisher = pkgs.writeShellScriptBin "family-calendar-publisher" ''
    export PYTHON=${calendarPython}/bin/python3
    export FLOCK=${pkgs.util-linux}/bin/flock
    export TIMEOUT=${pkgs.coreutils}/bin/timeout
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.openssh pkgs.curl pkgs.util-linux ]}
    exec ${pkgs.bash}/bin/bash ${familyCalendarSource}/router.sh
  '';
  sportsCalendarSource = ../../../scripts/calendar-publish/philly-sports-cal;
  sportsCalendarPublisher = pkgs.writeShellScriptBin "sports-calendar-publisher" ''
    export PYTHON=${calendarPython}/bin/python3
    export RSYNC=${pkgs.rsync}/bin/rsync
    export SSH=${pkgs.openssh}/bin/ssh
    export MKDIR=${pkgs.coreutils}/bin/mkdir
    export MKTemp=${pkgs.coreutils}/bin/mktemp
    export MV=${pkgs.coreutils}/bin/mv
    export RM=${pkgs.coreutils}/bin/rm
    export FLOCK=${pkgs.util-linux}/bin/flock
    exec ${pkgs.bash}/bin/bash ${sportsCalendarSource}/deploy.sh
  '';
  forgejo-credential-helper = pkgs.writeShellScript "forgejo-credential-helper" ''
    host=""
    protocol=""
    while IFS="=" read -r key value; do
      case "$key" in
        host) host="$value" ;;
        protocol) protocol="$value" ;;
      esac
    done

    if [ "$protocol" = "https" ] && [ "$host" = "git.montycasa.net" ]; then
      printf '%s\n' 'username=openclaw'
      printf 'password='
      cat ${config.sops.secrets."forgejo-token".path}
    fi
  '';
in

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    inputs.nix-hermes-agent.nixosModules.default
  ];

  nixpkgs.overlays = [
    (final: prev: {
      python312 = prev.python312.override {
        packageOverrides = _self: super:
          (builtins.mapAttrs (_name: val:
            if builtins.isAttrs val && val ? overrideAttrs
            then val.overrideAttrs (_: { doCheck = false; doInstallCheck = false; })
            else val
          ) super) // {
            # Hermes-Relay uses the global python312Packages set rather than
            # the local Hermes environment above. Keep its mypy dependency on
            # the same prebuilt wheel so mypyc is never compiled twice.
            mypy = super.mypy.overridePythonAttrs (_: {
              version = "1.20.1";
              src = pkgs.fetchurl {
                url = "https://files.pythonhosted.org/packages/b2/c6/75e969781c2359b2f9c15b061f28ec6d67c8b61865ceda176e85c8e7f2de/mypy-1.20.1-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl";
                hash = "sha256-7zRhsa1c1EblQAFukLWYRlft2jn5gvTMRcoxe2KPWjc";
              };
              format = "wheel";
              pyproject = null;
              propagatedBuildInputs = with _self; [
                typing-extensions
                mypy-extensions
                pathspec
                librt
              ];
              doCheck = false;
            });
            scipy = super.scipy.overridePythonAttrs (_: { doCheck = false; });
          };
      };
    })
  ];

  networking.hostName = "hermes";
  networking.firewall.allowedTCPPorts = [ 8642 8644 9119 ];
  # WebUI is bound to the Hermes LAN address; keep its direct listener scoped
  # to the LAN interface for the local-proxy reverse proxy.
  networking.firewall.interfaces."eth0".allowedTCPPorts = [ 8787 ];

  # python3.12 doc build broken in nixpkgs 26.05 (upstream issue #529084)
  documentation.man.enable = false;
  documentation.doc.enable = false;

  extra-services.tailscale = {
    enable = true;
    lxc = true;
  };
  extra-services.host-checkin.enable = true;
  extra-services.hermes-relay.enable = true;
  extra-services.nookbridge = {
    enable = true;
    # Keep the deployed policy declarative in Nix rather than sourcing JSON.
    settingsFile = null;
    settings = {
      defaults = {
        read = true;
        edit = true;
        create = true;
        delete = true;
      };
      overrides = [
        { notebooks = [ "Financial" ]; delete = false; }
      ];
    };
  };
  # When extraPlugins changes (e.g. adding/removing Hermes-Relay),
  # restart both hermes-agent and hermes-dashboard so the loader picks
  # up the new plugin tree. Without this, plugin enable requires a
  # manual `systemctl restart hermes-agent hermes-dashboard` after
  # deploy. nix-hermes-agent's own module does not declare these
  # triggers, so we add them here. Cited by Luna xhigh review r3.
  systemd.services.hermes-agent.restartTriggers =
    [ config.services.hermes-agent.package ]
    ++ config.services.hermes-agent.extraPlugins
    # The Hermes module merges settings into mutable config.yaml during
    # activation. Restart when the memory provider/settings change so a
    # provider cutover is effective without a manual systemctl command.
    ++ [ (builtins.toJSON config.services.hermes-agent.settings.memory) ]
    ++ [ (builtins.toJSON config.services.hermes-agent.settings.mcp_servers) nookbridge ];
  # Memory databases contain private user context. Keep files created by the
  # service private even though the parent state directory is group-accessible.
  systemd.services.hermes-agent.serviceConfig.UMask = lib.mkForce "0077";
  systemd.services.hermes-dashboard.restartTriggers =
    [ config.services.hermes-agent.package ]
    ++ config.services.hermes-agent.extraPlugins;
  # The WebUI is a third Hermes surface over the same home and plugin set: it
  # runs provider discovery, which calls into model-provider plugins. It needs
  # both the vendor CLI on PATH (the subscription plugin resolves its transport
  # with a PATH lookup) and a restart when the plugin set changes, or its model
  # list would go stale and report the provider unavailable.
  systemd.services.hermes-webui.path = [ pkgs-unstable.claude-code ];
  systemd.services.hermes-webui.restartTriggers =
    [ config.services.hermes-agent.package ]
    ++ config.services.hermes-agent.extraPlugins;
  extra-services.obsidian-headless = {
    enable = true;
    # Run the sync daemon as the same Unix user that writes vault files
    # (hermes), so cross-user permission/ACL coordination is unnecessary.
    # See modules/obsidian-headless.nix for the broader parameterization.
    user = "hermes";
    group = "users";
    vaults.MontyVault.path = "/var/lib/hermes/vault/MontyVault";
    # `unsupported` is required for .ics / .base / .canvas and other
    # extensions outside Obsidian's default allowlist. Without it, files
    # like tasknotes-calendar.ics are silently dropped before upload even
    # when the phone's "Sync all other types" toggle is on.
    fileTypes.MontyVault = [ "image" "audio" "pdf" "video" "unsupported" ];
  };

  services.openssh.enable = true;

  # SSH client: trust Home Assistant's host key declaratively
  programs.ssh.knownHosts = {
    "home-assistant" = {
      hostNames = [ "192.168.86.100" "homeassistant" "ha" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMzBHEg142uYU3qgiuUa3afGEVcI9JPe5a4aX4gnyHJ1";
    };
    "bifrost" = {
      hostNames = [ "bifrost" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEsVAXwCpidt9V/tx4/2E5jMyLDqvgnHYLv1ysQIOKRA";
    };
  };

  environment.systemPackages = with pkgs; [
    pkgs-unstable.claude-code
    pkgs-unstable.codex
    graphviz
    tmux
    pkgs.jq
    pkgs.tesseract
    pkgs.rsync
    pkgs.util-linux
    hermesPython
  ];

  programs.fish.enable = true;

  # Hermes gateway API keys stay in openclaw-env. Forgejo Git authentication is
  # a separate, runtime-only file consumed solely by the URL-scoped helper.
  sops.secrets."openclaw-env" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  # WebUI authentication is separate from the agent's provider environment.
  # The encrypted value contains the WebUI authentication assignment and is
  # never embedded in Nix or exposed through the generated system closure.
  sops.secrets."hermes-webui-env" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."hermes-webhook" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."forgejo-token" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."calendar-proton-url" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."calendar-google-url" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };

  programs.git = {
    enable = true;
    config.credential."https://git.montycasa.net".helper = "!${forgejo-credential-helper}";
  };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    extraDependencyGroups = [ "messaging" "anthropic" "voice" "edge-tts" ];

    # mcpServers.forgejo = {
    #   url = "http://192.168.86.120:8080/sse";
    # };

    # MCP-NixOS (https://github.com/utensils/mcp-nixos) — package/option/flake
    # discovery across search.nixos.org, NixHub, FlakeHub, Noogle, NixOS Wiki,
    # nix.dev, and the local /nix/store. Read-only; no credentials required.
    # Binary comes from pinned nixpkgs; smoke-tested in /tmp/mcp-smoke4.py.
    mcpServers.nixos = {
      command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
      timeout = 60;
      connect_timeout = 30;
    };
    mcpServers.nookbridge = {
      command = "${nookbridge}/bin/nook-mcp";
      args = [ "--socket" "/run/nookbridge/nookbridge.sock" ];
      timeout = 60;
      connect_timeout = 30;
    };
    user = "hermes";
    group = "users";
    createUser = true;
    stateDir = "/var/lib/hermes";
    workingDirectory = "/var/lib/hermes/workspace";
    environmentFiles = [ config.sops.secrets.openclaw-env.path ];
    environment = {
      TZ = "America/New_York";
      API_SERVER_ENABLED = "true";
      API_SERVER_HOST = "0.0.0.0";
      API_SERVER_PORT = "8642";
      SEARXNG_BASE_URL = "http://192.168.86.137:8080";
      TELEGRAM_ALLOWED_USERS = "748642877";
      TELEGRAM_HOME_CHANNEL = "748642877";
      # Keep Mnemosyne data under the Hermes state directory, not ~/.mnemosyne
      # or the disposable plugin virtualenv.
      MNEMOSYNE_HOME = "/var/lib/hermes/.hermes/mnemosyne";

      # WhatsApp self-chat is enabled declaratively. The personal allowlist
      # remains in the SOPS-backed openclaw-env as WHATSAPP_ALLOWED_USERS.
      WHATSAPP_ENABLED = "true";
      WHATSAPP_MODE = "self-chat";

      # Mattermost — MATTERMOST_URL must be an env var: when MATTERMOST_TOKEN
      # is set, gateway/config.py overwrites platforms.mattermost.extra.url
      # with $MATTERMOST_URL (empty if unset), so the declarative extra.url is
      # ignored. hermes reaches the server over Tailscale. MATTERMOST_ALLOWED_USERS
      # is also mirrored into systemd.services.hermes-agent.environment below
      # (the allow-list check reads it via os.getenv at startup). The bot token
      # lives in the openclaw-env secret as MATTERMOST_TOKEN.
      MATTERMOST_URL = "http://mattermost:8065";
      MATTERMOST_ALLOWED_USERS = "yyhr83fpj3n3fpnjzf3o1zah6r";
      MATTERMOST_HOME_CHANNEL = "s5yp7xu9iif3mjrw9zczwcg5ro";
    };

    # The voice-only health plugin owns a single write capability. Its Google
    # client dependencies are added to Hermes' runtime Python, not the global OS.
    extraPlugins = [
      (pkgs.runCommand "health-log-hermes-plugin" { } ''
        cp -r ${./plugins/health-log} $out
      '')
      # Hermes-Relay plugin (v1.5.0): QR pairing, `hermes pair` and
      # `hermes relay` CLI sub-commands, android_*/desktop_*/relay_* tools,
      # and dashboard relay routes. The plugin loader imports this directory
      # directly (no separate Python package needed at discovery time);
      # runtime deps (aiohttp, segno, ...) are picked up by the
      # hermes-relay systemd service via its own python interpreter
      # (see extra-services.hermes-relay below). The wheel's
      # `plugin/hermes_relay_bootstrap/` (legacy `.pth` compat hook) is
      # intentionally excluded. Keep `plugin/voice_lab/`: relay imports
      # its expressions, metrics, and provider base modules on CLI startup,
      # even when optional voice provider keys are unset.
      (pkgs.runCommand "hermes-relay-hermes-plugin" { } ''
        cp -r ${./plugins/hermes-relay} $out
      '')
      # Mnemosyne plugin and its pinned Python runtime are packaged above;
      # this replaces the mutable wrapper generated by the installer.
      mnemosyneHermesPlugin
      # Claude Pro/Max via the official Claude Code CLI. Adds a subscriber
      # route; it does not change the default model or any fallback.
      claudeSubscriptionDirectsdkPlugin
    ];
    # The subscription model-provider plugin resolves its transport by looking
    # up the vendor CLI on PATH (`shutil.which`), and the service PATH is
    # assembled from this list only — not from environment.systemPackages,
    # which is why an interactive shell finds the CLI and the service does not.
    # Without this entry the gateway reports the CLI as unavailable.
    #
    # The same applies to the discovery-time provider check the dashboard
    # performs (see systemd.services.hermes-dashboard.path below).
    extraPackages = [ pkgs-unstable.claude-code ];
    extraPythonPackages = [
      mnemosyneMemory
      mnemosyneHermes
    ];

    settings = {
      # Default conversation model is now GPT-5.6 Luna via Codex at
      # `high` reasoning. Auxiliary review (see auxiliary.review) is
      # configured separately on MiniMax-M3 at xhigh so the reviewer
      # stays strictly more deliberate than the parent conversation —
      # independent review semantics are preserved.
      model = {
        default = "gpt-5.6-luna";
        provider = "openai-codex";
        reasoning_effort = "high";
        # User-defined model aliases — resolved before catalog lookup.
        # Checked BEFORE built-in short names (sonnet/grok/...).
        # See hermes_cli/model_switch.py::resolve_alias().
        # `mm` is the previous default kept as a stable short name.
        aliases = {
          luna = "openai-codex/gpt-5.6-luna";
          terra = "openai-codex/gpt-5.6-terra";
          sol = "openai-codex/gpt-5.6-sol";
          mm = "minimax/MiniMax-M3";
          # `mimo` replaces the retired `flash` alias (deepseek-v4-flash).
          # Higher opencode-go weekly quota than flash; same provider.
          mimo = "opencode-go/mimo-v2.5";
        };
      };

      # Native delegate_task controls (Bernie's delegation path).
      # Worker model is MiniMax-M3 via the minimax Portal so children
      # run on the Portal target and the daily CLI primary quota is
      # reserved for the parent conversation. Fallback chain inherits
      # the global fallback_providers (Luna first, then MiMo). Session
      # /reasoning --session still wins for individual workers.
      delegation = {
        provider = "minimax";
        model = "MiniMax-M3";
        max_concurrent_children = 2;
        max_spawn_depth = 1;
        orchestrator_enabled = true;
      };

      tts = {
        provider = "edge";
        edge.voice = "en-GB-RyanNeural";
      };

      # Reset gateway sessions after 48h of inactivity so topic conversations
      # do not accumulate unbounded context across long gaps. Manual /reset
      # still works; context compression remains the capacity guard.
      session_reset = {
        mode = "idle";
        idle_minutes = 2880;
      };

      # Fallbacks are ordered availability routes: Codex Luna sits ahead
      # of OpenCode Go MiMo 2.5 so a single proxy/provider outage does
      # not exhaust the cheap-MiMo budget before reaching the higher-
      # quality review model. The prior opencode-go / minimax-m3 entry
      # was removed because the default model is already minimax
      # MiniMax-M3, so a same-vendor retry of the same model added no
      # availability value while still spending opencode-go quota.
      fallback_providers = [
        { provider = "openai-codex"; model = "gpt-5.6-luna"; }
        { provider = "opencode-go"; model = "mimo-v2.5"; }
      ];

      # Mixture of Agents presets. Five profiles, each tuned for a
      # different cost/quality tradeoff:
      #   - standard (default): balanced MoA — Codex Sol aggregator with
      #     cross-family references (minimax MiniMax-M3, opencode-go MiMo
      #     2.5 Pro, opencode-go Qwen 3.7 Plus). Brings productive
      #     disagreement from non-overlapping training lineages.
      #   - max: heavy MoA — same Codex Sol aggregator over opencode-go
      #     glm/deepseek-pro/kimi references. Best for deep multi-
      #     perspective synthesis where latency is acceptable. Kept as a
      #     proven safety net; opt in via `/model max --provider moa`.
      #   - tool: tool-calling specialist — Codex Terra aggregator with
      #     opencode-go Tencent Hy3 (tool-use specialist), minimax
      #     MiniMax-M3 (diverse generalist), and opencode-go qwen3.7-plus
      #     (cheap diverse tiebreaker — formerly deepseek-v4-flash).
      #   - coder: code-tuned aggregator (Codex Terra) with coding-
      #     oriented references. For implementation tasks and code review.
      #   - lite: cheap/fast aggregator (minimax MiniMax-M3) for
      #     short-turn routing and simple queries. Two opencode-go
      #     references (mimo-v2.5 + qwen3.7-plus — both high weekly
      #     quota, different training lineages). Lowest cost.
      # Use via `/model <preset> --provider moa` or one-shot
      # `/moa <prompt>`. Set per-preset `enabled = false` to fall back
      # to the aggregator acting alone.
      moa = {
        default_preset = "standard";
        presets.standard = {
          reference_models = [
            { provider = "minimax"; model = "MiniMax-M3"; }
            { provider = "opencode-go"; model = "MiMo 2.5 Pro"; }
            { provider = "opencode-go"; model = "qwen3.7-plus"; }
          ];
          aggregator = {
            provider = "openai-codex";
            model = "gpt-5.6-sol";
          };
          max_tokens = 4096;
          reference_max_tokens = 700;
          enabled = true;
        };
        presets.max = {
          reference_models = [
            { provider = "opencode-go"; model = "glm-5.2"; }
            { provider = "opencode-go"; model = "deepseek-v4-pro"; reasoning_effort = "high"; }
            { provider = "opencode-go"; model = "kimi-k2.7-code"; }
          ];
          aggregator = {
            provider = "openai-codex";
            model = "gpt-5.6-sol";
          };
          max_tokens = 4096;
          reference_max_tokens = 700;
          enabled = true;
        };
        presets.tool = {
          reference_models = [
            { provider = "opencode-go"; model = "tencent/hy3"; }
            { provider = "minimax"; model = "MiniMax-M3"; }
            # qwen3.7-plus replaces deepseek-v4-flash as the cheap diverse
            # tiebreaker — higher opencode-go weekly quota.
            { provider = "opencode-go"; model = "qwen3.7-plus"; }
          ];
          aggregator = {
            provider = "openai-codex";
            model = "gpt-5.6-terra";
          };
          max_tokens = 4096;
          reference_max_tokens = 600;
          enabled = true;
        };
        presets.coder = {
          reference_models = [
            { provider = "opencode-go"; model = "kimi-k2.7-code"; }
            { provider = "opencode-go"; model = "glm-5.2"; }
            { provider = "opencode-go"; model = "deepseek-v4-pro"; }
          ];
          aggregator = {
            provider = "openai-codex";
            model = "gpt-5.6-terra";
          };
          max_tokens = 4096;
          reference_max_tokens = 700;
          enabled = true;
        };
        presets.lite = {
          reference_models = [
            # mimo-v2.5 (formerly deepseek-v4-flash) + qwen3.7-plus — both
            # cheap, both with high opencode-go weekly quota, different
            # training lineages for productive disagreement at the lite tier.
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "opencode-go"; model = "qwen3.7-plus"; }
          ];
          aggregator = {
            provider = "minimax";
            model = "MiniMax-M3";
          };
          reference_max_tokens = 400;
        };
      };

      # Auxiliary task assignments. Each task declares its primary provider,
      # model, reasoning level, and an ordered fallback_chain. Reasoning is
      # task-level in installed Hermes 0.20.0 (auxiliary_client.py:7558-7601)
      # and the same value is passed to every fallback candidate. Per-entry
      # reasoning is not honored; per-entry timeout is supported but unused
      # here. Provider/model IDs are verbatim from the OpenCode Go docs page
      # https://opencode.ai/docs/go/#endpoints and the live /v1/models
      # catalog.
      auxiliary = {
        provider = "minimax";
        model = "MiniMax-M2.7";

        web_extract = {
          provider = "minimax";
          model = "MiniMax-M2.7";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        compression = {
          provider = "minimax";
          model = "MiniMax-M3";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        skills_hub = {
          provider = "minimax";
          model = "MiniMax-M2.7";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        mcp = {
          provider = "minimax";
          model = "MiniMax-M2.7";
          reasoning_effort = "medium";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        approval = {
          provider = "minimax";
          model = "MiniMax-M3";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        title_generation = {
          provider = "minimax";
          model = "MiniMax-M2.7";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        triage_specifier = {
          provider = "minimax";
          model = "MiniMax-M2.7";
          reasoning_effort = "medium";
          fallback_chain = [
            { provider = "opencode-go"; model = "mimo-v2.5"; }
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
          ];
        };

        # Vision. Primary MiMo V2.5, then Luna, then the experimental
        # DeepSeek V4 Flash vision model documented by OpenCode Go.
        vision = {
          provider = "opencode-go";
          model = "mimo-v2.5";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
            { provider = "opencode-go"; model = "deepseek-v4-flash-vision-exp"; }
          ];
        };

        # Review. /review launches a full reviewer subagent. The default
        # conversation is now Luna at `high`, so the reviewer MUST be a
        # strictly more deliberate target to preserve independent review
        # semantics. MiniMax-M3 at xhigh is the canonical reviewer
        # primary; Luna is the immediate fallback. Reasoning applies
        # uniformly because per-entry overrides are unsupported.
        review = {
          provider = "minimax";
          model = "MiniMax-M3";
          reasoning_effort = "xhigh";
          fallback_chain = [
            { provider = "openai-codex"; model = "gpt-5.6-luna"; }
            { provider = "opencode-go"; model = "deepseek-v4-flash"; }
          ];
        };
      };

      approvals = {
        mode = "smart";
      };

      quick_commands = {
        "myusage" = {
          type = "exec";
          command = "/var/lib/hermes/.hermes/scripts/provider-quota/myusage.sh";
        };
      };

      toolsets = [ "hermes-cli" "files" "web" "computer" "memory" ];

      # Voice requests get Home Assistant plus one narrow health write action.
      # They never receive generic file, shell, browser, or Google tools.
      platform_toolsets.api_server = [ "homeassistant" "health_log" ];
      # claude-subscription-directsdk-experimental adds a selectable Claude
      # Pro/Max route (conversation model). The default model and provider are
      # unchanged; nothing falls back to it automatically.
      plugins.enabled = [ "health-log" "hermes-relay" "hermes-mnemosyne" "claude-subscription-directsdk-experimental" ];

      # The v0.19 migration is blocked in Nix-managed mode. Declare its schema
      # marker here; the disposable migration lab validated this is sufficient.
      _config_version = 33;

      # Persist delivery obligations before platform sends; this is a durable
      # reliability boundary, not a one-off runtime default.
      gateway.delivery_ledger = true;

      agent = {
        max_turns = 90;
        gateway_timeout = 1800;
        # Per-session overrides via `/reasoning [low|medium|high|xhigh]` still win.
        reasoning_effort = "medium";
        # Per-model reasoning override. Keys are model IDs (spelling-tolerant
        # resolver in hermes_constants.resolve_per_model_reasoning_effort).
        # Session-scoped /reasoning --session always wins for that session.
        reasoning_overrides = {
          "gpt-5.6-luna" = "high";
        };
        # Surface-aware verify-before-finish: ON for CLI/TUI/desktop/programmatic
        # surfaces where the verification narrative is useful, OFF for messaging
        # surfaces (Telegram/Discord/etc.) where it would arrive as chat noise.
        # Setting this string explicitly preserves the upstream auto behavior
        # against future schema-default drift.
        verify_on_stop = "auto";
      };

      compression = {
        enabled = true;
        # threshold kept at 0.85 by user preference — compactions were firing
        # too often at lower values. in_place keeps the same session id
        # across the rewrite, so gateway routing, /goal, and session_search
        # stay coherent across long topic sessions.
        threshold = 0.85;
        threshold_tokens = 300000;
        target_ratio = 0.20;
        protect_last_n = 120;
        protect_first_n = 3;
        in_place = true;
      };

      memory = {
        # Mnemosyne migration and direct SDK/tool smoke tests passed before
        # this provider flip. Keep the imported database and Holographic
        # rollback artifacts for rollback/forensics.
        memory_enabled = false;
        user_profile_enabled = false;
        write_approval = false;

        provider = "mnemosyne";

        # Mnemosyne provider settings are declared here because this host is
        # NixOS-managed; hermes config set is intentionally blocked. The
        # provider is packaged in extraPlugins above and selected via this
        # provider key. Keep built-in file-backed injection disabled so Hermes
        # does not mix MEMORY.md/USER.md with Mnemosyne's store.
        mnemosyne = {
          auto_sleep = false;
          sleep_threshold = 50;
          vector_type = "int8";
          # Keep the imported default bank active first. Profile-isolated banks
          # require a separate migration and are enabled only after proving the
          # gateway resolves the intended profile bank.
          profile_isolation = false;
          shared_surface_path = "/var/lib/hermes/.hermes/mnemosyne/data/shared/mnemosyne.db";
          shared_surface_read = false;
          skip_contexts = [ "cron" "flush" "subagent" "background" "skill_loop" ];
          sync_roles = [ "user" "assistant" ];
        };
      };

      skills.write_approval = false;

      # Real-time token streaming over Telegram (editMessageText / sendMessageDraft)
      streaming = {
        enabled = true;
        transport = "auto";
        edit_interval = 0.8;
        buffer_threshold = 24;
        fresh_final_after_seconds = 60;
      };

      # Per-platform display settings for Telegram. Show every tool call,
      # group them into one accumulating bubble, and remove temporary
      # progress/heartbeat bubbles after successful turns. Keep the busy-ack
      # iteration counter quiet.
      display = {
        platforms.telegram = {
          tool_progress = "all";
          tool_progress_grouping = "accumulate";
          busy_ack_detail = false;
          runtime_footer = {
            enabled = false;
          };
          cleanup_progress = true;
        };
      };

      # Voice transcription (STT) — local faster-whisper, no API key needed
      stt = {
        enabled = true;
        provider = "local";
        local = {
          model = "base";
        };
      };

      # Telegram — requires a NEW bot token separate from openclaw's.
      # Set TELEGRAM_BOT_TOKEN in openclaw-env to hermes's bot token.
      # Allow-list mirrors openclaw (user 748642877 = Monty).
      telegram = {
        reactions = false;
      };

      platforms = {
        # Native Telegram DM-topic routing. Each topic starts with one compact
        # umbrella skill; the umbrella loads specialist skills only when needed.
        # disable_topic_auto_rename stops Hermes from rewriting the Telegram
        # topic title on /new and similar session resets.
        telegram = {
          extra = {
            disable_topic_auto_rename = true;
            # Hermes 0.18.0 does not perform name-based topic discovery; if
            # thread_id is absent it calls createForumTopic on startup, which
            # created 7 duplicates (97639-97651) on the post-rebuild restart
            # and orphaned the originals. Pinning the originals here so
            # future restarts bind idempotently.
            dm_topics = [
              {
                chat_id = 748642877;
                topics = [
                  { name = "Hermes";           skill = "topic-hermes";          thread_id = 87624; }
                  { name = "Health & Fitness"; skill = "topic-health-fitness";  thread_id = 92608; }
                  { name = "Homelab";          skill = "topic-homelab";         thread_id = 87193; }
                  { name = "Tasks";            skill = "topic-tasks";           thread_id = 87814; }
                  { name = "Briefing";         skill = "topic-briefing";        thread_id = 90466; }
                  { name = "General";          skill = "topic-general";         thread_id = 87664; }
                  { name = "CHOP";             skill = "topic-chop";            thread_id = 88598; }
                  { name = "Coder";            skill = "topic-coder";           thread_id = 116234; }
                ];
              }
            ];
          };
        };

        # Voice Assistant endpoint. HA's OpenClaw Assistant sends model
        # `bernie-voice`, which is routed to mimo-v2.5 (formerly DeepSeek V4
        # Flash) without changing Bernie's MiniMax-M3 default for Telegram and
        # other gateway clients. mimo-v2.5 has higher opencode-go weekly quota.
        api_server = {
          enabled = true;
          extra = {
            model_name = "hermes-agent";
            model_routes.bernie-voice = {
              provider = "opencode-go";
              model = "mimo-v2.5";
            };
          };
        };

        homeassistant = {
          enabled = true;
          extra = {
            url = "http://192.168.86.100:8123";
            watch_entities = [
              "binary_sensor.away_mode"
              "sensor.pat_phone_next_alarm"
              "sensor.last_activity"
            ];
            watch_all = false;
            cooldown_seconds = 10;
          };
        };

        webhook = {
          enabled = true;
          extra = {
            host = "0.0.0.0";
            port = 8644;
            secret = config.sops.secrets."hermes-webhook".path;
            routes = {
              "ha-alert" = {
                secret = config.sops.secrets."hermes-webhook".path;
              };
            };
          };
        };

        # Mattermost ops surface. hermes reaches the server over Tailscale
        # (bifrost is only for the phone/browser). Connection is driven by the
        # MATTERMOST_* env vars in the environment block above (url, token,
        # allowed users, home channel) — when MATTERMOST_TOKEN is set the
        # gateway sources the url from $MATTERMOST_URL, overriding extra.url,
        # so the url lives there, not here.
        mattermost = {
          enabled = true;
          extra = {
            reply_mode = "off";
          };
        };
      };

      terminal = {
        cwd = "/var/lib/hermes/workspace";
      };

      checkpoints = {
        enabled = true;
        auto_prune = true;
      };

    };

    # SOUL.md — injected as a workspace document at activation time
    documents."SOUL.md" = builtins.readFile ./documents/SOUL.md;
  };

  environment.etc."hermes/bernie/worker-registry.json" = {
    source = ./delegation/worker-registry.json;
  };

  # Inject allowlist into the systemd environment so hermes's os.getenv()
  # check sees it at startup (the module writes these to .env but the gateway
  # allowlist check uses os.getenv, not hermes's own .env loader).
  systemd.services.hermes-agent.environment = {
    TELEGRAM_ALLOWED_USERS = "748642877";
    HERMES_MANAGED = "true";
    MATTERMOST_ALLOWED_USERS = "yyhr83fpj3n3fpnjzf3o1zah6r";
    WIKI_PATH = "/var/lib/hermes/vault/MontyVault/Hermes/Wiki";
    BERNIE_WORKER_REGISTRY = "/etc/hermes/bernie/worker-registry.json";
    BERNIE_WORKER_EXECUTABLE = "/var/lib/hermes/scripts/bernie/model_worker.py";
    PYTHONPATH = mnemosynePythonPath;
  };

  # Fix file ownership after nix rebuilds. The activation script chowns
  # directories but not individual files — if anything runs as root and
  # touches a file under .hermes/ (e.g. cron/jobs.json during a service
  # restart race), it becomes root-owned and the gateway can't read it.
  # This self-heals on every service start.
  systemd.services.hermes-agent.postStart = ''
    find /var/lib/hermes/.hermes -maxdepth 3 \! -user hermes -exec chown hermes:users {} + 2>/dev/null || true
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/hermes/scripts 0755 hermes users -"
    "L+ /var/lib/hermes/scripts/bernie - - - - ${hermes-scripts}"
    "L+ /var/lib/hermes/scripts/dns_migration - - - - ${hermes-scripts}/dns_migration"
    "z /var/lib/hermes/.hermes/.env 0600 hermes users -"
    "d /var/lib/hermes/.local 0700 hermes users -"
    "d /var/lib/hermes/.local/state 0700 hermes users -"
    "d /var/lib/hermes/.local/state/bernie-delegation 0700 hermes users -"
    "d /var/lib/hermes/.cache 0700 hermes users -"
    "d /var/lib/hermes/.hermes/mnemosyne 0750 hermes users -"
    "d /var/lib/hermes/.hermes/plugins 0750 hermes users -"
    # The memory provider loader resolves providers by this directory name;
    # expose the Nix-built plugin at the canonical `mnemosyne` path instead of
    # relying on the mutable user-installed wrapper.
    "L+ /var/lib/hermes/.hermes/plugins/mnemosyne - - - - ${mnemosyneHermesPlugin}"
    "d /var/lib/hermes/.hermes/mnemosyne/data 0750 hermes users -"
    "d /var/lib/hermes/.hermes/mnemosyne/data/shared 0750 hermes users -"
    # Tighten existing SQLite files as well as files created under UMask=0077.
    "z /var/lib/hermes/.hermes/mnemosyne/data/mnemosyne.db 0600 hermes users -"
    "z /var/lib/hermes/.hermes/mnemosyne/data/mnemosyne.db-wal 0600 hermes users -"
    "z /var/lib/hermes/.hermes/mnemosyne/data/mnemosyne.db-shm 0600 hermes users -"
    "z /var/lib/hermes/.hermes/mnemosyne/data/shared/mnemosyne.db 0600 hermes users -"
    "z /var/lib/hermes/.hermes/mnemosyne/data/shared/mnemosyne.db-wal 0600 hermes users -"
    "z /var/lib/hermes/.hermes/mnemosyne/data/shared/mnemosyne.db-shm 0600 hermes users -"
  ];

  # bernie-lane-validation.service and bernie-lane-validation.timer were
  # removed when the runtime lane-validation automation was shelved in favor
  # of native Hermes delegate_task. The validator script is preserved at
  # scripts/bernie/_shelved/validate_lanes.py and the systemd units can be
  # restored by reverting that shelf PR.

  systemd.services.tasknotes-calendar-publish = {
    description = "Publish the validated TaskNotes calendar to Bifrost";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "obsidian-headless-MontyVault.service" ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "users";
      WorkingDirectory = "/var/lib/hermes";
      # The publisher is maintained in Hermes Library, not nix-config. Fail
      # clearly if the library deployment is missing rather than reporting a
      # misleading Python/import failure.
      ExecStartPre = [
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/calendars/publish_tasknotes_calendar.py"
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/calendars/generate_tasknotes_calendar.py"
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/calendars/normalize_tasknotes_calendar.py"
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/calendars/validate_ics.py"
      ];
      ExecStart = "${hermesPython}/bin/python3 /var/lib/hermes/.hermes/scripts/calendars/publish_tasknotes_calendar.py";
      TimeoutStartSec = 120;
    };
  };

  systemd.paths.tasknotes-calendar-publish = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = [
        "/var/lib/hermes/vault/MontyVault/TaskNotes"
        "/var/lib/hermes/vault/MontyVault/TaskNotes/Tasks"
        "/var/lib/hermes/vault/MontyVault/TaskNotes/Archive"
      ];
      Unit = "tasknotes-calendar-publish.service";
    };
  };

  systemd.timers.tasknotes-calendar-publish-fallback = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      Persistent = true;
      Unit = "tasknotes-calendar-publish.service";
    };
  };

  # Nix-managed calendar publishers. The legacy Hermes family job and sports
  # service remain installed as manual rollback paths, but are no longer
  # scheduled once this cutover configuration is active.
  systemd.services.family-calendar-publish = {
    description = "Fetch and publish family calendars";
    wants = [ "network-online.target" "sops-install-secrets.service" ];
    after = [ "network-online.target" "sops-install-secrets.service" ];
    path = with pkgs; [ curl openssh coreutils util-linux ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      PROTON_ICAL_URL_FILE = config.sops.secrets."calendar-proton-url".path;
      LINA_ICAL_URL_FILE = config.sops.secrets."calendar-google-url".path;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "users";
      WorkingDirectory = "/var/lib/hermes";
      UMask = "0077";
      ExecStartPre = [
        "${pkgs.coreutils}/bin/test -x ${familyCalendarPublisher}/bin/family-calendar-publisher"
        "${pkgs.coreutils}/bin/test -r ${config.sops.secrets."calendar-proton-url".path}"
        "${pkgs.coreutils}/bin/test -r ${config.sops.secrets."calendar-google-url".path}"
      ];
      ExecStart = "${familyCalendarPublisher}/bin/family-calendar-publisher";
      TimeoutStartSec = 900;
    };
  };

  systemd.timers.family-calendar-publish = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:00:00 America/New_York";
      Persistent = true;
      Unit = "family-calendar-publish.service";
    };
  };

  systemd.services.calendar-sports-publish = {
    description = "Generate and publish Philadelphia sports calendars (Nix)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ coreutils openssh rsync util-linux ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "users";
      WorkingDirectory = "/var/lib/hermes";
      UMask = "0077";
      ExecStartPre = [
        "${pkgs.coreutils}/bin/test -x ${sportsCalendarPublisher}/bin/sports-calendar-publisher"
        "${pkgs.coreutils}/bin/test -d /var/lib/hermes/workspace"
      ];
      ExecStart = "${sportsCalendarPublisher}/bin/sports-calendar-publisher";
      TimeoutStartSec = 1800;
    };
  };

  systemd.timers.calendar-sports-publish = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:00:00 America/New_York";
      Persistent = true;
      Unit = "calendar-sports-publish.service";
    };
  };

  systemd.services.calendar-sports-generate = {
    description = "Generate and publish Philadelphia sports calendars";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "hermes";
      Group = "users";
      WorkingDirectory = "/var/lib/hermes";
      ExecStartPre = [
        "${pkgs.coreutils}/bin/test -x /var/lib/hermes/.hermes/scripts/philly-sports-cal/deploy.sh"
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/philly-sports-cal/generate.py"
        "${pkgs.coreutils}/bin/test -r /var/lib/hermes/.hermes/scripts/philly-sports-cal/validate.py"
      ];
      ExecStart = "/var/lib/hermes/.hermes/scripts/philly-sports-cal/deploy.sh";
      TimeoutStartSec = 1800;
    };
  };

  systemd.timers.calendar-sports-generate = {
    # Retain the legacy service for manual rollback, but remove its scheduled
    # trigger once the Nix-managed publisher is enabled.
    enable = false;
    wantedBy = [ ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:00:00 America/New_York";
      Persistent = true;
      Unit = "calendar-sports-generate.service";
    };
  };

  # A prior generation may have left the legacy timer active even after its
  # timers.target link was removed. NixOS owns /etc/systemd/system, so a
  # manual `systemctl disable` cannot clean that stale runtime unit. Stop it
  # during activation while retaining the legacy service for manual rollback.
  system.activationScripts.disable-legacy-calendar-sports-timer =
    lib.stringAfter [ "etc" ] ''
      if ${pkgs.systemd}/bin/systemctl is-active --quiet calendar-sports-generate.timer; then
        ${pkgs.systemd}/bin/systemctl stop calendar-sports-generate.timer
      fi
    '';

  users.users.hermes = {
    linger = true;
    extraGroups = [ "nookbridge-clients" "nookbridge-operators" ];
  };

  # NixOS's switch-to-configuration reloads lingering user units after
  # activation. On a headless LXC, logind can have created the linger marker
  # without starting user@UID.service yet, leaving /run/user/UID/bus
  # unavailable and making an otherwise successful switch exit non-zero.
  # Start the declaratively-lingering Hermes manager before that reload. This
  # is idempotent when the manager is already active.
  system.activationScripts.hermes-user-manager = lib.stringAfter [ "users" ] ''
    if [ -e /var/lib/systemd/linger/hermes ]; then
      hermes_uid="$(${pkgs.coreutils}/bin/id -u hermes)"
      ${pkgs.systemd}/bin/systemctl start "user@''${hermes_uid}.service"
    fi
  '';

  users.users.root.linger = true;

  systemd.services.rocket-githook = {
    wantedBy = [ "multi-user.target" ];
    after = [ "hermes-agent.service" ];
    script = ''
      HOOK_DIR="/var/lib/hermes/.hermes/git/nix-config/.git/hooks"
      mkdir -p "$HOOK_DIR"
      cp ${./githooks/pre-push} "$HOOK_DIR/pre-push"
      chmod +x "$HOOK_DIR/pre-push"
      chown hermes:users "$HOOK_DIR/pre-push"
    '';
  };

  systemd.services.hermes-dashboard = {
    wantedBy = [ "multi-user.target" ];
    after = [ "hermes-agent.service" ];
    # The dashboard loads the same plugin set as the gateway (it shares the
    # extraPlugins restart trigger), and the subscription model-provider plugin
    # resolves its transport by looking up the vendor CLI on PATH. Without this
    # the dashboard's provider discovery cannot see the CLI.
    path = [ pkgs-unstable.claude-code ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
    };
    serviceConfig = {
      User = "hermes";
      Group = "users";
      EnvironmentFile = config.sops.secrets."openclaw-env".path;
      ExecStart = "${config.services.hermes-agent.package}/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  services.hermes-webui = {
    enable = true;
    user = "hermes";
    group = "users";
    host = "192.168.86.126";
    port = 8787;
    stateDir = "/var/lib/hermes-webui";
    hermesHome = "/var/lib/hermes/.hermes";
    agent.package = config.services.hermes-agent.package;
    environmentFiles = [
      config.sops.secrets."openclaw-env".path
      config.sops.secrets."hermes-webui-env".path
    ];
    extraEnvironment = {
      HERMES_WEBUI_DEFAULT_WORKSPACE = "/var/lib/hermes/workspace";
      HERMES_WEBUI_SERVER_CWD = "/var/lib/hermes/workspace";
    };
  };

  system.stateVersion = "25.11";
}
