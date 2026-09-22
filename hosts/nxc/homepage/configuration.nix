{ config, pkgs, lib, modulesPath, inputs, outputs, ... }:
let
  homepage-with-assets = pkgs.symlinkJoin {
    name = "homepage-dashboard-with-monty-casa-assets";
    paths = [ pkgs.homepage-dashboard ];
    meta.mainProgram = "homepage";
    postBuild = ''
      mkdir -p $out/share/homepage/public/images
      cp ${./assets/monty-casa-crest.svg} $out/share/homepage/public/images/monty-casa-crest.svg

      # symlinkJoin links server.js to the original package. Next resolves that
      # symlink and uses the original directory as its static-asset root, so
      # materialize the entrypoint inside this overlay instead.
      rm $out/share/homepage/server.js
      cp ${pkgs.homepage-dashboard}/share/homepage/server.js $out/share/homepage/server.js

      rm $out/bin/homepage
      cat > $out/bin/homepage <<EOF
      #!${pkgs.runtimeShell}
      cd "$out/share/homepage"
      exec ${pkgs.nodejs}/bin/node "$out/share/homepage/server.js" "\$@"
      EOF
      chmod +x $out/bin/homepage
    '';
  };
in
{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  sops = {
    secrets = {
      "homepage-dashboard-env" = {
        mode = "0400";
        restartUnits = [ "homepage-dashboard.service" ];
      };
    };
  };


  extra-services.tailscale = {
    enable = true;
    lxc = true;
  };
  extra-services.host-checkin.enable = true;

  services.openssh.enable = true;

  services.homepage-dashboard = {
    enable = true;
    package = homepage-with-assets;
    allowedHosts = "192.168.86.118:8082,homepage.skink-galaxy.ts.net:8082,homepage.montycasa.net";
    environmentFile = config.sops.secrets."homepage-dashboard-env".path;
    openFirewall = true;
    
    settings = {
      title = "Monty Casa Homelab";
      favicon = "/images/monty-casa-crest.svg";
      quicklaunch = {
        searchDescriptions = true;
        hideInternetSearch = true;
        hideVisitURL = true;
      };

      layout = [
        { Proxmox = { tab = "Machines"; }; }
        { Storage = { tab = "Machines"; }; }
        { "Other Machines" = { tab = "Machines"; }; }
        { Offsite = { tab = "Machines"; }; }
        { "Routers, DNS, Switches" = { tab = "Networking"; }; }
        { "Access Points" = { tab = "Networking"; }; }
        { "Remote Access" = { tab = "Networking"; }; }
        { "Home Automation" = { tab = "Home"; }; }
        { NVR = { tab = "Home"; }; }
        { "Media Servers" = { tab = "Media"; style = "row"; columns = 1; }; }
        { Aar = { tab = "Media"; style = "row"; columns = 3; }; }
        { Apps = { tab = "Apps"; style = "row"; columns = 3; }; }
        { Status = { style = "row"; columns = 2; }; }
      ];
    };

    widgets = [
      {
        logo = {
          icon = "/images/monty-casa-crest.svg";
        };
      }
      {
        greeting = {
          text_size = "3xl";
          text = "Monty Casa Homelab";
        };
      }
      {
        resources = {
          cpu = true;
          memory = true;
          disk = "/";
        };
      }
      {
        search = {
          provider = "duckduckgo";
          target = "_blank";
        };
      }
    ];

    bookmarks = [
      {
        "Infrastructure" = [
          {
            "GitHub" = [{
                icon = "si-github";
                href = "https://github.com/monty033?tab=repositories";
            }];
          }
          {
            "Proxmox Helper Scripts" = [
              {
                icon = "https://raw.githubusercontent.com/tteck/Proxmox/main/misc/images/logo.png";
                href = "https://community-scripts.github.io/ProxmoxVE/scripts";
              }
            ];
          }
        ];
      }
      {
        "Cloud Storage" = [
          {
            "TrueCloud - Storj" = [
              {
                icon = "https://us1.storj.io/static/dist/assets/logo-dark-B-1o513O.svg";
                href = "https://us1.storj.io/projects/KCrA-smpTX2/dashboard";
              }
            ];
          }
        ];
      }
      {
        "Documentation" = [
          {
            "Home Assistant Docs" = [
              {
                icon = "sh-home-assistant.svg";
                href = "https://www.home-assistant.io/docs/";
              }
            ];
          }
          {
            "Homepage Docs" = [
              {
                icon = "sh-homepage.png";
                href = "https://gethomepage.dev/";
              }
            ];
          }
          {
            "Frigate Docs" = [
              {
                icon = "sh-frigate.svg";
                href = "https://docs.frigate.video/";
              }
            ];
          }
          {
            "NixOS Search" = [
              {
                icon = "sh-nixos.svg";
                href = "https://search.nixos.org/packages";
              }
            ];
          }
          {
            "NixOS Wiki" = [
              {
                icon = "sh-nixos.svg";
                href = "https://nixos.wiki/wiki/Main_Page";
              }
            ];
          }
          {
            "Ansible Docs" = [
              {
                icon = "sh-ansible.svg";
                href = "https://docs.ansible.com/ansible/latest/index.html";
              }
            ];
          }
        ];
      }
    ];

    services = [
      {
        "Status" = [
          {
            "Uptime Kuma" = {
              href = "https://uptime.montycasa.net";
              siteMonitor = "https://uptime.montycasa.net";
              icon = "sh-uptime-kuma.svg";
              widget = {
                type = "uptimekuma";
                url = "https://uptime.montycasa.net";
                slug = "homepage";
              };
            };
          }
          {
            "MySpeed" = {
              href = "https://myspeed.montycasa.net";
              siteMonitor = "https://myspeed.montycasa.net";
              icon = "sh-myspeed.png";
              widget = {
                type = "myspeed";
                url = "https://myspeed.montycasa.net";
              };
            };
          }
          {
            "Dockge" = {
              href = "https://dockge.montycasa.net";
              siteMonitor = "https://dockge.montycasa.net";
              icon = "sh-dockge.svg";
            };
          }
          {
            "Gotify" = {
              href = "https://notify.montycasa.com";
              siteMonitor = "https://notify.montycasa.com";
              icon = "sh-gotify.svg";
            };
          }
        ];
      }
      {
        "Proxmox" = [
          {
            "Stark" = {
              href = "https://stark.montycasa.net";
              siteMonitor = "https://stark.montycasa.net";
              description = "Proxmox VE";
              icon = "sh-proxmox.svg";
              widget = {
                type = "proxmox";
                url = "https://stark.montycasa.net";
                username = "{{HOMEPAGE_VAR_PROXMOX_USERNAME}}";
                password = "{{HOMEPAGE_VAR_PROXMOX_PASSWORD}}";
                node = "stark";
              };
            };
          }
          {
            "Loki" = {
              href = "https://loki.montycasa.net";
              siteMonitor = "https://loki.montycasa.net";
              description = "Proxmox VE";
              icon = "sh-proxmox.svg";
              widget = {
                type = "proxmox";
                url = "https://loki.montycasa.net";
                username = "{{HOMEPAGE_VAR_PROXMOX_USERNAME}}";
                password = "{{HOMEPAGE_VAR_PROXMOX_PASSWORD}}";
                node = "loki";
              };
            };
          }
          {
            "Starlord" = {
              href = "https://starlord.montycasa.net";
              siteMonitor = "https://starlord.montycasa.net";
              description = "Proxmox VE";
              icon = "sh-proxmox.svg";
              widget = {
                type = "proxmox";
                url = "https://starlord.montycasa.net";
                username = "{{HOMEPAGE_VAR_PROXMOX_USERNAME}}";
                password = "{{HOMEPAGE_VAR_PROXMOX_PASSWORD}}";
                node = "starlord";
              };
            };
          }
        ];
      }
      {
        "Storage" = [
          {
            "TrueNAS Home" = {
              href = "https://truenas.montycasa.net";
              siteMonitor = "https://truenas.montycasa.net";
              description = "TrueNAS Scale";
              icon = "sh-truenas-scale.svg";
              widget = {
                type = "truenas";
                url = "https://truenas.montycasa.net";
                key = "{{HOMEPAGE_VAR_TRUENAS_API_KEY}}";
                nasType = "scale";
              };
            };
          }
          {
            "Proxmox Backup Server" = {
              href = "https://pbs.montycasa.net";
              siteMonitor = "https://pbs.montycasa.net";
              icon = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/proxmox-light.png";
              widget = {
                type = "proxmoxbackupserver";
                url = "https://pbs.montycasa.net";
                username = "{{HOMEPAGE_VAR_PBS_USERNAME}}";
                password = "{{HOMEPAGE_VAR_PBS_PASSWORD}}";
              };
            };
          }
          {
            "Syncthing" = {
              href = "https://192.168.86.99:20910/";
              siteMonitor = "https://192.168.86.99:20910/";
              icon = "sh-syncthing.svg";
            };
          }
          {
            "Backblaze" = {
              href = "https://secure.backblaze.com/user_signin.htm";
              icon = "sh-backblaze.svg";
            };
          }
        ];
      }
      {
        "Other Machines" = [
          {
            "PiKVM" = {
              href = "https://pikvm.skink-galaxy.ts.net";
              siteMonitor = "https://pikvm.skink-galaxy.ts.net";
              icon = "https://avatars.githubusercontent.com/u/41749659?s=200&v=4";
            };
          }
          {
            "Yondu VS Code" = {
              href = "http://192.168.86.114:8680";
              siteMonitor = "http://192.168.86.114:8680";
              description = "VS Code Server for yondu server";
              icon = "https://cdn3.iconfinder.com/data/icons/marvel-avatars-flaticons/64/yondu-avangers-marvel-avatars-gartoon-marvel_avatars-hero-512.png";
            };
          }
        ];
      }
      {
        "Offsite" = [
          {
            "Wakanda" = {
              href = "https://wakanda.montycasa.net/";
              siteMonitor = "https://wakanda.montycasa.net/";
              description = "Offsite Proxmox VE";
              icon = "sh-proxmox.svg";
              widget = {
                type = "proxmox";
                url = "https://wakanda.montycasa.net";
                username = "{{HOMEPAGE_VAR_WAKANDA_USERNAME}}";
                password = "{{HOMEPAGE_VAR_WAKANDA_PASSWORD}}";
                node = "wakanda";
              };
            };
          }
          {
            "Bucky TrueNAS" = {
              href = "https://bucky.montycasa.net/";
              siteMonitor = "https://bucky.montycasa.net/";
              description = "Offsite TrueNAS Scale";
              icon = "sh-truenas-scale.svg";
              widget = {
                type = "truenas";
                url = "https://bucky.montycasa.net/";
                key = "{{HOMEPAGE_VAR_BUCKY_API_KEY}}";
                nasType = "scale";
              };
            };
          }
          {
            "Bucky Backup Link" = {
              href = "https://10.10.12.10";
              siteMonitor = "https://10.10.12.10";
              description = "Backup Link to Bucky";
              icon = "sh-truenas-scale.svg";
            };
          }
          {
            "DigitalOcean" = {
              href = "https://cloud.digitalocean.com/projects/8c2d35b4-ab76-4750-87db-4230144b4a44/resources?i=d4b54a";
              description = "DigitalOcean VPS";
              icon = "sh-digitalocean.svg";
            };
          }
        ];
      }
      {
        "Routers, DNS, Switches" = [
          {
            "OPNSense" = {
              href = "https://router.montycasa.net";
              siteMonitor = "https://router.montycasa.net";
              description = "Router/Firewall";
              icon = "sh-opnsense.svg";
              widget = {
                type = "opnsense";
                url = "https://router.montycasa.net";
                username = "{{HOMEPAGE_VAR_OPNSENSE_USERNAME}}";
                password = "{{HOMEPAGE_VAR_OPNSENSE_PASSWORD}}";
              };
            };
          }
          {
            "Adguard Home" = {
              href = "https://blocker.montycasa.net";
              siteMonitor = "https://blocker.montycasa.net";
              description = "Network DNS Adblocker";
              icon = "sh-adguard-home.svg";
              widget = {
                type = "adguard";
                url = "https://blocker.montycasa.net";
                username = "{{HOMEPAGE_VAR_ADGUARD_USERNAME}}";
                password = "{{HOMEPAGE_VAR_ADGUARD_PASSWORD}}";
              };
            };
          }
          {
            "Pi-hole 1" = {
              href = "https://pihole1.montycasa.net";
              siteMonitor = "https://pihole1.montycasa.net";
              description = "DNS Filtering — pihole1 (loki)";
              icon = "sh-pi-hole";
              widget = {
                type = "pihole";
                url = "https://pihole1.montycasa.net";
                version = 6;
                key = "{{HOMEPAGE_VAR_PIHOLE_API_KEY}}";
              };
            };
          }
          {
            "Pi-hole 2" = {
              href = "https://pihole2.montycasa.net";
              siteMonitor = "https://pihole2.montycasa.net";
              description = "DNS Filtering — pihole2 (stark)";
              icon = "sh-pi-hole";
              widget = {
                type = "pihole";
                url = "https://pihole2.montycasa.net";
                version = 6;
                key = "{{HOMEPAGE_VAR_PIHOLE_API_KEY}}";
              };
            };
          }
          {
            "Homelab 10GbE Aggregate Switch" = {
              href = "http://192.168.86.2/";
              siteMonitor = "http://192.168.86.2";
              description = "8x10GbE SPF+";
              icon = "mdi-router-network";
            };
          }
          {
            "Homelab 2.5GbE Switch" = {
              href = "http://192.168.86.6/";
              siteMonitor = "http://192.168.86.6";
              description = "1x10GbE SPF+ / 8x2.5GbE";
              icon = "mdi-router-network";
            };
          }
          {
            "Homelab 2.5GbE PoE Switch" = {
              href = "http://192.168.86.4/";
              siteMonitor = "http://192.168.86.4";
              description = "1x10GbE SPF+ / 8x2.5GbE PoE";
              icon = "mdi-router-network";
            };
          }
          {
            "Homelab 2.5GbE Mini Switch" = {
              href = "http://192.168.86.3/";
              siteMonitor = "http://192.168.86.3";
              description = "2x10GbE SPF+ / 4x2.5GbE";
              icon = "mdi-router-network";
            };
          }
          {
            "Basement PoE Switch" = {
              href = "http://192.168.86.5/";
              siteMonitor = "http://192.168.86.5";
              description = "8x1GbE with 4x PoE";
              icon = "mdi-router-network";
            };
          }
        ];
      }
      {
        "Access Points" = [
          {
            "Omada" = {
              href = "https://omada.montycasa.net";
              siteMonitor = "https://omada.montycasa.net";
              description = "Omada Controller";
              icon = "sh-omada.svg";
              widget = {
                type = "omada";
                url = "https://omada.montycasa.net";
                username = "{{HOMEPAGE_VAR_OMADA_USERNAME}}";
                password = "{{HOMEPAGE_VAR_OMADA_PASSWORD}}";
                site = "{{HOMEPAGE_VAR_OMADA_SITE}}";
              };
            };
          }
          {
            "Homelab AP" = {
              href = "http://192.168.86.11/";
              siteMonitor = "http://192.168.86.11/";
              description = "TP-Link Omada EAP723";
              icon = "mdi-access-point-network";
            };
          }
          {
            "Kitchen AP" = {
              href = "http://192.168.86.13/";
              siteMonitor = "http://192.168.86.13/";
              description = "TP-Link Omada EAP723";
              icon = "mdi-access-point-network";
            };
          }
          {
            "Garage AP" = {
              href = "http://192.168.86.15/";
              siteMonitor = "http://192.168.86.15/";
              description = "TP-Link Omada EAP235-Wall";
              icon = "mdi-access-point-network";
            };
          }
        ];
      }
      {
        "Remote Access" = [
          {
            "Pangolin" = {
              href = "https://pangolin.montycasa.com";
              siteMonitor = "https://pangolin.montycasa.com";
              description = "Proxy and Authentication";
              icon = "sh-pangolin.svg";
            };
          }
          {
            "Tailscale" = {
              href = "https://login.tailscale.com/admin/machines";
              description = "Mesh VPN";
              icon = "sh-tailscale.svg";
            };
          }
          {
            "Cloudflare" = {
              href = "https://dash.cloudflare.com/login";
              description = "Domain Name and DNS Service";
              icon = "sh-cloudflare.svg";
            };
          }
        ];
      }
      {
        "Home Automation" = [
          {
            "Home Assistant" = {
              href = "http://192.168.86.100:8123";
              siteMonitor = "http://192.168.86.100:8123";
              description = "Home Automation System";
              icon = "sh-home-assistant.svg";
            };
          }
          {
            "WLED Patio" = {
              href = "http://192.168.10.19/";
              siteMonitor = "http://192.168.10.19/";
              description = "Patio wall lights";
              icon = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/wled.png";
            };
          }
          {
            "WLED Cabinets" = {
              href = "http://192.168.10.17/";
              siteMonitor = "http://192.168.10.17/";
              description = "Kitchen under cabinet lights";
              icon = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/wled.png";
            };
          }
        ];
      }
      {
        "NVR" = [
          {
            "Frigate" = {
              href = "https://frigate.montycasa.net";
              siteMonitor = "https://frigate.montycasa.net";
              description = "Network Video Recorder";
              icon = "sh-frigate.svg";
            };
          }
          {
            "Bella's Room" = {
              href = "http://192.168.10.51/";
              siteMonitor = "http://192.168.10.51/";
              description = "IP Camera";
              icon = "mdi-webcam";
            };
          }
          {
            "Girls's Room" = {
              href = "http://192.168.10.50/";
              siteMonitor = "http://192.168.10.50/";
              description = "IP Camera";
              icon = "mdi-webcam";
            };
          }
          {
            "Nursery" = {
              href = "http://192.168.10.52/";
              siteMonitor = "http://192.168.10.52/";
              description = "IP Camera";
              icon = "mdi-webcam";
            };
          }
          {
            "Front Door" = {
              href = "http://192.168.10.54/";
              siteMonitor = "http://192.168.10.54/";
              description = "IP Camera";
              icon = "mdi-cctv";
            };
          }
          {
            "Back Door" = {
              href = "http://192.168.10.53/";
              siteMonitor = "http://192.168.10.53/";
              description = "IP Camera";
              icon = "mdi-cctv";
            };
          }
        ];
      }
      {
        "Media Servers" = [
          {
            "Jellyfin" = {
              href = "https://watchit.montycasa.com";
              siteMonitor = "https://watchit.montycasa.com";
              description = "Movie and TV Show Library";
              icon = "sh-jellyfin.svg";
              widget = {
                type = "jellyfin";
                url = "https://watchit.montycasa.com";
                key = "{{HOMEPAGE_VAR_JELLYFIN_KEY}}";
                enableNowPlaying = true;
                enableUser = true;
                showEpisodeNumber = true;
                expandOneStreamToTwoRows = false;
              };
            };
          }
          {
            "Immich" = {
              href = "https://photos.montycasa.com";
              siteMonitor = "https://photos.montycasa.com";
              description = "Photo Library";
              icon = "sh-immich.svg";
              widget = {
                type = "immich";
                url = "https://photos.montycasa.com";
                key = "{{HOMEPAGE_VAR_IMMICH_KEY}}";
                version = 2;
              };
            };
          }
          {
            "Audiobookshelf" = {
              href = "https://audiobooks.montycasa.com";
              siteMonitor = "https://audiobooks.montycasa.com";
              description = "Audiobook Library";
              icon = "sh-audiobookshelf.svg";
              widget = {
                type = "audiobookshelf";
                url = "https://audiobooks.montycasa.com";
                key = "{{HOMEPAGE_VAR_AUDIOBOOKSHELF_KEY}}";
              };
            };
          }
        ];
      }
      {
        "Aar" = [
          {
            "qBittorrent" = {
              href = "https://qbittorrent.montycasa.net";
              siteMonitor = "https://qbittorrent.montycasa.net";
              icon = "sh-qbittorrent.svg";
              widget = {
                type = "qbittorrent";
                url = "https://qbittorrent.montycasa.net";
                username = "{{HOMEPAGE_VAR_QBITTORRENT_USERNAME}}";
                password = "{{HOMEPAGE_VAR_QBITTORRENT_PASSWORD}}";
              };
            };
          }
          {
            "Radarr" = {
              href = "https://radarr.montycasa.net";
              siteMonitor = "https://radarr.montycasa.net";
              icon = "sh-radarr.svg";
              widget = {
                type = "radarr";
                url = "https://radarr.montycasa.net";
                key = "{{HOMEPAGE_VAR_RADARR_KEY}}";
                enableQueue = true;
              };
            };
          }
          {
            "Sonarr" = {
              href = "https://sonarr.montycasa.net";
              siteMonitor = "https://sonarr.montycasa.net";
              icon = "sh-sonarr.svg";
              widget = {
                type = "sonarr";
                url = "https://sonarr.montycasa.net";
                key = "{{HOMEPAGE_VAR_SONARR_KEY}}";
                enableQueue = true;
              };
            };
          }
          {
            "Bazarr" = {
              href = "https://bazarr.montycasa.net";
              siteMonitor = "https://bazarr.montycasa.net";
              icon = "sh-bazarr.png";
              widget = {
                type = "bazarr";
                url = "https://bazarr.montycasa.net";
                key = "{{HOMEPAGE_VAR_BAZARR_KEY}}";
              };
            };
          }
          {
            "Prowlarr" = {
              href = "https://prowlarr.montycasa.net";
              siteMonitor = "https://prowlarr.montycasa.net";
              icon = "sh-prowlarr.svg";
              widget = {
                type = "prowlarr";
                url = "https://prowlarr.montycasa.net";
                key = "{{HOMEPAGE_VAR_PROWLARR_KEY}}";
              };
            };
          }
          {
            "Pinchflat" = {
              href = "http://192.168.86.114:8945";
              siteMonitor = "http://192.168.86.114:8945";
              icon = "sh-pinchflat.png";
            };
          }
          {
            "Transmission" = {
              href = "http://192.168.86.114:9092/";
              siteMonitor = "http://192.168.86.114:9092/";
              description = "NO VPN";
              icon = "sh-transmission.svg";
              widget = {
                type = "transmission";
                url = "http://192.168.86.114:9092";
                username = "";
                password = "{{HOMEPAGE_VAR_TRANSMISSION_KEY}}";
                rpcUrl = "/transmission/";
              };
            };
          }
          {
            "Jackett" = {
              href = "http://192.168.86.114:9117/";
              siteMonitor = "http://192.168.86.114:9117/";
              description = "NO VPN";
              icon = "sh-jackett.svg";
              widget = {
                type = "jackett";
                url = "http://192.168.86.114:9117";
              };
            };
          }
          {
            "Youtarr" = {
              href = "https://youtarr.montycasa.net";
              siteMonitor = "https://youtarr.montycasa.net";
              icon = "sh-youtarr.png";
            };
          }
        ];
      }
      {
        "Apps" = [
          {
            "Nextcloud" = {
              href = "https://drive.montycasa.com";
              siteMonitor = "https://drive.montycasa.com";
              icon = "sh-nextcloud.png";
            };
          }
          {
            "MinusPod" = {
              href = "https://minuspod.montycasa.net/ui/";
              siteMonitor = "https://minuspod.montycasa.net/ui/";
              icon = "sh-minuspod.svg";
            };
          }
          {
            "Forgejo" = {
              href = "https://git.montycasa.net";
              siteMonitor = "https://git.montycasa.net";
              icon = "sh-forgejo.svg";
            };
          }
          {
            "Alby Hub" = {
              href = "https://ln.montybitcoin.com";
              siteMonitor = "https://ln.montybitcoin.com";
              icon = "si-alby";
            };
          }
          {
            "Karakeep" = {
              href = "https://keep.montycasa.com";
              siteMonitor = "https://keep.montycasa.com";
              icon = "sh-karakeep.svg";
            };
          }
          {
            "Paperless-ngx" = {
              href = "https://paperless.montycasa.net";
              siteMonitor = "https://paperless.montycasa.net";
              icon = "sh-paperless-ngx.svg";
            };
          }
          {
            "Mealie" = {
              href = "https://mealie.montycasa.com";
              siteMonitor = "https://mealie.montycasa.com";
              icon = "sh-mealie.svg";
            };
          }
          {
            "Endurain" = {
              href = "https://fit.montycasa.com";
              siteMonitor = "https://fit.montycasa.com";
              icon = "sh-endurain.svg";
            };
          }
          {
            "PocketID" = {
              href = "https://auth.montycasa.com";
              siteMonitor = "https://auth.montycasa.com";
              icon = "sh-pocket-id.svg";
            };
          }
        ];
      }
    ];
  };

  system.stateVersion = "25.05";
}
