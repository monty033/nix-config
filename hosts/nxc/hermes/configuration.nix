{ config, pkgs, lib, modulesPath, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  # The DirectSDK plugin discovers the subscription model catalog through
  # Claude Code at runtime and requires CLI 2.1.293 or newer. Keep this newer
  # vendor-binary CLI isolated to Hermes, using nixpkgs' manifest override.
  claudeCodeForHermes = let
    package = pkgs-unstable.claude-code.override {
      manifest = builtins.fromJSON (builtins.readFile ../../../packages/claude-code-2.1.293-manifest.json);
    };
  in
    assert lib.versionAtLeast package.version "2.1.293";
    package;
  nookbridge = pkgs.callPackage ../../../packages/nookbridge.nix { inherit inputs; };
  opencode-v2 = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-v2;
  opencode-claude = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-claude;
  opencode-goal-plugin = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-goal-plugin;
  opencode-api = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode-api;
  # Tier dispatcher. Its base roster is a separate artifact, installed read-only
  # at /etc/hermes/routing/models below; a local overlay may extend or override
  # any entry per model id.
  oc-tier = pkgs.callPackage ../../../packages/oc-tier.nix { inherit opencode-api; };
  opencode-server-config = pkgs.writeText "opencode-server-config.json" (builtins.toJSON {
    plugins = [
      "${opencode-claude}/lib/node_modules/@openchamber/opencode-claude"
      "${opencode-goal-plugin}/share/opencode-goal-plugin"
    ];
  });
  # Hermes' stable Tailscale IPv4 address (also used by the local-proxy
  # dashboard upstream).
  hermesTailscaleIp = "100.81.254.49";
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
  # Home Assistant left core in Hermes 0.22 and ships as an official catalog
  # plugin. Pin the upstream source and load its homeassistant/ subtree at the
  # plugin root, which is where extraPlugins expects plugin.yaml.
  homeAssistantHermesPlugin = pkgs.runCommand "homeassistant-hermes-plugin" { } ''
    cp -r ${pkgs.fetchFromGitHub {
      owner = "NousResearch";
      repo = "hermes-official-plugins";
      rev = "a4e311e433f1470b1fec15434deea6a05e8644eb";
      hash = "sha256-q9gpwik7FUp2z6H69z5eoq7qNZYvdi6KvU7fOG796C4=";
      name = "hermes-official-plugins";
    }}/homeassistant $out
  '';
  # Restores idle/daily gateway session resets, which core no longer applies.
  sessionResetPolicyHermesPlugin = pkgs.fetchFromGitHub {
    owner = "fastfinge";
    repo = "hermes-session-reset-policy";
    rev = "493df020496d2782d3fe15308cc3b6672c2224c4";
    hash = "sha256-Ax//zlao53+YOwP/+v3AOYIH0R30U9ON7ixI3EjEEVI=";
    name = "hermes-session-reset-policy";
  };
  # End-to-end encrypted push to Kyllene through ntfy. The phone supplies the
  # server URL and topic when it registers over the dashboard connection, so no
  # endpoint is configured here; pinned to the revision Kyllene v0.15.0 expects
  # (PLUGIN_REF) because app and plugin share a wire format. Declared rather than
  # installed from the app: on this managed install an app-driven install writes
  # an unmanaged copy and its enable leg persists nothing.
  heraldPushHermesPlugin = pkgs.fetchFromGitHub {
    owner = "Giton22";
    repo = "hermes-herald-push";
    rev = "47297c5e2e2779e6895736e46f6e79ad91050e1d";
    hash = "sha256-YCqQcdtcX3WuxZviu9/xDBKxASpPYuomalTw7xaYSjw=";
    name = "hermes-herald-push";
  };
  mnemosyneHermesPlugin = pkgs.runCommand "mnemosyne-hermes-plugin" { } ''
    mkdir -p $out
    cp -r ${mnemosyneHermes}/lib/python3.12/site-packages/mnemosyne_hermes/* $out/
    chmod -R a+rX $out
  '';
  # hermes-proton — Proton Mail, Calendar, Contacts and Drive for Hermes, over
  # Proton's private web API (no Bridge, no paid plan). Pinned by COMMIT rather
  # than version: the plugin is community-maintained against an API Proton can
  # change without notice, so the exact reviewed tree is the only thing that can
  # be reasoned about.
  #
  # Two packaging facts drive the shape below:
  #   * Hermes runs Python 3.14 from its sealed venv, so extension modules the
  #     plugin loads must come from `package.python.pkgs` — the python312 set
  #     used by the Mnemosyne packaging above would produce a wheel with the
  #     wrong ABI (`ModuleNotFoundError` at import, not at build).
  #   * nix-hermes-agent's extraPythonPackages guard fails the build when an
  #     extra package re-supplies a name already in the venv. PGPy13's declared
  #     deps (cryptography, pyasn1) are already there at compatible versions, so
  #     they are deliberately not propagated and resolve from the venv instead.
  hermesProtonSrc = pkgs.fetchFromGitHub {
    owner = "Maytrella007";
    repo = "hermes-proton";
    rev = "3e0612848cf20116294f9ff58e74aadf34bc858e";
    hash = "sha256-sI10YsmMRJs4GdTq47SgneiN2Ea0E+9MUsjmABfvHwE=";
  };
  # Upstream ships the plugin and its `protonlite` client in one tree, and the
  # plugin imports the client from its own directory (`import protonlite`), so
  # the checkout IS the plugin directory. Copying the tree keeps the client and
  # the tools on exactly the pinned commit — no second artifact to drift.
  hermesProtonPlugin = pkgs.runCommand "hermes-proton" { } ''
    cp -r ${hermesProtonSrc} $out
    chmod -R a+rX $out
  '';
  protonPGPy = config.services.hermes-agent.package.python.pkgs.buildPythonPackage rec {
    pname = "pgpy13";
    version = "0.6.1rc1";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/4f/de/8e43636f1244989fb733513fa7c1252a3f82feda4ee861ec1b6377f2e6e7/pgpy13-0.6.1rc1-py3-none-any.whl";
      hash = "sha256-yNbPPeoMwjNz/xxO15pqS/OSFr9UlwuufMplYAPRqk8=";
    };
    # See the guard note above: propagating these would fail the build and
    # shadow the venv's own copies at runtime.
    propagatedBuildInputs = [ ];
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };
  # Claude Subscription DirectSDK (experimental) — routes Hermes inference
  # through the official Claude Code CLI so a Claude Pro/Max subscription can
  # serve as a conversation model. The plugin now discovers available models
  # live through Claude Code and requires CLI >= 2.1.293. Pinned by COMMIT, not
  # version: upstream 0.3.0 spans materially different prompt-cache
  # implementations, so the tag alone is not a safe pin.
  #
  # The plugin declares no Python dependencies and Hermes' plugin loader
  # imports the directory directly (verified by running it from a plugin
  # directory with no PYTHONPATH changes), so no extraPythonPackages entry is
  # needed. Runtime prerequisite is the `claude` CLI — provided above as
  # claudeCodeForHermes — alongside the hermes user's existing subscription.
  # It provides the Claude aliases and the availability fallbacks configured
  # below; the active default route (model.default / model.provider in the
  # settings block) now runs on a different provider.
  claudeSubscriptionDirectsdkSrc = pkgs.fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-plugin-claude-subscription-directsdk";
    rev = "4bc79c78031d1a042b5d8a7314ceea283db5c5e2";
    hash = "sha256-xrCfPlPKG5qYYFx7YMTo8Gp+bERcrSFvFZBUHgiM44M=";
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
    install -m 0555 ${../../../scripts/dns_migration/switch_dns_path.py} $out/dns_migration/switch_dns_path.py
  '';
  calendarPython = python312.withPackages (ps: [ ps.icalendar ]);
  # /myusage renders its chart with matplotlib. Building the renderer puts the
  # interpreter, matplotlib and the script into one closure, so the quick
  # command runs no nix evaluation and downloads nothing at call time. The
  # wrapper it replaces shelled out to nix-shell with a pinned nixpkgs source
  # path; that path no longer exists, so nix warns "Nix search path entry ...
  # does not exist, ignoring", resolves nixpkgs another way, and instantiates
  # and fetches the whole Python closure on every call. That cold path is where
  # the command reported the chart as unavailable.
  providerUsageGraph = pkgs.callPackage ../../../packages/provider-usage-graph.nix { };
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
  # Hermes Desktop on Murdock authenticates to this dashboard with a dedicated
  # session token. The unit reads the raw one-line SOPS file at start time and
  # exports it only into the dashboard process environment, so the value never
  # reaches the Nix store or a command line. Fail closed if it is unreadable
  # or empty, rather than serving with a random per-start token.
  hermesDashboardSessionTokenFile = config.sops.secrets."hermes-desktop-session-token".path;
  hermes-dashboard-launch = pkgs.writeShellScript "hermes-dashboard-launch" ''
    set -eu

    token_file=${lib.escapeShellArg hermesDashboardSessionTokenFile}
    if [ ! -r "$token_file" ]; then
      echo "hermes-dashboard: cannot read the session token file '$token_file'. The unit stops." >&2
      exit 1
    fi

    HERMES_DASHBOARD_SESSION_TOKEN="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$token_file")"
    if [ -z "$HERMES_DASHBOARD_SESSION_TOKEN" ]; then
      echo "hermes-dashboard: the session token file '$token_file' is empty. The unit stops." >&2
      exit 1
    fi
    export HERMES_DASHBOARD_SESSION_TOKEN

    # This execs the base hermes-agent package, not the build the gateway unit
    # runs. The gateway's wrapper appends extraPythonPackages to PYTHONPATH;
    # without this line every plugin whose dependency is not already in Hermes'
    # venv fails discovery here ("No module named 'pgpy'") while loading fine in
    # the gateway. Same construction the module uses for the gateway:
    # lib.makeSearchPath over the interpreter's site-packages subdir.
    export PYTHONPATH=${lib.makeSearchPath
      config.services.hermes-agent.package.python.sitePackages
      config.services.hermes-agent.extraPythonPackages}''${PYTHONPATH:+:$PYTHONPATH}

    exec ${config.services.hermes-agent.package}/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build
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
  # Previously these three ports (API server 8642, webhook 8644, dashboard
  # 9119) were globally allowed on every interface. Confirmed access
  # patterns: 8642 (Home Assistant voice endpoint) and 8644 (ha-alert
  # webhook route) are only ever reached by Home Assistant on the LAN;
  # the dashboard (9119) is only ever reached over Tailscale (its
  # dashboard-auth.log shows exclusively Tailscale-range client IPs).
  # Scope each port to the interface that actually needs it instead of
  # exposing all three on every network path into the host.
  #
  # Hermes Webapp listener, reached by the local-proxy Caddy for the
  # hermes.montycasa.net vhost. The listener accepts only a loopback or
  # wildcard bind, so it also answers on the tailnet address; this route
  # uses the LAN address for the proxy hop instead, which is why 9120 is
  # opened here rather than on tailscale0. Nothing binds 9120 on the
  # currently deployed version, so this port is opened ahead of the
  # release that will use it.
  networking.firewall.interfaces."eth0".allowedTCPPorts = [ 8642 8644 9120 ];
  # OpenCode v2 server (4096) is likewise reachable only over Tailscale.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 9119 4096 9130 ];

  # python3.12 doc build broken in nixpkgs 26.05 (upstream issue #529084)
  documentation.man.enable = false;
  documentation.doc.enable = false;

  extra-services.tailscale = {
    enable = true;
    lxc = true;
  };
  extra-services.host-checkin.enable = true;
  extra-services.nookbridge = {
    enable = true;
    # Keep the deployed policy declarative in Nix rather than sourcing JSON.
    settingsFile = null;
    settings = {
      # A sync transports the whole vault queue, so its release is a vault-wide
      # decision rather than a per-note one. `allow` lets `notes.sync` flush what
      # the Notesnook app queued without a root operator run (#281).
      upload = "allow";
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
    # activation. Restart when the memory, voice, MCP, webapp, or routing
    # settings change so a provider cutover or a new listener is effective
    # without a manual systemctl command.
    ++ [
      (builtins.toJSON config.services.hermes-agent.settings.memory)
      (builtins.toJSON config.services.hermes-agent.settings.tts)
      # Toolset enablement partly lives in settings.agent: disabled_toolsets is
      # here. settings.toolsets and platform_toolsets are not covered by any
      # restart trigger, so changing those still needs a manual restart of the
      # gateway. Without this trigger the activation merge updates config.yaml
      # while the running gateway keeps the toolset list it started with, so
      # enabling a toolset appears to do nothing until some unrelated change
      # restarts the service.
      (builtins.toJSON config.services.hermes-agent.settings.agent)
      # Model routes and delegation live in their own settings sections, so a
      # route change leaves the agent blob above byte-identical and no trigger
      # fires. Activation would then rewrite config.yaml while the running
      # gateway kept the route it started with, making a default-route switch
      # look like a no-op until an unrelated change restarted the unit.
      (builtins.toJSON config.services.hermes-agent.settings.model)
      (builtins.toJSON config.services.hermes-agent.settings.delegation)
      # Auxiliary lanes and the fallback chain are settings blocks of their own,
      # so a change to either must restart the unit, exactly as a change to the
      # model or delegation blocks does.
      (builtins.toJSON config.services.hermes-agent.settings.auxiliary)
      (builtins.toJSON config.services.hermes-agent.settings.fallback_providers)
    ]
    ++ [
      (builtins.toJSON config.services.hermes-agent.settings.mcp_servers)
      # The webapp block is what makes the gateway bind 9120 at all, so it
      # needs the same restart treatment as the other settings blocks.
      (builtins.toJSON config.services.hermes-agent.settings.webapp)
      # The mascot selector is part of settings.display, which sits beside the
      # per-platform rendering options. Without this trigger the activation
      # merge rewrites config.yaml while the running gateway keeps the pet it
      # started with; the shared blob also means a per-platform display tweak
      # cycles the unit.
      (builtins.toJSON config.services.hermes-agent.settings.display)
      # Platform blocks (webhook routes, platform extras) are merged into the
      # mutable config the same way, so a platform change needs the same
      # treatment: without this trigger the merge rewrites config.yaml while
      # the running gateway keeps the platform tables it started with.
      (builtins.toJSON config.services.hermes-agent.settings.platforms)
      # The identity file is installed at activation, but the gateway must
      # restart to load its new instructions after a SOUL.md change.
      (builtins.hashString "sha256" config.services.hermes-agent.hermesHomeFiles."SOUL.md")
      nookbridge
    ];
  # Memory databases contain private user context. Keep files created by the
  # service private even though the parent state directory is group-accessible.
  systemd.services.hermes-agent.serviceConfig.UMask = lib.mkForce "0077";
  systemd.services.hermes-dashboard.restartTriggers =
    [ config.services.hermes-agent.package ]
    ++ config.services.hermes-agent.extraPlugins
    # The launch script carries the plugin PYTHONPATH. Changing it alters
    # ExecStart, so switch-to-configuration already restarts the unit on that
    # comparison; declaring the script explicitly is belt-and-braces, so the
    # restart does not depend on the unit-file diff alone.
    ++ [ hermes-dashboard-launch ];
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
    # like .ics or .base files are silently dropped before upload even
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
    claudeCodeForHermes
    pkgs-unstable.codex
    opencode-v2
    opencode-api
    oc-tier
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
  # The Proton recipient allowlist, deliberately NOT a declarative setting: it is
  # personal data, and a declarative setting writes it into git, the Nix store and
  # the 0660 runtime config.yaml in plain text (the module's environmentFiles
  # option would instead merge it into .env -- also plain text). sops-nix decrypts
  # this file to a 0400 path that the gateway unit loads as a systemd
  # EnvironmentFile, so the plugin's os.environ fallback finds
  # PROTON_ALLOWED_RECIPIENTS with the addresses encrypted at rest.
  # The `key` names the single entry in the encrypted file, matching the sibling
  # env-style secrets: the value is the whole `VAR=value` line, which is what
  # systemd expects to parse. Rotation means re-encrypting, committing and
  # activating; restartUnits makes the new value take effect in the running unit.
  sops.secrets."hermes-proton-env" = {
    sopsFile = ../../../secrets/hermes-proton-env.yaml;
    key = "hermes-proton-env";
    format = "yaml";
    owner = "hermes";
    group = "users";
    mode = "0400";
    restartUnits = [ "hermes-agent.service" ];
  };
  sops.secrets."hermes-webhook" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  # Raw one-line session token shared with Hermes Desktop on Murdock. The
  # dashboard launcher reads it at start time; restart on rotation.
  sops.secrets."hermes-desktop-session-token" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
    restartUnits = [ "hermes-dashboard.service" ];
  };
  sops.secrets."forgejo-token" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  # Contains OPENCODE_SERVER_PASSWORD=<value>; read by systemd as an
  # EnvironmentFile, never embedded in Nix or the store.
  sops.secrets."opencode-server-env" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
    restartUnits = [ "opencode-server.service" ];
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
  # Managed-switch admin passwords, one entry per switch keyed by management
  # IP: the key survives a switch rename, and rotating one is a single sops
  # edit. sops activation materialises each of them on every boot; what does not
  # happen is any unit consuming them, so no restartUnits is set. They are owned
  # by the hermes account because that is the account the switch tooling runs
  # as, and a 0400 file leaves that account with the only read.
  sops.secrets."switch-192-168-86-2-password" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."switch-192-168-86-3-password" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."switch-192-168-86-4-password" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."switch-192-168-86-5-password" = {
    owner = "hermes";
    group = "users";
    mode = "0400";
  };
  sops.secrets."switch-192-168-86-6-password" = {
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
    # Upstream leaves the package version at its "0.0.0" default, which
    # the install stamp records and the plugin loader's requires_hermes gate
    # reads. Pin the release version so version-gated plugins (homeassistant
    # requires >=0.21.5) load. Keep this in sync with the nix-hermes-agent
    # pin in flake.nix.
    package = pkgs.hermes-agent.override { version = "0.23.0"; };
    addToSystemPackages = true;
    extraDependencyGroups = [ "messaging" "anthropic" "voice" ];

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

      # WhatsApp is intentionally unconfigured. No Node.js bridge is installed
      # here, so an enabled adapter cannot be constructed — which is what made
      # the gateway report the platform as broken. The plugin opts in only when
      # WHATSAPP_ENABLED is true/1/yes, so leaving it unset keeps WhatsApp off.
      # WHATSAPP_ALLOWED_USERS in the encrypted environment file is inert while
      # the platform is off; drop it there when that file is next edited.

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
      # Mnemosyne plugin and its pinned Python runtime are packaged above;
      # this replaces the mutable wrapper generated by the installer.
      mnemosyneHermesPlugin
      homeAssistantHermesPlugin
      sessionResetPolicyHermesPlugin
      # Push to the phone through ntfy, end-to-end encrypted. Phone tools are
      # hidden until a phone switches them on in Kyllene.
      heraldPushHermesPlugin
      # Claude Pro/Max via the official Claude Code CLI. The default
      # conversation route runs on the reseller gateway, so this plugin supplies
      # the delegation route (Haiku), the subscription fallback route, and the
      # Claude aliases.
      claudeSubscriptionDirectsdkPlugin
      # Proton Mail/Calendar/Contacts/Drive. Reads and writes are both enabled:
      # the recipient allowlist comes from the hermes-proton-env sops secret
      # (see sops.secrets below) and the plugin's pre_tool_call hook raises an
      # approval for each send, attendee invite, RSVP, Drive upload or share,
      # permanent delete, trash empty and contact delete.
      hermesProtonPlugin
    ];
    # The subscription model-provider plugin resolves its transport by looking
    # up the vendor CLI on PATH (`shutil.which`), and the service PATH is
    # assembled from this list only — not from environment.systemPackages,
    # which is why an interactive shell finds the CLI and the service does not.
    # Without this entry the gateway reports the CLI as unavailable.
    #
    # The same applies to the discovery-time provider check the dashboard
    # performs (see systemd.services.hermes-dashboard.path below).
    extraPackages = [ claudeCodeForHermes pkgs.gnupg ];
    extraPythonPackages = [
      mnemosyneMemory
      mnemosyneHermes
      # hermes-proton. bcrypt is the only compiled dependency Hermes' venv does
      # not already carry — the SRP login handshake hashes with it — and it
      # must match the runtime interpreter. cryptography, pyasn1 and requests
      # come from the venv.
      config.services.hermes-agent.package.python.pkgs.bcrypt
      protonPGPy
    ];

    settings = {
      # Default conversation model is DeepSeek V4.1 Flash served through the
      # OpenCode Go gateway (provider `opencode-go`), whose ID for it is
      # `deepseek-v4.1-flash`. The platform API serves the same model under
      # `deepseek-flash` instead, which is why the alias below spells that
      # provider's ID rather than this one; the two spellings are not
      # interchangeable across routes. No per-model compaction override is
      # declared (see compression below), so it uses the global 300k cap like
      # other models — deliberately short of its 1M window. Delegation runs
      # Haiku (below).
      model = {
        default = "deepseek-v4.1-flash";
        provider = "opencode-go";
        # Reasoning effort per model lives in agent.reasoning_overrides below.
        # `model.reasoning_effort` is not a recognized key in this section's
        # schema, so it is not set here.
        # User-defined model aliases — resolved before catalog lookup.
        # Checked BEFORE built-in short names (sonnet/grok/...).
        # See hermes_cli/model_switch.py::resolve_alias().
        # Strings of '<provider>/<model>' are split on '/' into provider + model.
        aliases = {
          haiku = "claude-subscription-directsdk-experimental/claude-haiku-5-5";
          sonnet = "claude-subscription-directsdk-experimental/claude-sonnet-5-5";
          opus = "claude-subscription-directsdk-experimental/claude-opus-5-5[1m]";
          mm = "minimax/MiniMax-M3.1-Flash";
          # The default conversation model on its default route. The `flash`
          # name keeps pointing at whatever the default route is.
          flash = "opencode-go/deepseek-v4.1-flash";
          # The platform API's route to the same model, kept credentialed and
          # one command away: `/model dsflash`. Its ID on that provider is
          # `deepseek-flash`, not the reseller spelling used above.
          dsflash = "deepseek/deepseek-flash";
        };
      };

      # Native delegate_task controls (Bernie's delegation path).
      # Workers run Haiku on the subscription provider, a different provider from
      # the conversation default; no delegation fallback is configured, so an
      # outage there stops worker calls even when the main route has fallbacks.
      # `reasoning_effort` replaces the inherited session effort for each child
      # (tools/delegate_tool_config.py), so this key — not the per-model
      # override below — decides worker effort.
      # Serial concurrency and depth 1 keep this pilot bounded and leaf-only.
      delegation = {
        provider = "claude-subscription-directsdk-experimental";
        model = "claude-haiku-5-5";
        reasoning_effort = "medium";
        max_concurrent_children = 1;
        max_spawn_depth = 1;
        max_iterations = 40;
        orchestrator_enabled = true;
      };

      # MiniMax TTS on the global endpoint (api.minimax.io). The credential is
      # MINIMAX_API_KEY, which the service already receives from the
      # openclaw-env secret file; no additional sops entry is required.
      # tts.minimax.region is deliberately omitted: the resolver selects
      # "global" when only the global credential variable is present.
      tts = {
        provider = "minimax";
        minimax.model = "speech-2.8-hd";
        minimax.voice_id = "English_WiseScholar";
      };

      # Reset gateway sessions after 48h of inactivity so topic conversations
      # do not accumulate unbounded context across long gaps. Manual /reset
      # still works; context compression remains the capacity guard.
      session_reset = {
        mode = "idle";
        idle_minutes = 2880;
      };

      # Fallbacks are availability routes, not quality routing. Each entry is a
      # separate transport, so one failing leaves the others open: minimax
      # first (it also carries the auxiliary lanes), then Haiku on the
      # subscription provider.
      fallback_providers = [
        { provider = "minimax"; model = "MiniMax-M3.1-Flash"; }
        { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
      ];

      # Mixture of Agents presets. Each keeps two reference models and one
      # aggregator, drawn from the Claude subscription, MiniMax and OpenCode Go:
      #   - standard (default): Haiku + MiniMax M3.1 advise a DeepSeek aggregator.
      #   - max: DeepSeek + Sonnet advise an Opus aggregator for deliberate,
      #     expensive one-shot work.
      # Retired presets remain explicitly disabled because the NixOS module
      # deep-merges settings into mutable config.yaml and omitted keys survive.
      # Use via `/model <preset> --provider moa` or one-shot
      # `/moa <prompt>`. Set per-preset `enabled = false` to fall back
      # to the aggregator acting alone.
      moa = {
        default_preset = "standard";
        presets.standard = {
          reference_models = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
            { provider = "minimax"; model = "MiniMax-M3.1-Flash"; }
          ];
          aggregator = {
            provider = "opencode-go";
            model = "deepseek-v4.1-flash";
          };
          max_tokens = 4096;
          reference_max_tokens = 600;
          enabled = true;
        };
        presets.max = {
          reference_models = [
            { provider = "opencode-go"; model = "deepseek-v4.1-flash"; }
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-sonnet-5-5"; }
          ];
          aggregator = {
            provider = "claude-subscription-directsdk-experimental";
            model = "claude-opus-5-5[1m]";
          };
          max_tokens = 4096;
          reference_max_tokens = 700;
          enabled = true;
        };
        presets.tool.enabled = false;
        presets.coder.enabled = false;
        presets.lite.enabled = false;
      };

      # Auxiliary task assignments. minimax carries the background work; every
      # lane here declares its own cross-provider fallback chain. Reasoning is
      # task-level and applies uniformly to every fallback candidate.
      auxiliary = {
        provider = "minimax";
        model = "MiniMax-M3.1-Flash";

        web_extract = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
          ];
        };

        compression = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
          ];
        };

        skills_hub = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
          ];
        };

        mcp = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "medium";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-sonnet-5-5"; }
          ];
        };

        approval = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
          ];
        };

        title_generation = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-haiku-5-5"; }
          ];
        };

        triage_specifier = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "medium";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-sonnet-5-5"; }
          ];
        };

        # minimax carries vision. Both this route and the Sonnet fallback must
        # pass the post-deploy image smoke.
        vision = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "low";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-sonnet-5-5"; }
          ];
        };

        # /review launches a full reviewer subagent. The reasoning effort is
        # unchanged from the previous reviewer route; the Opus entry is the
        # cross-provider availability fallback.
        review = {
          provider = "minimax";
          model = "MiniMax-M3.1-Flash";
          reasoning_effort = "xhigh";
          fallback_chain = [
            { provider = "claude-subscription-directsdk-experimental"; model = "claude-opus-5-5[1m]"; }
          ];
        };
      };

      approvals = {
        mode = "smart";
        # The guardian classifies a tool call and may approve it without asking.
        # That is fine for shell commands it recognises; it is not fine for an
        # outbound mail. proton_send, an event invite with attendees, and the
        # three irreversible deletions are instructed to escalate rather than be
        # auto-approved, so they reach the operator. This is policy text appended
        # to the guardian's prompt, not a structured rule, so it steers that
        # judgement rather than replacing it.
        smart_policy = ''
          Always escalate these to the operator; never approve them yourself,
          whatever the recipient or the apparent intent: proton_send,
          proton_create_event when it has attendees, proton_delete with
          permanent set, proton_empty, and proton_delete_contact. A send cannot
          be recalled, and its recipient can be influenced by the content of
          the mail being read.
        '';
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
      # claude-subscription-directsdk-experimental provides the Claude aliases
      # and the subscription fallbacks.
      plugins.enabled = [
        "health-log"
        "hermes-mnemosyne"
        "claude-subscription-directsdk-experimental"
        "homeassistant"
        "hermes-session-reset-policy"
        "hermes-proton"
        "herald-push"
      ];
      # hermes-proton registers two toolsets: `proton_mail` (read) and
      # `proton_mail_write` (send, delete, upload, share, invite). Both are
      # enabled now that an account is signed in (see agent.disabled_toolsets,
      # declared empty above). What bounds a write is not the toolset but three
      # other things: the recipient allowlist (who may be written to at all --
      # deliberately not scalarised into
      # plugins.entries."hermes-proton".settings.allowed_recipients; it comes
      # from the hermes-proton-env sops secret via PROTON_ALLOWED_RECIPIENTS so
      # the addresses never appear in this file, the store or config.yaml), the
      # plugin's own pre_tool_call gate, which requires approval for every send,
      # every event invitation that carries attendees, and the three deletions
      # that have no undo, and the escalation rule in approvals.smart_policy,
      # which instructs the guardian not to approve those on the operator's
      # behalf.
      # Lazy plugin installs stay off: Hermes must not fetch dependencies at
      # runtime. Plugins come only from the Nix-managed extraPlugins above.
      security.allow_lazy_installs = false;

      # Pin the web_extract backend explicitly rather than relying on
      # autodetection. Keenable's extraction backend needs no API key.
      web.extract_backend = "keenable";

      # The schema marker is Nix-owned, so activation cannot rewind the file to
      # an older version and re-trigger migrations on every rebuild. The
      # disposable migration lab ran the 0.22.6 chain (33 -> 52) against a copy
      # of the live config: 19 steps, zero new keys, and the only semantic
      # change was this stamp — every other diff line was YAML re-serialization.
      _config_version = 52;

      # Persist delivery obligations before platform sends; this is a durable
      # reliability boundary, not a one-off runtime default.
      gateway.delivery_ledger = true;

      # Picker hygiene: the section-2 credential ladder in the model picker reads the shared
      # Claude Code OAuth credential file (~/.claude/.credentials.json) for the native
      # anthropic row even though native anthropic has no key and no route here — that file's
      # real consumer is the subscription DirectSDK plugin, whose models surface separately.
      # Excluding anthropic removes the phantom group from /model with one declarative knob.
      model_catalog.excluded_providers = [ "anthropic" ];

      agent = {
        max_turns = 90;
        gateway_timeout = 1800;
        # Short reply-style reminder. Hermes appends agent.system_prompt to the
        # end of the cached system prompt (SOUL.md, skills index) on every API
        # call for gateway, desktop/TUI and CLI sessions, so it sits after the
        # long instruction block rather than before it. An active
        # display.personality replaces it. Keep it in step with the "How I
        # talk" section of SOUL.md.
        system_prompt = "Style check before every reply to Patrick: lead with the answer in plain words. No commands, code blocks, file paths, version strings, hashes or exit codes unless he asked for them; offer \"want the details?\" instead. Keep it short. End with what he needs to do, or ask your question.";
        # Explicitly empty, not omitted. The activation script deep-merges these
        # settings over the config.yaml on disk: Nix wins on values, but a key
        # Nix stops declaring is never *deleted* from the file. Omitting this
        # key leaves a stale list in place forever, so a toolset removed here
        # would stay disabled through every rebuild (this is how the proton
        # write toolset survived its own removal in #465). Declaring the empty
        # list overwrites whatever is on disk. Re-enable a toolset by naming it
        # here rather than by deleting the key.
        disabled_toolsets = [ ];
        # Per-session overrides via `/reasoning [low|medium|high|xhigh]` still win.
        reasoning_effort = "medium";
        # Per-model reasoning override. Keys are model IDs (spelling-tolerant
        # resolver in hermes_constants.resolve_per_model_reasoning_effort).
        # The default conversation model uses high, declared under both the
        # reseller ID it is routed as and the platform-API ID the dsflash alias
        # resolves to, so switching between those routes keeps the same effort.
        # Haiku's entry covers sessions that select Haiku directly; delegation
        # children take their effort from `delegation.reasoning_effort` above.
        # The general route baseline remains medium.
        # Session-scoped /reasoning --session always wins for that session.
        reasoning_overrides = {
          "deepseek-flash" = "high";
          "deepseek-v4.1-flash" = "high";
          "claude-haiku-5-5" = "high";
          "claude-sonnet-5-5" = "medium";
          "claude-opus-5-5[1m]" = "medium";
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
        # Global cap stays at 300k for every model: huge prefixes burn allowance,
        # weaken focus, and are less cache-friendly than a compacted
        # stable prefix. Haiku 5.5 per-model override is currently disabled (see
        # model_thresholds below), so Haiku uses the global 300k cap like everything else.
        threshold_tokens = 300000;
        # Haiku 5.5 limit disabled for testing (no per-model override; global 300k cap applies).
        # To restore, uncomment the block below.
        # model_thresholds = {
        #   "claude-subscription-directsdk-experimental:claude-haiku-5-5" = 0.09;
        # };
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

        # The petdex mascot selector. Only the selector is declared here: the
        # artwork is runtime state in the application's home directory,
        # installed by the application's own pet commands, so it is not built
        # from this repository.
        pet = {
          enabled = true;
          slug = "bernie";
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
        # Voice Assistant endpoint. Keep the latency-sensitive route on Haiku
        # without changing the configured default route for other clients.
        api_server = {
          enabled = true;
          extra = {
            model_name = "hermes-agent";
            model_routes.bernie-voice = {
              provider = "claude-subscription-directsdk-experimental";
              model = "claude-haiku-5-5";
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

      # Browser-served Desktop, released in 0.22.6. The listener belongs to the
      # gateway, not to the dashboard on 9119, which is a separate surface.
      # The package builds the bundle into the store and points
      # HERMES_WEBAPP_DIST at it, so `hermes webapp` never writes to the
      # read-only store. The listener accepts only a loopback or wildcard host
      # (see gateway/webapp_listener.py), which is why 0.0.0.0 is used here and
      # eth0:9120 is opened for the local-proxy hop. Any non-loopback bind,
      # this one included, is gated by dashboard sign-in. public_url only tells
      # that sign-in flow which address a proxy serves: it is not a hostname
      # allowlist, so a direct LAN-IP request is answered and stopped by the
      # sign-in gate, not by host matching.
      webapp = {
        enabled = true;
        host = "0.0.0.0";
        port = 9120;
        public_url = "https://hermes.montycasa.net";
      };

    };

    # Hermes loads SOUL.md from HERMES_HOME, not from workingDirectory.
    # Keep the preexisting workspace copy sourced from the same file so it
    # cannot become a stale, conflicting copy after later rebuilds.
    documents."SOUL.md" = builtins.readFile ./documents/SOUL.md;
    hermesHomeFiles."SOUL.md" = builtins.readFile ./documents/SOUL.md;
  };

  # Inject allowlist into the systemd environment so hermes's os.getenv()
  # check sees it at startup (the module writes these to .env but the gateway
  # allowlist check uses os.getenv, not hermes's own .env loader).
  systemd.services.hermes-agent.environment = {
    TELEGRAM_ALLOWED_USERS = "748642877";
    HERMES_MANAGED = "true";
    MATTERMOST_ALLOWED_USERS = "yyhr83fpj3n3fpnjzf3o1zah6r";
    WIKI_PATH = "/var/lib/hermes/vault/MontyVault/Hermes/Wiki";
    PYTHONPATH = mnemosynePythonPath;
  };

  # The Proton recipient allowlist reaches the plugin through os.getenv, so it
  # has to be in the process environment. It is loaded here as a systemd
  # EnvironmentFile rather than through services.hermes-agent.environmentFiles,
  # because that option merges its files into .env -- which would put the
  # addresses back on disk in plain text, the thing the sops secret exists to
  # avoid. systemd reads the decrypted 0400 secret directly at unit start; the
  # ordering entry keeps that behind secrets installation on a boot where /run is
  # empty, and the value is inherited by any child process the agent spawns, so
  # it can still surface in an env dump or a core file.
  systemd.services.hermes-agent.serviceConfig.EnvironmentFile = [
    config.sops.secrets."hermes-proton-env".path
  ];
  systemd.services.hermes-agent.after = [ "sops-install-secrets.service" ];

  # Fix file ownership after nix rebuilds. The activation script chowns
  # directories but not individual files — if anything runs as root and
  # touches a file under .hermes/ (e.g. cron/jobs.json during a service
  # restart race), it becomes root-owned and the gateway can't read it.
  # This self-heals on every service start.
  systemd.services.hermes-agent.postStart = ''
    find /var/lib/hermes/.hermes -maxdepth 3 \! -user hermes -exec chown hermes:users {} + 2>/dev/null || true
  '';

  # The pinned nix-hermes-agent module declares /var/lib/hermes/.hermes as 2770 via
  # systemd.tmpfiles.rules, and the gateway refuses to operate while that control
  # directory is group-writable: it reports unsafe_control_permissions and every
  # scheduled job dies, including the daily briefing. A host-side tmpfiles rule
  # cannot override that declaration: for a duplicated path tmpfiles applies the
  # first entry in the merged file and ignores later ones (tmpfiles.d(5), and
  # systemd-tmpfiles logs "Duplicate line for path ..., ignoring"), and the
  # module's entry precedes this host's — which is why this file's own
  # `d .../.hermes/plugins 0750` rule leaves that directory live at 2770. The type
  # is irrelevant to that ordering, so the mode is set in the gateway's own
  # pre-start hook instead, which runs before the process on every start attempt.
  # `chmod 2750` states the target mode outright rather than clearing one bit, so
  # the setgid bit is set as well. Group write is not needed by any writer in this
  # configuration: they run as hermes (the owner) or as root. The absolute path
  # avoids depending on the unit's assembled PATH. This assumes the control
  # directory stays owned by hermes, as the module's rule declares; under another
  # owner the chmod fails, the pre-start hook fails and the unit refuses to start,
  # and the postStart chown cannot rescue it because it runs after ExecStart.
  # Revisit this line if a module bump relocates the directory.
  systemd.services.hermes-agent.preStart = lib.mkAfter ''
    ${pkgs.coreutils}/bin/chmod 2750 /var/lib/hermes/.hermes
  '';

  # The pinned nix-hermes-agent module's own activation snippet
  # (`hermes-agent-setup`) chmods /var/lib/hermes/.hermes back to 2770, and its
  # tmpfiles rule declares the same mode. The gateway refuses local-control
  # discovery while that directory is group-writable by a shared group, so every
  # agent-backed cron job dies with unsafe_control_permissions while `no_agent`
  # script jobs keep running. That is the 2026-11-02 outage: the 04:58 activation
  # reset the mode to 2770, the switch did not restart hermes-agent, the gateway's
  # own preStart chmod therefore never re-ran, and the 05:25 and 06:00 agent jobs
  # failed. Group write buys nothing here: every writer runs as hermes (the owner)
  # or as root. 2750 keeps group read/execute and the setgid bit.
  #
  # Three layers, in the order they bite:
  #
  #  1. tmpfiles. For a duplicated path systemd-tmpfiles honours the first entry
  #     it meets and processes files in name order, so this fragment — which sorts
  #     before 00-nixos.conf ('00-h' < '00-n') — decides the mode for every
  #     tmpfiles run, boot-time or manual. A plain `systemd.tmpfiles.rules` entry
  #     cannot do it: it lands after the module's entry in 00-nixos.conf, which is
  #     why this file's own `d .../.hermes/plugins 0750` rule leaves that
  #     directory live at 2770. Deliberate side effect: this fragment also creates
  #     the directory when it is absent, with the owner and mode the module
  #     intends, so a boot that reaches tmpfiles first still gets hermes:users.
  #  2. activation. This snippet runs after the module's because it names
  #     `hermes-agent-setup` in `deps` (ordering verified against the generated
  #     activation script). That name comes from the pinned module: if a bump
  #     renames the snippet and nixpkgs ignores the unknown dependency, only the
  #     ordering is lost, and layers 1 and 3 carry the mode on their own.
  #  3. the running system. The timer reconciles the mode while the gateway runs,
  #     because the unit's preStart hook above only repairs at start.
  #     OnUnitInactiveSec re-arms from the unit's last deactivation rather than its
  #     last activation, so a failed run does not stall the backstop the way
  #     OnUnitActiveSec alone does.
  # Base model inventory for the tier dispatcher: read-only, part of the
  # generation, and installed independently of the oc-tier package. Extend or
  # override it per model id in /var/lib/hermes/.hermes/routing/models; a local
  # entry replaces the base entry of the same id whole. The base governs where no
  # local entry exists, so an id listed in both is the local one's.
  environment.etc."hermes/routing/models".source = ../../../packages/routing/models;

  environment.etc."tmpfiles.d/00-hermes-control.conf".text = ''
    d /var/lib/hermes/.hermes 2750 hermes users - -
  '';

  # Deliberately no mkdir here: root `mkdir -p` follows a symlink in the final
  # component, so it would let a replaced control path create a directory at a
  # target the link names. The directory is someone else's to create — the module's
  # snippet runs just above and, at boot, the tmpfiles fragment does. `-type d` is
  # evaluated on the path itself (find does not follow symlinks by default), so a
  # real directory gets the chown and mode, a missing one makes the snippet fail
  # loudly instead of skipping, and a swapped-in symlink matches nothing: no
  # chown, no chmod, exit 0 — the intended no-op, though it leaves no trace in the
  # activation log. The chown re-asserts the ownership the module declares.
  # One-time cleanup of the retired Codex aliases and reasoning override. The
  # upstream config merge only adds and overwrites keys, so removing them from
  # this file left them live in the mutable config. This deletes exactly those
  # entries, keeps every other key, and preserves the file's owner and mode.
  # It is idempotent and never blocks activation. Remove this activation step
  # after one successful rebuild has verified the entries are gone.
  system.activationScripts.hermes-prune-codex-aliases = {
    deps = [ "hermes-agent-setup" ];
    text = ''
      hermes_cfg=/var/lib/hermes/.hermes/config.yaml
      if [ -f "$hermes_cfg" ]; then
        # Non-fatal: a failure here warns and never blocks activation.
        ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3 -c '
import copy
import os
import re
import sys
import tempfile

import yaml
from pathlib import Path

# Retired Codex entries. An alias is only removed while it still points at a
# Codex model, so a repointed alias is left alone with a warning.
RETIRED_ALIASES = {"luna", "sol"}
CODEX_PREFIX = "openai-codex/"
RETIRED_OVERRIDE_KEY = "gpt-6-luna"


def block_end(lines, start, indent):
    """Index of the first line after the mapping block that starts at `start`."""
    for j in range(start + 1, len(lines)):
        stripped = lines[j].strip()
        if not stripped or stripped.startswith("#"):
            continue
        cur = len(lines[j]) - len(lines[j].lstrip())
        if cur <= indent:
            return j
    return len(lines)


def find_top_level(lines, header):
    """Locate a top-level mapping key. Only column 0 counts."""
    for i, line in enumerate(lines):
        if line.strip() != header:
            continue
        if line.rstrip().endswith(":") and not line.startswith((" ", "\t")):
            return i
    return None


def find_child(lines, parent_header, child_header):
    """Locate a child mapping block inside a top-level parent block.

    The parent must be a top-level key, so a same-named mapping nested under
    another section (for example delegation.model) can never be mistaken for
    it.
    """
    parent = find_top_level(lines, parent_header)
    if parent is None:
        return None
    parent_end = block_end(lines, parent, 0)
    for j in range(parent + 1, parent_end):
        line = lines[j]
        if line.strip() != child_header or not line.rstrip().endswith(":"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= 0:
            continue
        return j, block_end(lines, j, indent)
    return None


def key_pattern(key):
    """Match `key:` and the quoted forms a YAML emitter may use."""
    return re.compile(r"^\s*\"?%s\"?\s*:" % re.escape(key))


def remove_key_lines(lines, span, key):
    """Remove the first `key:` entry from the block described by `span`."""
    start, end = span
    pattern = key_pattern(key)
    kept = []
    removed = False
    for i, line in enumerate(lines):
        if not removed and start < i < end and pattern.match(line):
            removed = True
            continue
        kept.append(line)
    if not removed:
        return lines, False
    return kept, True


def find_key_anywhere(node, target, path=""):
    """Every path at which `target` appears as a mapping key."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else str(key)
            if key == target:
                found.append(here)
            found.extend(find_key_anywhere(value, target, here))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found.extend(find_key_anywhere(value, target, f"{path}[{i}]"))
    return found


def main():
    raw_path = sys.argv[1]
    # Resolve symlinks so a linked config is pruned in place, not replaced by a
    # regular file.
    path = Path(os.path.realpath(raw_path))
    if not path.is_file():
        print("hermes-prune-codex-aliases: no config file, nothing to do")
        return 0

    try:
        original = path.read_text(encoding="utf-8-sig")
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: unreadable config, skipped ({exc.__class__.__name__})")
        return 0
    try:
        before = yaml.safe_load(original)
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: unparsable config, skipped ({exc.__class__.__name__})")
        return 0
    if not isinstance(before, dict):
        print("hermes-prune-codex-aliases: config is not a mapping, skipped")
        return 0

    model = before.get("model")
    aliases = model.get("aliases") if isinstance(model, dict) else None
    agent = before.get("agent")
    overrides = agent.get("reasoning_overrides") if isinstance(agent, dict) else None

    lines = original.splitlines(keepends=True)
    notes = []
    warnings = []
    removed_aliases = set()
    removed_override = False

    if isinstance(aliases, dict):
        for key in sorted(RETIRED_ALIASES):
            value = aliases.get(key)
            if key not in aliases:
                notes.append(f"alias {key}: already absent")
            elif not (isinstance(value, str) and value.startswith(CODEX_PREFIX)):
                notes.append(f"alias {key}: kept, it now points at {value!r}")
            else:
                # Recompute the span for each removal: removing a line shifts
                # every later index.
                span = find_child(lines, "model:", "aliases:")
                if span is None:
                    warnings.append(f"alias {key}: the model.aliases block was not found, so it is still live")
                    continue
                lines, ok = remove_key_lines(lines, span, key)
                if ok:
                    removed_aliases.add(key)
                    notes.append(f"alias {key}: removed")
                else:
                    warnings.append(f"alias {key}: its line was not found, so it is still live")
    else:
        notes.append("aliases: no mapping to prune")

    if isinstance(overrides, dict):
        if RETIRED_OVERRIDE_KEY not in overrides:
            notes.append(f"override {RETIRED_OVERRIDE_KEY}: already absent")
        else:
            span = find_child(lines, "agent:", "reasoning_overrides:")
            if span is None:
                warnings.append(f"override {RETIRED_OVERRIDE_KEY}: the agent.reasoning_overrides block was not found, so it is still live")
            else:
                lines, ok = remove_key_lines(lines, span, RETIRED_OVERRIDE_KEY)
                if ok:
                    removed_override = True
                    notes.append(f"override {RETIRED_OVERRIDE_KEY}: removed")
                else:
                    warnings.append(f"override {RETIRED_OVERRIDE_KEY}: its line was not found, so it is still live")
    else:
        notes.append("reasoning_overrides: no mapping to prune")

    for note in notes:
        print(f"hermes-prune-codex-aliases: {note}")
    for warning in warnings:
        print(f"hermes-prune-codex-aliases: WARNING {warning}")

    if not removed_aliases and not removed_override:
        return 0

    updated = "".join(lines)
    try:
        after = yaml.safe_load(updated)
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: edit would not parse, skipped ({exc.__class__.__name__})")
        return 0
    if not isinstance(after, dict):
        print("hermes-prune-codex-aliases: edit is not a mapping, skipped")
        return 0

    # Prove the edit did exactly what was intended: the whole document must
    # match the original with only the retired entries removed.
    expected = copy.deepcopy(before)
    exp_model = expected.get("model")
    if isinstance(exp_model, dict) and isinstance(exp_model.get("aliases"), dict):
        for key in removed_aliases:
            exp_model["aliases"].pop(key, None)
    exp_agent = expected.get("agent")
    if isinstance(exp_agent, dict) and isinstance(exp_agent.get("reasoning_overrides"), dict) and removed_override:
        exp_agent["reasoning_overrides"].pop(RETIRED_OVERRIDE_KEY, None)
    if after != expected:
        print("hermes-prune-codex-aliases: edit would change more than the retired entries, skipped")
        return 0

    # Re-read to be sure the file did not change under us since we parsed it.
    try:
        if path.read_text(encoding="utf-8-sig") != original:
            print("hermes-prune-codex-aliases: config changed during the prune, skipped")
            return 0
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: unreadable config, skipped ({exc.__class__.__name__})")
        return 0

    # Write atomically, carrying the original owner and mode onto the new file.
    try:
        st = path.stat()
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: could not stage a new file, skipped ({exc.__class__.__name__})")
        return 0
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(updated)
        os.chown(tmp_name, st.st_uid, st.st_gid)
        os.chmod(tmp_name, st.st_mode & 0o7777)
        os.replace(tmp_name, path)
        # The new file must carry a current timestamp so a watcher keyed on
        # mtime notices the change.
        os.utime(path, None)
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: write failed, skipped ({exc.__class__.__name__})")
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        return 0

    # Assert the end state on the file that is now in place. A prune that did
    # not take effect must say so loudly instead of logging a success.
    try:
        final = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        print(f"hermes-prune-codex-aliases: WARNING could not re-read the config to verify ({exc.__class__.__name__})")
        return 0
    still_present = []
    final_model = final.get("model") if isinstance(final, dict) else None
    final_aliases = final_model.get("aliases") if isinstance(final_model, dict) else None
    final_agent = final.get("agent") if isinstance(final, dict) else None
    final_overrides = final_agent.get("reasoning_overrides") if isinstance(final_agent, dict) else None
    # Any Codex-bound retired alias still present is a leftover. Repointed
    # aliases are intentionally preserved and are not reported as failures.
    for key in sorted(RETIRED_ALIASES):
        value = final_aliases.get(key) if isinstance(final_aliases, dict) else None
        if isinstance(value, str) and value.startswith(CODEX_PREFIX):
            still_present.append(f"alias {key}")
    # The override key names a retired model, so any surviving occurrence is a
    # leftover whether or not this run believed it removed one, and wherever
    # in the document it sits.
    for where in find_key_anywhere(final, RETIRED_OVERRIDE_KEY):
        still_present.append(f"override {RETIRED_OVERRIDE_KEY} at {where}")
    if still_present:
        joined = ", ".join(still_present)
        print(f"hermes-prune-codex-aliases: WARNING retired entries are still present: {joined}")
        return 0

    print("hermes-prune-codex-aliases: retired entries removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
' "$hermes_cfg" || echo "hermes-prune-codex-aliases: warning, step failed (non-fatal)" >&2
      fi
    '';
  };

  system.activationScripts.hermes-control-dir-mode = {
    deps = [ "hermes-agent-setup" ];
    text = ''
      ${pkgs.findutils}/bin/find /var/lib/hermes/.hermes -maxdepth 0 -type d \
        -exec ${pkgs.coreutils}/bin/chown hermes:users {} + \
        -exec ${pkgs.coreutils}/bin/chmod 2750 {} +
    '';
  };

  systemd.services.hermes-control-dir-mode = {
    description = "Reconcile the Hermes control directory mode";
    # An absent directory is a skip, not a failure. A chmod that genuinely fails
    # (ownership drift, read-only /var) must still reach the journal, which a `-`
    # prefix on ExecStart would hide.
    unitConfig.ConditionPathExists = "/var/lib/hermes/.hermes";
    serviceConfig = {
      Type = "oneshot";
      # The owner, not root: hermes can only ever chmod a path it owns, so a
      # replaced control directory cannot make this unit retarget a mode or the
      # setgid bit at somebody else's file, and drift surfaces as a failed run.
      User = "hermes";
      Group = "users";
      ExecStart = "${pkgs.coreutils}/bin/chmod 2750 /var/lib/hermes/.hermes";
      # 288 execs/day at default log level would bury the journal this host is
      # diagnosed from; failures are logged as warnings, so they still surface.
      LogLevelMax = "warning";
    };
  };

  systemd.timers.hermes-control-dir-mode = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "5min";
      Unit = "hermes-control-dir-mode.service";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/hermes/scripts 0755 hermes users -"
    # Rescue ISO build state, all root-owned except the trigger directory. The
    # agent may only create `/var/lib/rescue/in/request`; it can neither rename
    # the root-owned directories nor read the build directory.
    "d /var/lib/rescue 0755 root root -"
    "d /var/lib/rescue/build 0700 root root -"
    "d /var/lib/rescue/out 0755 root root -"
    "d /var/lib/rescue/in 1733 root root -"
    "r /var/lib/hermes/scripts/bernie"
    "L+ /var/lib/hermes/scripts/dns_migration - - - - ${hermes-scripts}/dns_migration"
    # The provider-quota quick command resolves its renderer as graph.sh beside
    # myusage.sh. Point that name at the packaged renderer so the chart cannot
    # depend on a runtime nix-shell; L+ replaces the previous mutable copy.
    "L+ /var/lib/hermes/.hermes/scripts/provider-quota/graph.sh - - - - ${providerUsageGraph}/bin/provider-usage-graph"
    "z /var/lib/hermes/.hermes/.env 0600 hermes users -"
    "d /var/lib/hermes/.local 0700 hermes users -"
    "d /var/lib/hermes/.local/state 0700 hermes users -"
    "R /var/lib/hermes/.local/state/bernie-delegation"
    "d /var/lib/hermes/.cache 0700 hermes users -"
    "d /var/lib/hermes/.hermes/mnemosyne 0750 hermes users -"
    "d /var/lib/hermes/nookbridge-dash 0750 hermes users -"
    "d /var/lib/hermes/.hermes/plugins 0750 hermes users -"
    # Plugin runtime state — hermes-proton keeps one 0600 session file per
    # signed-in Proton account here, holding the access/refresh tokens and the
    # salted key passphrase. The directory stays private because the file names
    # are account addresses. Runtime state, never Nix-declared content.
    "d /var/lib/hermes/.hermes/plugin-data 0700 hermes users -"
    # The memory provider loader resolves providers by this directory name;
    # expose the Nix-built plugin at the canonical `mnemosyne` path instead of
    # relying on the mutable user-installed wrapper.
    "L+ /var/lib/hermes/.hermes/plugins/mnemosyne - - - - ${mnemosyneHermesPlugin}"
    # The startup migration check looks for plugins/homeassistant by directory
    # name; the module's link is nix-managed-homeassistant-hermes-plugin. This
    # adds the canonical name at the same store path. L+ replaces anything
    # already at this path, so do not install a manual copy there.
    "L+ /var/lib/hermes/.hermes/plugins/homeassistant - - - - ${homeAssistantHermesPlugin}"
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

  # --- host rescue ISO ------------------------------------------------------
  # The rescue ISO embeds /etc/sops/age/keys.txt, so evaluation (not just the
  # build) requires root. The agent runs as hermes without sudo, so a root
  # oneshot performs the build and the agent only drops a trigger file.
  #
  # Trust boundary: nothing the agent owns feeds the build. The unit fetches
  # `master` into its own root-owned bare mirror using the Forgejo token, with
  # system and global git config disabled, builds an extracted copy of that
  # commit in a root-owned directory, and publishes only the ISO and a status
  # file. The agent's trigger is a bare "run now"; it cannot choose a commit,
  # a ref, or a tree.
  systemd.services.rescue-iso-build = {
    description = "Build the host rescue ISO from upstream master";
    path = with pkgs; [ git nix gnutar coreutils findutils ];
    environment = {
      HOME = "/var/lib/rescue";
      GIT_CONFIG_NOSYSTEM = "1";
      GIT_CONFIG_SYSTEM = "/dev/null";
      GIT_CONFIG_GLOBAL = "/dev/null";
      GIT_TERMINAL_PROMPT = "0";
      NIX_CONFIG = "experimental-features = nix-command flakes";
    };
    # /run/secrets is provided by the host, not by an in-container unit; the
    # script checks the token file itself and fails with a readable status.
    unitConfig = {
      StartLimitIntervalSec = 300;
      StartLimitBurst = 3;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      TimeoutStartSec = 3600;
      # Runs even when systemd kills the shell for a timeout, so a failed build
      # always leaves a status file the agent can read.
      ExecStopPost = toString (pkgs.writeShellScript "rescue-iso-status" ''
        state=/var/lib/rescue
        out=$state/out
        build=$state/build
        status=$out/status.json
        # Never write through a symlinked state root or a symlinked or
        # non-directory child.
        if [ -L "$state" ] || [ ! -d "$state" ] \
           || [ -L "$out" ] || [ ! -d "$out" ] \
           || [ -L "$build" ] || [ ! -d "$build" ]; then
          exit 0
        fi
        if [ -L "$status" ] || [ ! -f "$status" ] || [ ! -s "$status" ]; then
          rm -rf "$status" 2>/dev/null || true
          wrote=0
          tmp=$(mktemp "$build/status.XXXXXX" 2>/dev/null) || tmp=""
          if [ -z "$tmp" ]; then
            tmp=$build/status.fallback
            rm -rf "$tmp" 2>/dev/null || true
            if ( set -o noclobber; : > "$tmp" ) 2>/dev/null; then wrote=1; fi
          else
            wrote=1
          fi
          if [ "$wrote" = 1 ]; then
            printf '{"ok":false,"error":"build did not complete"}\n' > "$tmp" 2>/dev/null || true
            chmod 0644 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$status" 2>/dev/null || true
          fi
          if [ ! -s "$status" ]; then
            echo "rescue-iso-build: could not publish $status" >&2
          fi
        fi
      '');
    };
    script = ''
      set -euo pipefail
      state=/var/lib/rescue
      build=$state/build
      out=$state/out
      mirror=$state/repo.git
      token_file=${config.sops.secrets."forgejo-token".path}
      src=""
      cred=""
      finish() {
        rc=$?
        if [ -n "$cred" ]; then rm -rf -- "$cred"; fi
        if [ -n "$src" ]; then rm -rf -- "$src"; fi
        if [ "$rc" -ne 0 ] && { [ -L "$out/status.json" ] || [ ! -f "$out/status.json" ] || [ ! -s "$out/status.json" ]; }; then
          rm -rf -- "$out/status.json" 2>/dev/null || true
          wrote=0
          tmp=$(mktemp "$build/status.XXXXXX" 2>/dev/null) || tmp=""
          if [ -z "$tmp" ]; then
            tmp=$build/status.fallback
            rm -rf -- "$tmp" 2>/dev/null || true
            if ( set -o noclobber; : > "$tmp" ) 2>/dev/null; then wrote=1; fi
          else
            wrote=1
          fi
          if [ "$wrote" = 1 ]; then
            printf '{"ok":false,"rc":%s,"error":"build failed"}\n' "$rc" > "$tmp" 2>/dev/null || true
            chmod 0644 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$out/status.json" 2>/dev/null || true
          fi
          if [ ! -s "$out/status.json" ]; then
            echo "rescue-iso-build: could not publish $out/status.json" >&2
          fi
        fi
        exit "$rc"
      }

      # Nothing pre-existing under the state root is trusted. Check the type of
      # every directory before any write (so a symlinked state root or symlinked
      # `in`/`out`/`build` is never followed), then repair ownership and mode:
      # tmpfiles `d` creates a missing directory but never repairs an existing
      # one.
      for d in "$state" "$state/in" "$state/out" "$state/build"; do
        if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then
          echo "refusing: $d is not a plain directory" >&2
          exit 1
        fi
      done
      install -d -m 0755 -o root -g root "$state"
      install -d -m 0755 -o root -g root "$out"
      install -d -m 0700 -o root -g root "$build"
      install -d -m 1733 -o root -g root "$state/in"

      # Clear the previous result before anything else can fail, so a stale
      # status can never be mistaken for this run's outcome. The trap goes in
      # only after the directories are known to be plain and correctly owned.
      rm -rf -- "$out/status.json" "$out/rescue.iso" "$out/rescue.iso.new"
      trap finish EXIT

      # Nix reads $HOME/.config/nix/nix.conf before NIX_CONFIG, so the build
      # gets a fresh root-owned home inside the (0700) build directory instead
      # of the state root.
      home=$build/home
      rm -rf -- "$home"
      install -d -m 0700 -o root -g root "$home"
      export HOME="$home"
      export XDG_CONFIG_HOME="$home/.config"

      # Claim the trigger before anything that can fail. `mv` moves files and
      # directories alike; `rm -rf` only removes the entry, never a target.
      if [ -e "$state/in/request" ]; then
        mv -f "$state/in/request" "$build/request.$$" 2>/dev/null ||
          rm -rf "$state/in/request" || true
      fi

      [ -r "$token_file" ] || { echo "cannot read forgejo token" >&2; exit 1; }
      umask 077
      cred=$build/cred
      rm -rf -- "$cred"
      ( set -o noclobber; printf 'https://x-access-token:%s@git.montycasa.net\n' "$(cat "$token_file")" > "$cred" )

      # The mirror is rebuilt from scratch every run: a bare repository left by
      # an older layout could carry local config or hooks that the fetch would
      # trust. `rm -rf` removes a symlink entry, never its target.
      rm -rf "$mirror"
      git init --quiet --bare "$mirror"
      git --git-dir="$mirror" remote add origin https://git.montycasa.net/patrick/nix-config.git
      git --git-dir="$mirror" -c credential.helper="store --file=$cred" \
        fetch --quiet --no-tags --depth=1 origin \
        +refs/heads/master:refs/remotes/origin/master
      rm -f "$cred"; cred=""
      sha=$(git --git-dir="$mirror" rev-parse refs/remotes/origin/master)

      src=$(mktemp -d "$build/src.XXXXXX")
      git --git-dir="$mirror" archive --format=tar "$sha" | tar --no-same-owner -x -C "$src"
      if [ -n "$(find "$src" -type l -print -quit)" ]; then
        echo "refusing to build a tree containing symlinks" >&2
        exit 1
      fi
      cd "$src"
      nix build --impure --no-write-lock-file \
        '.#nixosConfigurations.rescue.config.system.build.isoImage' \
        --out-link "$build/current"
      iso=$(ls "$build"/current/iso/*.iso | head -1)
      rm -rf -- "$out/rescue.iso.new"
      install -m 0644 "$iso" "$out/rescue.iso.new"
      mv -f "$out/rescue.iso.new" "$out/rescue.iso"
      version=$(basename "$iso" .iso)
      version=''${version%-x86_64-linux}
      # The label may or may not carry a flavour prefix (`nixos-minimal-...` or
      # plain `nixos-...`), so take the version token itself instead of
      # stripping a prefix that may not exist.
      parsed=$(printf '%s\n' "$version" | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9a-f]+' | head -1 || true)
      if [ -n "$parsed" ]; then version=$parsed; fi
      tmp=$(mktemp "$build/status.XXXXXX")
      printf '{"ok":true,"commit":"%s","version":"%s","sha256":"%s","bytes":%s,"built_at":"%s"}\n' \
        "$sha" "$version" "$(sha256sum "$out/rescue.iso" | cut -d' ' -f1)" \
        "$(stat -c %s "$out/rescue.iso")" "$(date -Iseconds)" > "$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$out/status.json"
    '';
  };

  # Touch /var/lib/rescue/in/request to start a build. The service moves the
  # request out of `in/` first, so a stale trigger cannot loop.
  systemd.paths.rescue-iso-build = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathExists = "/var/lib/rescue/in/request";
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

  # SR-9: Hermes and every process it spawns (including the MCP server) are
  # daemon clients only. Operator access lives behind `nookbridge-as-operator`,
  # which requires root and drops to the dedicated `nookop` account. Do not add
  # `nookbridge-operators` here: the agent's shell would regain view, preimage,
  # apply, browse-operator and upload approval, which is the whole finding.
  users.users.hermes = {
    linger = true;
    extraGroups = [ "nookbridge-clients" ];
  };

  assertions = [
    {
      # Both routes matter: extraGroups on the user, and explicit group members.
      assertion =
        !(builtins.elem "nookbridge-operators" config.users.users.hermes.extraGroups)
        && !(builtins.elem "hermes" (config.users.groups.nookbridge-operators.members or [ ]));
      message = ''
        hermes must never hold nookbridge-operators: the agent runtime and the
        MCP server it launches inherit that identity and would regain the
        operator surface (SR-9). Use `sudo nookbridge-as-operator` instead.
      '';
    }
  ];

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
    wants = [ "sops-install-secrets.service" ];
    after = [ "hermes-agent.service" "sops-install-secrets.service" ];
    # The dashboard loads the same plugin set as the gateway (it shares the
    # extraPlugins restart trigger), and the subscription model-provider plugin
    # resolves its transport by looking up the vendor CLI on PATH. Without this
    # the dashboard's provider discovery cannot see the CLI.
    path = [ claudeCodeForHermes ];
    environment = {
      HOME = "/var/lib/hermes";
      HERMES_HOME = "/var/lib/hermes/.hermes";
      # Dashboard-spawned sessions need the same Mnemosyne closure as the gateway.
      PYTHONPATH = mnemosynePythonPath;
    };
    serviceConfig = {
      User = "hermes";
      Group = "users";
      EnvironmentFile = config.sops.secrets."openclaw-env".path;
      ExecStart = "${hermes-dashboard-launch}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # OpenCode v2 server. Bound to Hermes' Tailscale address only and also
  # firewalled to tailscale0. Runs as the hermes user so it shares the
  # workspace and tool credentials with the agent.
  systemd.services.opencode-server = {
    description = "OpenCode v2 server (Tailscale only)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" "tailscaled.service" "tailscaled-autoconnect.service" "sops-install-secrets.service" ];
    after = [ "network-online.target" "tailscaled.service" "tailscaled-autoconnect.service" "sops-install-secrets.service" ];
    environment = {
      HOME = "/var/lib/hermes";
      OPENCODE_CONFIG_CONTENT = builtins.readFile opencode-server-config;
    };
    path = [ claudeCodeForHermes ];
    serviceConfig = {
      User = "hermes";
      Group = "users";
      WorkingDirectory = "/var/lib/hermes/workspace";
      EnvironmentFile = config.sops.secrets."opencode-server-env".path;
      # The bind address only exists once tailscaled is authenticated; wait
      # for it instead of crash-looping at boot.
      # Fail closed instead of letting OpenCode silently generate a random password.
      ExecStartPre = [
        "${pkgs.runtimeShell} -c 'test -n \"\$OPENCODE_SERVER_PASSWORD\" || { echo \"OpenCode server password is required\" >&2; exit 1; }'"
        "${pkgs.runtimeShell} -c 'for i in $(seq 1 90); do ${pkgs.iproute2}/bin/ip -4 addr show dev tailscale0 | ${pkgs.gnugrep}/bin/grep -q \"inet ${hermesTailscaleIp}/\" && exit 0; sleep 1; done; echo \"tailscale address ${hermesTailscaleIp} not available\" >&2; exit 1'"
      ];
      ExecStart = "${opencode-v2}/bin/opencode serve --hostname ${hermesTailscaleIp} --port 4096";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # NookBridge progress dashboard (served as dash.montycasa.net/nookbridge
  # through local-proxy). Stdlib Python; SQLite is the source of truth.
  # Bound only to Hermes' Tailscale address and firewalled to tailscale0.
  # No login: anyone on the tailnet can edit (accepted by Patrick).
  # Source runs from the Hermes workspace; the database lives in the
  # hermes state directory.
  systemd.services.nookbridge-dash = {
    description = "NookBridge progress dashboard (Tailscale only)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" "tailscaled.service" "tailscaled-autoconnect.service" ];
    after = [ "network-online.target" "tailscaled.service" "tailscaled-autoconnect.service" ];
    serviceConfig = {
      User = "hermes";
      Group = "users";
      # SQLite creates the DB and sidecar files with this umask: owner-only.
      UMask = "0077";
      WorkingDirectory = "/var/lib/hermes/workspace/nookbridge-dash";
      # The bind address only exists once tailscaled is authenticated; wait
      # for it instead of crash-looping at boot. Never falls back to 0.0.0.0.
      ExecStartPre = [
        "${pkgs.writeShellScript "nookbridge-dash-wait-tailscale" ''
          for i in $(seq 1 90); do
            ${pkgs.iproute2}/bin/ip -4 addr show dev tailscale0 | ${pkgs.gnugrep}/bin/grep -qF "inet ${hermesTailscaleIp}/" && exit 0
            sleep 1
          done
          echo "tailscale address ${hermesTailscaleIp} not available" >&2
          exit 1
        ''}"
      ];
      ExecStart = "${pkgs.python3}/bin/python3 /var/lib/hermes/workspace/nookbridge-dash/app/server.py --bind ${hermesTailscaleIp} --port 9130 --db /var/lib/hermes/nookbridge-dash/dash.db --host dash.montycasa.net";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  system.stateVersion = "25.11";
}
