{ config, lib, pkgs, ... }:

{

  imports = [
      ./hardware-configuration.nix
  ];

  networking.hostName = "ali-book";

  extra-services.tailscale = {
    enable = true;
    # tags = ["tag:receive-only"];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/fcf87905-cdb2-48d3-bf33-7e47d50e33f4";
    fsType = "ext4";
    options = [
      "defaults"
      "user_xattr"
      "acl"
      "noatime"        # Reduce write operations
      "commit=60"      # Commit changes every 60 seconds
    ];
  };

  users.users.aleandra = {
    isNormalUser = true;
    description = "Aleandra";
    extraGroups = [ "networkmanager" "storage" "wheel" ];
    packages = with pkgs; [
      simplex-chat-desktop
      cowsay
    ];
  };

  # Configure sudo to use root's password for aleandra
  security.sudo.extraConfig = ''
    Defaults:aleandra rootpw
  '';

  environment.systemPackages = with pkgs; [

  ];

  system.stateVersion = "25.05";

}
