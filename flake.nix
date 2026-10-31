{
  description = "Monty's NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pinned to last known-good nixos-25.11 rev for elegoo-slicer AppImage compatibility
    # (glib 2.86 broke wx's g_dbus_proxy_call_sync; this rev has the last working glib)
    nixpkgs-elegoo-compat.url = "github:NixOS/nixpkgs/10e7ad5bbcb421fe07e3a4ad53a634b0cd57ffac";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak = {
      url = "github:gmodena/nix-flatpak";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Pinned to NookBridge main at a145cf0. Since 812ff19 it adds: the
    # operator socket serves one request per connection and resolves peers
    # without blocking the event loop (#268); a custom service policy drops
    # `notes.search` unless `notes.get` is also allowed, because search matches
    # note bodies (#269); opaque placeholder tokens are keyed with an HMAC
    # derived from the database key, so they no longer confirm a guess about
    # withheld content (#270); and the security notes state that operator-group
    # membership equals upload authority (#271).
    #
    # Earlier pin 812ff19: `nookctl`
    # exits 4 when `notes` or `tree` refuses categorically (denied, locked,
    # missing, conflict), so scripts no longer read a refusal as success (#265);
    # a notebook-less operator create now meets a `<root>` create-deny (#266);
    # and the daemon socket drops operator-only method literals like unknown
    # methods and answers an id-form get, append or update on a missing note
    # as `permission_denied` (#267).
    #
    # Earlier pin 009129b: adds terminal-confirmed
    # operator upload approval (S7a-6, #254), opaque-block editing that keeps
    # notes with images, attachments or embeds editable (D6-1, #256), the
    # operator-only path diagnostic (#262), and multi-notebook authorization
    # (#263). The operator listener now admits only `nookbridge-operators`,
    # which is what lets the host grant it to `nookop` alone (SR-9).
    # Note that D6-1 drops `notes.delete` from the legacy `readWriteNoDelete`
    # profile; the deployed policy here is an explicit `readPolicy` that still
    # includes `notes.delete`, so production behaviour is unchanged.
    #
    # Earlier pins: after PRs #252 and #253. #252 makes operator
    # pagination usable: `nookctl notes browse` and `tree list` now print the
    # cursor the daemon hands back, so every page after the first is reachable.
    # #253 fixes note reads that have a title but no body: they used to be
    # serialized as invalid, dropped with the connection, and reported to the
    # caller as `service_unavailable`; they now return `contentStatus: "ok"`
    # with an empty Markdown body. `allowEmpty` is scoped to the note-content
    # call site, so the operator view/preimage projections still require a
    # non-empty body. The 65,536-byte response frame and its exact JSON byte
    # accounting are unchanged from the previous pin.
    nookbridge = {
      url = "git+https://git.montycasa.net/patrick/NookBridge?rev=a145cf0d47b13739496b542aa7da5d07243a3194";
      flake = false;
    };

    nix-hermes-agent = {
      url = "github:NousResearch/hermes-agent/v0.22.4";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    hermes-webui = {
      url = "github:nesquena/hermes-webui/v0.52.492";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, home-manager, disko, sops-nix, nix-flatpak, plasma-manager, nix-hermes-agent, hermes-webui, ... }:
  let
    # Modules shared by every NixOS host: sops secret wiring, the home-manager
    # NixOS module, and the common home-manager settings. Each host appends its
    # own modules after this list to extend the shared configuration.
    commonModules = [
      sops-nix.nixosModules.sops
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "backup";
          extraSpecialArgs = { inherit inputs; };
          sharedModules = [ sops-nix.homeManagerModules.sops ];
        };
      }
    ];
  in {
    packages.x86_64-linux = {
      opencode-v2 = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/opencode-v2.nix { };
      opencode-claude = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/opencode-claude.nix { };
      opencode-goal-plugin = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/opencode-goal-plugin.nix { };
      opencode-api = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/opencode-api.nix { };
    };

    # `nix fmt` formats the tree with this.
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

    ## tesseract ##
    nixosConfigurations.tesseract = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        ./hosts/tesseract
        disko.nixosModules.disko
        {
          home-manager.users.patrick = import ./users/patrick/hosts/tesseract/home.nix;
          home-manager.users.lina = import ./users/lina/hosts/tesseract/home.nix;
          home-manager.sharedModules = [
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];
    };

    ## murdock ##
    nixosConfigurations.murdock = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        ./hosts/murdock
        disko.nixosModules.disko
        {
          home-manager.users.patrick = import ./users/patrick/hosts/murdock/home.nix;
          home-manager.users.lina = import ./users/lina/hosts/murdock/home.nix;
          home-manager.sharedModules = [
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];
    };

    ## rescue ##
    nixosConfigurations.rescue = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ./hosts/rescue
      ];
    };

    ## nixbook installer ##
    nixosConfigurations.nixbook-installer = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ./hosts/nixbooks/nixbook-installer
      ];
    };

    ## ali-book ##
    nixosConfigurations.ali-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nixbooks/ali-book ];
    };

    ## emma-book ##
    nixosConfigurations.emma-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nixbooks/emma-book ];
    };

    ## cora-book ##
    nixosConfigurations.cora-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nixbooks/cora-book ];
    };

    ## plasma-vm-nixos ##
    nixosConfigurations.plasma-vm-nixos = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        ./hosts/plasma-vm-nixos
        {
          home-manager.users.patrick = import ./users/patrick/hosts/tesseract/home.nix;
          home-manager.sharedModules = [
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];
    };

    ## nxc-base ##
    nixosConfigurations.nxc-base = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/nxc-base ];
    };

    ## pihole-native-test ##
    nixosConfigurations.pihole-native-test = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/pihole-native-test ];
    };

    ## pihole1 ##
    nixosConfigurations.pihole1 = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; outputs = self; piholeHostName = "pihole1"; };
      modules = commonModules ++ [ ./hosts/nxc/pihole ];
    };

    ## pihole2 ##
    nixosConfigurations.pihole2 = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; outputs = self; piholeHostName = "pihole2"; };
      modules = commonModules ++ [ ./hosts/nxc/pihole ];
    };

    ## lxc-tailscale ##
    nixosConfigurations.lxc-tailscale = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/lxc-tailscale ];
    };

    ## nix-fury ##
    nixosConfigurations.nix-fury = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nix-fury ];
    };

    ## yondu ##
    nixosConfigurations.yondu = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/yondu ];
    };

    ## bifrost ##
    nixosConfigurations.bifrost = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/bifrost ];
    };

    ## local-proxy ##
    nixosConfigurations.local-proxy = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/local-proxy ];
    };

    ## jellyfin ##
    nixosConfigurations.jellyfin = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/jellyfin ];
    };

    ## audiobookshelf ##
    nixosConfigurations.audiobookshelf = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/audiobookshelf ];
    };

    ## obsidian ##
    nixosConfigurations.obsidian = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/obsidian ];
    };

    ## immich ##
    nixosConfigurations.immich = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/immich ];
    };

    ## homepage ##
    nixosConfigurations.homepage = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/homepage ];
    };

    ## omada ##
    nixosConfigurations.omada = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/omada ];
    };

    ## endurain ##
    nixosConfigurations.endurain = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/endurain ];
    };

    ## mealie ##
    nixosConfigurations.mealie = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/mealie ];
    };

    ## Mattermost ##
    nixosConfigurations.mattermost = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/mattermost ];
    };

    ## ERPNext ##
    nixosConfigurations.erpnext = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/dev/erpnext ];
    };

    ## grist ##
    nixosConfigurations.grist = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/grist ];
    };

    ## pocket-id ##
    nixosConfigurations.pocket-id = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/pocket-id ];
    };

    ## nextcloud ##
    nixosConfigurations.nextcloud = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nextcloud ];
    };

    ## onlyoffice ##
    nixosConfigurations.onlyoffice = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/dev/onlyoffice ];
    };

    ## forgejo ##
    nixosConfigurations.forgejo = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; nixosConfigurations = self.nixosConfigurations; };
      modules = commonModules ++ [ ./hosts/nxc/forgejo ];
    };

    ## omnitools ##
    nixosConfigurations.omnitools = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/omnitools ];
    };

    ## frigate ##
    nixosConfigurations.frigate = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/frigate ];
    };

    ## paperless-ngx ##
    nixosConfigurations.paperless-ngx = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/paperless-ngx ];
    };

    ## searxng ##
    nixosConfigurations.searxng = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/searxng ];
    };

    ## wallabag ##
    nixosConfigurations.wallabag = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/wallabag ];
    };

    ## karakeep ##
    nixosConfigurations.karakeep = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/karakeep ];
    };

    ## ollama ##
    nixosConfigurations.ollama = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [ ./hosts/nxc/ollama ];
    };

    ## hermes ##
    nixosConfigurations.hermes = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = commonModules ++ [
        { nixpkgs.overlays = [
          nix-hermes-agent.overlays.default
          (final: prev: {
            hermes-relay = final.callPackage ./packages/hermes-relay.nix { };
          })
        ]; }
        ./hosts/nxc/hermes
        hermes-webui.nixosModules.default
      ];
    };

    # Stage 8 VM isolation gate: real `pkgs.testers.nixosTest`
    # proving service/client user/group separation, socket ACL access
    # for a nookbridge-clients member, denial of state/credential
    # visibility for that same member, denial of socket access for an
    # outsider, and absence of the runtime-generated fixture secret
    # in the built package output directory. The test is self-contained: it
    # defines its own users/groups, state/runtime dirs, root-only
    # oneshot secret-fixture service, and nookd.service whose only
    # difference from the production unit is `ExecStart` (a Python
    # AF_UNIX stub). The production module evaluation / service-
    # boundary static structure is covered by
    # `checks.x86_64-linux.nookbridge-service`; live application
    # behaviour (RPC handlers, native SQLite) is covered by the
    # NookBridge repo's own test suite.
    checks.x86_64-linux.nookbridge-isolation =
      nixpkgs.legacyPackages.x86_64-linux.testers.nixosTest
        (import ./tests/nookbridge-isolation.nix {
          lib = nixpkgs.lib;
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit inputs;
        });

    # Non-gate Stage 9 drill (this does NOT close G2): generated encrypted
    # fixture, real recovery CLI, restart/access checks, and the framed server
    # with a test-chosen policy in a throwaway VM. The daemon is a stub and the
    # corrupted bundle is never recovered.
    checks.x86_64-linux.nookbridge-recovery =
      nixpkgs.legacyPackages.x86_64-linux.testers.nixosTest
        (import ./tests/nookbridge-recovery.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit inputs;
        });

    # Stage 9 G2: production module/daemon bundle recovery under TCG.  This
    # check uses the pinned production package and the real sops/Systemd
    # credential path; it is separate from the non-gate stub drill above.
    checks.x86_64-linux.nookbridge-production-recovery =
      nixpkgs.legacyPackages.x86_64-linux.testers.nixosTest
        (import ./tests/nookbridge-production-recovery.nix {
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          inherit inputs;
        });

    # Pure settings-module check: inline Nix settings are rendered to the
    # same closed JSON schema consumed by nookd, with null option fields
    # removed and invalid override selectors rejected at evaluation time.
    checks.x86_64-linux.nookbridge-settings =
      import ./tests/nookbridge-settings.nix {
        lib = nixpkgs.lib;
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      };

    # Integration check: evaluate the production module with inline settings
    # and verify the generated /etc payload and ownership contract.
    checks.x86_64-linux.nookbridge-settings-module =
      import ./tests/nookbridge-settings-module.nix {
        lib = nixpkgs.lib;
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit inputs;
      };

    checks.x86_64-linux.nookbridge-service = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      cfg = self.nixosConfigurations.hermes.config;
      service = cfg.systemd.services.nookd.serviceConfig;
      configFile = ./modules/nookbridge/service.json;
      settingsEtc = cfg.environment.etc."nookbridge/settings.json";
      execStart = nixpkgs.lib.escapeShellArg service.ExecStart;
      credentialCount = builtins.length service.LoadCredential;
      credentialDb = nixpkgs.lib.escapeShellArg (builtins.elemAt service.LoadCredential 0);
      credentialSettings = nixpkgs.lib.escapeShellArg (builtins.elemAt service.LoadCredential 1);
      credentialPath = toString cfg.sops.secrets."nookbridge-db-key".path;
      nookbridgePackage = pkgs.callPackage ./packages/nookbridge.nix { inherit inputs; };
      operatorProvision = builtins.head (builtins.filter (p: p.name == "nookbridge-provision") cfg.environment.systemPackages);
      operatorSync = builtins.head (builtins.filter (p: p.name == "nookbridge-sync") cfg.environment.systemPackages);
      operatorRecovery = builtins.head (builtins.filter (p: p.name == "nookbridge-recovery") cfg.environment.systemPackages);
    in pkgs.runCommand "nookbridge-service-boundary-check" {
      nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.jq ];
    } ''
      ${pkgs.jq}/bin/jq -e '
        .stateDir == "/var/lib/nookbridge" and
        .socketPath == "/run/nookbridge/nookbridge.sock" and
        .socketGroup == "nookbridge-clients" and
        .backend == "systemd-credential" and
        .credentialName == "nookbridge-db-key" and
        .readPolicy == ["notes.search", "notes.status", "notes.list_notebooks", "notes.get", "notes.path_diagnostic", "notes.create", "notes.append", "notes.update", "notes.delete", "notes.sync"]
      ' ${configFile} > /dev/null

      case ${execStart} in
        */bin/nookd\ --config\ /etc/nookbridge/service.json) ;;
        *) echo "unexpected nookd ExecStart" >&2; exit 1 ;;
      esac
      test ${toString credentialCount} = 2
      test ${credentialDb} = "nookbridge-db-key:/run/secrets/nookbridge-db-key"
      test ${credentialSettings} = "nookbridge-settings:/etc/nookbridge/settings.json"
      test ${nixpkgs.lib.escapeShellArg settingsEtc.user} = root
      test ${nixpkgs.lib.escapeShellArg settingsEtc.group} = root
      test ${nixpkgs.lib.escapeShellArg settingsEtc.mode} = 0640
      test ${nixpkgs.lib.escapeShellArg service.User} = nookbridge
      test ${nixpkgs.lib.escapeShellArg service.Group} = nookbridge-clients
      test ${nixpkgs.lib.escapeShellArg (toString service.RestrictAddressFamilies)} = 'AF_UNIX AF_INET AF_INET6'
      test ${nixpkgs.lib.escapeShellArg service.StateDirectory} = nookbridge
      test ${nixpkgs.lib.escapeShellArg service.RuntimeDirectory} = nookbridge
      test ${nixpkgs.lib.escapeShellArg cfg.sops.secrets."nookbridge-db-key".owner} = root
      test ${nixpkgs.lib.escapeShellArg cfg.sops.secrets."nookbridge-db-key".mode} = 0400

      assert_wrapper_line() {
        ${pkgs.gnugrep}/bin/grep -Fxq -- "$1" "$2"
      }

      for command in \
        ${operatorProvision}/bin/nookbridge-provision \
        ${operatorSync}/bin/nookbridge-sync \
        ${operatorRecovery}/bin/nookbridge-recovery; do
        test -x "$command"
        ${pkgs.gnugrep}/bin/grep -Fq -- 'id -u' "$command"
        ${pkgs.gnugrep}/bin/grep -Fq -- 'must be run as root' "$command"
        if [ "$command" = "${operatorRecovery}/bin/nookbridge-recovery" ]; then
          assert_wrapper_line "  --quiet --wait --collect --pipe \\" "$command"
        else
          assert_wrapper_line "  --quiet --wait --collect --pty \\" "$command"
        fi
        assert_wrapper_line "  --uid=nookbridge \\" "$command"
        if [ "$command" != "${operatorRecovery}/bin/nookbridge-recovery" ]; then
          assert_wrapper_line "  --gid=nookbridge-clients \\" "$command"
        fi
        assert_wrapper_line "  --property=WorkingDirectory=/var/lib/nookbridge \\" "$command"
        assert_wrapper_line "  --property=Environment=HOME=/var/lib/nookbridge \\" "$command"
        assert_wrapper_line "  --property=Environment=PATH=${pkgs.coreutils}/bin \\" "$command"
        assert_wrapper_line "  --property=LoadCredential=nookbridge-db-key:${credentialPath} \\" "$command"
        assert_wrapper_line "  --property=ProtectSystem=strict \\" "$command"
        assert_wrapper_line "  --property=ProtectHome=yes \\" "$command"
        assert_wrapper_line "  --property=NoNewPrivileges=yes \\" "$command"
        assert_wrapper_line "  --property=PrivateTmp=yes \\" "$command"
        assert_wrapper_line "  --property=PrivateDevices=yes \\" "$command"
        assert_wrapper_line "  --property=RestrictAddressFamilies='AF_UNIX AF_INET AF_INET6' \\" "$command"
        assert_wrapper_line "  --property=RestrictNamespaces=yes \\" "$command"
        assert_wrapper_line "  --property=ProtectKernelTunables=yes \\" "$command"
        assert_wrapper_line "  --property=ProtectKernelModules=yes \\" "$command"
        assert_wrapper_line "  --property=ProtectControlGroups=yes \\" "$command"
        assert_wrapper_line "  --property=LockPersonality=yes \\" "$command"
        assert_wrapper_line "  --property=RestrictRealtime=yes \\" "$command"
        assert_wrapper_line "  --property=RestrictSUIDSGID=yes \\" "$command"
        assert_wrapper_line "  --property=CapabilityBoundingSet= \\" "$command"
        assert_wrapper_line "  --property=AmbientCapabilities= \\" "$command"
        assert_wrapper_line "  --property=SystemCallArchitectures=native \\" "$command"
        assert_wrapper_line "  --property=ReadWritePaths=/var/lib/nookbridge \\" "$command"
        assert_wrapper_line "  --property=UMask=0077 \\" "$command"
        assert_wrapper_line "  --property=TimeoutStartSec=10min \\" "$command"
        assert_wrapper_line "  --property=RuntimeMaxSec=10min \\" "$command"
        ! ${pkgs.gnugrep}/bin/grep -Fq -- 'wantedBy' "$command"
      done
      assert_wrapper_line "  --unit=nookbridge-recovery-\$\$.service \\" ${operatorRecovery}/bin/nookbridge-recovery
      assert_wrapper_line "  --gid=nookbridge \\" ${operatorRecovery}/bin/nookbridge-recovery
      assert_wrapper_line "  --setenv=NOOKBRIDGE_STATE_DIR=/var/lib/nookbridge \\" ${operatorRecovery}/bin/nookbridge-recovery
      assert_wrapper_line "  ${nookbridgePackage}/bin/nookctl recover-local-state bundle \"\$@\"" ${operatorRecovery}/bin/nookbridge-recovery
      ${pkgs.gnugrep}/bin/grep -Fq -- 'systemctl is-active --quiet nookd' ${operatorRecovery}/bin/nookbridge-recovery
      ! ${pkgs.gnugrep}/bin/grep -Fq -- '/run/current-system/sw/bin/nookctl' ${operatorRecovery}/bin/nookbridge-recovery
      test -f ${nookbridgePackage}/libexec/nookbridge/dist/provision.js
      test -f ${nookbridgePackage}/libexec/nookbridge/dist/sync.js

      # Stage 8: structural assertions for the packaged nookctl wrapper.
      test -x ${nookbridgePackage}/bin/nookctl
      ${pkgs.gnugrep}/bin/grep -Fq -- 'dist/cli.js' ${nookbridgePackage}/bin/nookctl
      test -f ${nookbridgePackage}/libexec/nookbridge/dist/cli.js
      assert_wrapper_line "  --unit=nookbridge-provision.service \\" ${operatorProvision}/bin/nookbridge-provision
      assert_wrapper_line "  --unit=nookbridge-sync.service \\" ${operatorSync}/bin/nookbridge-sync
      assert_wrapper_line "  --setenv=NOOKBRIDGE_ENABLE_LIVE_AUTH=1 \\" ${operatorProvision}/bin/nookbridge-provision
      assert_wrapper_line "  --setenv=NOOKBRIDGE_ENABLE_LIVE_SYNC=1 \\" ${operatorSync}/bin/nookbridge-sync
      assert_wrapper_line "  --setenv=NOOKBRIDGE_STATE_DIR=/var/lib/nookbridge \\" ${operatorSync}/bin/nookbridge-sync
      assert_wrapper_line "  ${nookbridgePackage}/bin/nookbridge-provision-cli" ${operatorProvision}/bin/nookbridge-provision
      assert_wrapper_line "  ${nookbridgePackage}/bin/nookbridge-sync-cli" ${operatorSync}/bin/nookbridge-sync
      ! ${pkgs.gnugrep}/bin/grep -Fq -- 'nookbridge-sync-cli' ${operatorProvision}/bin/nookbridge-provision
      ! ${pkgs.gnugrep}/bin/grep -Fq -- 'nookbridge-provision-cli' ${operatorSync}/bin/nookbridge-sync
      touch "$out"
    '';
  };
}
