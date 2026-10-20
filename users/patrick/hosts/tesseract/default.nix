{ config, pkgs, inputs, ... }: {

  imports = [ ../../common ];

  users.users.patrick = {

      packages = with pkgs; [
        nfs-utils
        standardnotes
        #cowsay
      ];
  };

  # Mount media NFS Share in home directory
  # These mounts go over Tailscale, so we need to ensure Tailscale is connected first
  fileSystems."/home/patrick/mnt/media" = {
    device = "truenas:/mnt/HDD-Mirror-01/media";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.idle-timeout=600"
      "x-systemd.device-timeout=5"
      "x-systemd.requires=tailscaled-autoconnect.service"
      "x-systemd.after=tailscaled-autoconnect.service"
      "soft"  # Fail faster if NFS server is unreachable
      "timeo=10"  # 1 second timeout (value is in deciseconds)
      "retrans=2"  # Only retry twice
    ];
  };

  # Mount home_media NFS Share in home directory
  fileSystems."/home/patrick/mnt/home_media" = {
    device = "truenas:/mnt/HDD-Mirror-01/home_media";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.idle-timeout=600"
      "x-systemd.device-timeout=5"
      "x-systemd.requires=tailscaled-autoconnect.service"
      "x-systemd.after=tailscaled-autoconnect.service"
      "soft"
      "timeo=10"
      "retrans=2"
    ];
  };

  # Mount nextcloud NFS Share in home directory
  fileSystems."/home/patrick/mnt/nextcloud" = {
    device = "truenas:/mnt/HDD-Mirror-01/drive/patrick/files";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.idle-timeout=600"
      "x-systemd.device-timeout=5"
      "x-systemd.requires=tailscaled-autoconnect.service"
      "x-systemd.after=tailscaled-autoconnect.service"
      "soft"
      "timeo=10"
      "retrans=2"
    ];
  };

  fileSystems."/home/patrick/mnt/general" = {
    device = "truenas:/mnt/HDD-Mirror-01/general";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.idle-timeout=600"
      "x-systemd.device-timeout=5"
      "x-systemd.requires=tailscaled-autoconnect.service"
      "x-systemd.after=tailscaled-autoconnect.service"
      "soft"
      "timeo=10"
      "retrans=2"
    ];
  };

  # Create mount point directories if they don't exist
  systemd.tmpfiles.rules = [
    "d /home/patrick/mnt 0755 patrick users -"
    "d /home/patrick/mnt/media 0755 patrick users -"
    "d /home/patrick/mnt/home_media 0755 patrick users -"
    "d /home/patrick/mnt/nextcloud 0755 patrick users -"
    "d /home/patrick/mnt/general 0755 patrick users -"
  ];

  # optional, but ensures rpc-statsd is running for on demand mounting
  boot.supportedFilesystems = [ "nfs" ];
  # Ensure network-online.target is enabled
  systemd.targets.network-online.enable = true;

}
