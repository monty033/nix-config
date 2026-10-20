{ config, lib, pkgs, ... }:

{

  imports = [
      ./hardware-configuration.nix
  ];

  networking.hostName = "cora-book";

  extra-services.tailscale = {
    enable = true;
    # tags = ["tag:receive-only"];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/b665e92a-8ae2-4a9a-9cb1-ac984d759604";
    fsType = "ext4";
    options = [
      "defaults"
      "user_xattr"
      "acl"
      "noatime"        # Reduce write operations
      "commit=60"      # Commit changes every 60 seconds
    ];
  };

  users.users.cora = {
    isNormalUser = true;
    description = "Cora";
    extraGroups = [ "networkmanager" "wheel" "storage" ];
    packages = with pkgs; [
      simplex-chat-desktop
      cowsay
    ];
  };

  # Configure sudo to use root's password for cora
  security.sudo.extraConfig = ''
    Defaults:cora rootpw
  '';

  environment.systemPackages = with pkgs; [

  ];

  system.stateVersion = "25.05";

}
