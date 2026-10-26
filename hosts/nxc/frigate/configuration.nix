{ config, pkgs, modulesPath, inputs, outputs, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  # No extra packages needed - Frigate includes go2rtc

  networking.hostName = "frigate";

  services.openssh.enable = true;

  extra-services.tailscale = {
    enable = true;
    lxc = true;
  };
  extra-services.host-checkin.enable = true;

  systemd.tmpfiles.rules = [
    "d /mnt/media 0755 root root -"
    "d /var/lib/frigate/cache 0755 frigate frigate -"
    "d /var/lib/frigate/model_cache 0755 frigate frigate -"
    "d /media 0755 root root -"
    "L+ /media/frigate - - - - /var/lib/frigate"
    "d /run/frigate-snapshots 0755 root root -"
  ];

  extra-services.mount_media.enable = true;

  # Configure SOPS secrets for Frigate
  sops.secrets.frigate-env = {};

  # Go2RTC is now managed by the Frigate container

  # Enable Podman for running Frigate OCI container
  virtualisation.podman = {
    enable = true;
    # Required for containers to access host network
    defaultNetwork.settings.dns_enabled = true;
  };

  # Frigate NVR as OCI Container
  virtualisation.oci-containers = {
    backend = "podman";
    containers.frigate = {
      # 0.18 runs a one-way database migration on first start. The database is
      # /var/lib/frigate/frigate.db (WAL mode); take a consistent backup with
      # SQLite's online-backup API before the first boot of this generation.
      # Rolling back to 0.17.2 means stopping the container, restoring that
      # backup, and removing any stale -wal/-shm sidecars beside it.
      # Keep frigate-config.yml's version: key matching this image's config
      # version -- any 0.18.x reports 0.18-0.
      image = "ghcr.io/blakeblackshear/frigate:0.18.2";

      # Use host network mode for easier access to go2rtc
      extraOptions = [
        "--network=host"
        "--shm-size=256m"
        "--device=/dev/dri/renderD128:/dev/dri/renderD128"
        "--device=/dev/dri/card0:/dev/dri/card0"
        "--group-add=${toString config.hardware.intelGpu.renderGid}"
        "--group-add=${toString config.hardware.intelGpu.videoGid}"
        "--cap-add=CAP_PERFMON"  # Performance monitoring capability
        "--tmpfs=/tmp/cache:size=1G"  # Tmpfs for cache (reduces disk wear)
      ];

      volumes = [
        "/var/lib/frigate:/var/lib/frigate"
        "/var/lib/frigate:/media/frigate"  # Backward compatibility for old database paths
        "/run/frigate-config:/config"
        "/var/lib/frigate/model_cache:/config/model_cache"
        "/etc/localtime:/etc/localtime:ro"  # Match host timezone
        "/run/frigate-snapshots:/run/frigate-snapshots:ro"  # Polled kiosk camera snapshots
      ];

      environment = {
        LIBVA_DRIVER_NAME = "iHD";
        FRIGATE_MQTT_PASSWORD = "\${FRIGATE_MQTT_PASSWORD}";
        FRIGATE_CAMERA_PASSWORD = "\${FRIGATE_CAMERA_PASSWORD}";
        FRIGATE_KIOSK_PASSWORD = "\${FRIGATE_KIOSK_PASSWORD}";
      };

      environmentFiles = [
        config.sops.secrets.frigate-env.path
      ];
    };
  };

  # Create runtime config directory and substitute secrets
  systemd.services.podman-frigate = {
    preStart = ''
      # Create config directory
      mkdir -p /run/frigate-config

      # Load environment variables without letting bash expand $ sequences
      # in the values (source/set -a would treat e.g. a literal "$4" in a
      # password as a positional parameter and silently truncate it)
      while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        case "$key" in \#*) continue ;; esac
        export "$key=$value"
      done < ${config.sops.secrets.frigate-env.path}

      # Escape sed metacharacters (\, /, &) in secret values so passwords
      # containing them don't corrupt or truncate the substitution
      escape_sed() {
        printf '%s' "$1" | ${pkgs.gnused}/bin/sed -e 's/[\/&\\]/\\&/g'
      }

      # Substitute environment variables in config
      ${pkgs.gnused}/bin/sed \
        -e "s/{FRIGATE_MQTT_PASSWORD}/$(escape_sed "$FRIGATE_MQTT_PASSWORD")/g" \
        -e "s/{FRIGATE_CAMERA_PASSWORD}/$(escape_sed "$FRIGATE_CAMERA_PASSWORD")/g" \
        -e "s/{FRIGATE_KIOSK_PASSWORD}/$(escape_sed "$FRIGATE_KIOSK_PASSWORD")/g" \
        ${./frigate-config.yml} > /run/frigate-config/config.yml
    '';

    # Ensure NFS mount is available before starting Frigate
    requires = [ "mnt-media.mount" ];
    after = [ "mnt-media.mount" ];
  };

  # Poll the kitchen kiosk's snapshot endpoint and write it to a local file.
  # ffmpeg's image2/mjpeg demuxers can't reliably probe a fresh single-JPEG
  # HTTP response as a "stream" (no seeking, no re-fetch on loop), so we
  # fetch it ourselves and let frigate's ffmpeg read a local file instead,
  # which -loop 1 -f image2 handles natively.
  #
  # Keep this as one persistent service rather than a one-shot service driven
  # by a one-second timer. Five successful starts in systemd's default ten-
  # second window hit the start-rate limiter even when every fetch succeeds.
  systemd.services.frigate-kitchen-snapshot = {
    description = "Poll kitchen kiosk camera snapshot";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startLimitIntervalSec = 10;
    startLimitBurst = 5;
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      set -u

      while IFS='=' read -r key value; do
        [ -z "$key" ] && continue
        case "$key" in \#*) continue ;; esac
        export "$key=$value"
      done < ${config.sops.secrets.frigate-env.path}

      snapshot=/run/frigate-snapshots/kitchen.jpg
      temporary="$snapshot.tmp"
      consecutive_failures=0

      while :; do
        if ${pkgs.curl}/bin/curl \
          --fail --silent --show-error \
          --connect-timeout 3 --max-time 5 \
          "http://192.168.86.228:2323/?cmd=getCamshot&password=$FRIGATE_KIOSK_PASSWORD" \
          --output "$temporary" \
          && test -s "$temporary" \
          && mv -f -- "$temporary" "$snapshot"; then
          if [ "$consecutive_failures" -gt 0 ]; then
            echo "Kitchen kiosk snapshot fetch recovered" >&2
          fi
          consecutive_failures=0
        else
          rm -f -- "$temporary"
          consecutive_failures=$((consecutive_failures + 1))
          echo "Kitchen kiosk snapshot fetch failed ($consecutive_failures consecutive failures)" >&2

          if [ "$consecutive_failures" -ge 5 ]; then
            rm -f -- "$snapshot"
            echo "Kitchen kiosk snapshot is stale; removed it so Frigate can surface input loss" >&2
            exit 1
          fi
        fi

        sleep 1
      done
    '';
  };

  hardware.intelGpu = {
    enable = true;
    users = [ "frigate" ];
    videoAccess = true;
    videoProcessing = true;
  };

  # Keep the container's explicit device and group flags; the shared module
  # supplies the same host-specific numeric values declaratively.

  # Bind mount NFS recordings and exports to Frigate directories
  fileSystems."/var/lib/frigate/recordings" = {
    device = "/mnt/media/frigate/recordings";
    fsType = "none";
    options = [ "bind" ];
  };

  fileSystems."/var/lib/frigate/exports" = {
    device = "/mnt/media/frigate/exports";
    fsType = "none";
    options = [ "bind" ];
  };


  # Mount tmpfs for cache (reduces SSD wear)
  fileSystems."/var/lib/frigate/cache" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "size=1G" "mode=0755" ];
  };

  # Frigate container exposes port 5000 directly via --network=host

  # Open firewall ports for Frigate
  networking.firewall.allowedTCPPorts = [
    5000   # Web UI
    8554   # RTSP feeds
    8555   # WebRTC TCP
    1984   # Go2RTC API
    8971   # Additional Go2RTC port
  ];
  networking.firewall.allowedUDPPorts = [
    8555   # WebRTC UDP
  ];

  system.stateVersion = "25.05";
}
