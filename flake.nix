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

    nixpkgs-2511.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Pinned to the merged Stage 9 source tree with breadcrumbs fallback;
    # deployment policy is explicitly read-write with bounded single-note
    # delete capability.
    nookbridge = {
      url = "git+https://git.montycasa.net/patrick/NookBridge?rev=804e9c61a4bef3b35c68fa475589fdb7729d910d";
      flake = false;
    };

    nix-hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.9.21";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    hermes-webui = {
      url = "github:nesquena/hermes-webui/v0.52.113";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, nixpkgs-2511, home-manager, disko, sops-nix, nix-flatpak, plasma-manager, nix-hermes-agent, hermes-webui, ... }: {

    ## tesseract ##
    nixosConfigurations.tesseract = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/tesseract
        disko.nixosModules.disko
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.users.patrick = import ./users/patrick/hosts/tesseract/home.nix;
          home-manager.users.lina = import ./users/lina/hosts/tesseract/home.nix;

          home-manager.sharedModules = [
            sops-nix.homeManagerModules.sops
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];
    };

    ## murdock ##
    nixosConfigurations.murdock = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/murdock
        disko.nixosModules.disko
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.users.patrick = import ./users/patrick/hosts/murdock/home.nix;
          home-manager.users.lina = import ./users/lina/hosts/murdock/home.nix;

          home-manager.sharedModules = [
            sops-nix.homeManagerModules.sops
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];
    };

    ## rescue ##
    nixosConfigurations.rescue = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"

        ./hosts/rescue
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## nixbook installer ##
    nixosConfigurations.nixbook-installer = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"

        ./hosts/nixbooks/nixbook-installer
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## ali-book ##
    nixosConfigurations.ali-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nixbooks/ali-book
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## emma-book ##
    nixosConfigurations.emma-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nixbooks/emma-book
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## cora-book ##
    nixosConfigurations.cora-book = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nixbooks/cora-book
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## plasma-vm-nixos ##
    nixosConfigurations.plasma-vm-nixos = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/plasma-vm-nixos
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.users.patrick = import ./users/patrick/hosts/tesseract/home.nix;
          
          home-manager.sharedModules = [
            sops-nix.homeManagerModules.sops
            nix-flatpak.homeManagerModules.nix-flatpak
            plasma-manager.homeModules.plasma-manager
          ];
        }
      ];

    };

    ## nxc-base ##
    nixosConfigurations.nxc-base = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/nxc-base
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## pihole-native-test ##
    nixosConfigurations.pihole-native-test = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/pihole-native-test
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## pihole1 ##
    nixosConfigurations.pihole1 = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; outputs = self; piholeHostName = "pihole1"; };
      modules = [
        ./hosts/nxc/pihole
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## pihole2 ##
    nixosConfigurations.pihole2 = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; outputs = self; piholeHostName = "pihole2"; };
      modules = [
        ./hosts/nxc/pihole
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## lxc-tailscale ##
    nixosConfigurations.lxc-tailscale = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/lxc-tailscale
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## nix-fury ##
    nixosConfigurations.nix-fury = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nix-fury
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];

    };

    ## yondu ##
    nixosConfigurations.yondu = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/yondu
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];

    };

    ## bifrost ##
    nixosConfigurations.bifrost = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/bifrost
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## local-proxy ##
    nixosConfigurations.local-proxy = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/local-proxy
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## jellyfin ##
    nixosConfigurations.jellyfin = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/jellyfin
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## audiobookshelf ##
    nixosConfigurations.audiobookshelf = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/audiobookshelf
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## obsidian ##
    nixosConfigurations.obsidian = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/obsidian
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## immich ##
    nixosConfigurations.immich = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/immich
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## homepage ##
    nixosConfigurations.homepage = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/homepage
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## omada ##
    nixosConfigurations.omada = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/omada
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## endurain ##
    nixosConfigurations.endurain = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/endurain
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## mealie ##
    nixosConfigurations.mealie = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/mealie
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## Mattermost ##
    nixosConfigurations.mattermost = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/mattermost
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## ERPNext ##
    nixosConfigurations.erpnext = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/dev/erpnext
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## grist ##
    nixosConfigurations.grist = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/grist
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## pocket-id ##
    nixosConfigurations.pocket-id = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/pocket-id
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## nextcloud ##
    nixosConfigurations.nextcloud = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nextcloud
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## onlyoffice ##
    nixosConfigurations.onlyoffice = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/dev/onlyoffice
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## forgejo ##
    nixosConfigurations.forgejo = nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        nixosConfigurations = self.nixosConfigurations;
      };
      modules = [
        ./hosts/nxc/forgejo
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## omnitools ##
    nixosConfigurations.omnitools = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/omnitools
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

   #       home-manager.users.patrick = import ./users/patrick/home.nix;

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## frigate ##
    nixosConfigurations.frigate = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/frigate
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## paperless-ngx ##
    nixosConfigurations.paperless-ngx = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/paperless-ngx
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## searxng ##
    nixosConfigurations.searxng = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/searxng
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## wallabag ##
    nixosConfigurations.wallabag = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/wallabag
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## karakeep ##
    nixosConfigurations.karakeep = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/karakeep
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## ollama ##
    nixosConfigurations.ollama = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/nxc/ollama
        sops-nix.nixosModules.sops

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
        }
      ];
    };

    ## hermes ##
    nixosConfigurations.hermes = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        { nixpkgs.overlays = [
          nix-hermes-agent.overlays.default
          (final: prev: {
            hermes-relay = final.callPackage ./packages/hermes-relay.nix { };
          })
        ]; }
        ./hosts/nxc/hermes
        sops-nix.nixosModules.sops
        hermes-webui.nixosModules.default

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";
          home-manager.extraSpecialArgs = { inherit inputs; };

          home-manager.sharedModules = [
            sops-nix.homeManagerModules.sops
          ];
        }
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
        ${operatorSync}/bin/nookbridge-sync; do
        test -x "$command"
        ${pkgs.gnugrep}/bin/grep -Fq -- 'id -u' "$command"
        ${pkgs.gnugrep}/bin/grep -Fq -- 'must be run as root' "$command"
        assert_wrapper_line "  --quiet --wait --collect --pty \\" "$command"
        assert_wrapper_line "  --uid=nookbridge \\" "$command"
        assert_wrapper_line "  --gid=nookbridge-clients \\" "$command"
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
      assert_wrapper_line "  ${nookbridgePackage}/bin/nookbridge-provision-cli" ${operatorProvision}/bin/nookbridge-provision
      assert_wrapper_line "  ${nookbridgePackage}/bin/nookbridge-sync-cli" ${operatorSync}/bin/nookbridge-sync
      ! ${pkgs.gnugrep}/bin/grep -Fq -- 'nookbridge-sync-cli' ${operatorProvision}/bin/nookbridge-provision
      ! ${pkgs.gnugrep}/bin/grep -Fq -- 'nookbridge-provision-cli' ${operatorSync}/bin/nookbridge-sync
      touch "$out"
    '';
  };
}
