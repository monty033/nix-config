{ config, lib, pkgs, ... }:

{

  imports = [
      ./hardware-configuration.nix
  ];

  networking.hostName = "emma-book";

  extra-services.tailscale = {
    enable = true;
    # tags = ["tag:receive-only"];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/0f2ce08a-5508-4532-b82e-c9007e22776d";
    fsType = "ext4";
    options = [
      "defaults"
      "user_xattr"
      "acl"
      "noatime"        # Reduce write operations
      "commit=60"      # Commit changes every 60 seconds
    ];
  };

  users.users.emma = {
    isNormalUser = true;
    description = "Emma";
    extraGroups = [ "networkmanager" "wheel" "storage" ];
    packages = with pkgs; [
    #  thunderbird
      simplex-chat-desktop
      cowsay
    ];
  };

  # Configure sudo to use root's password for emma
  security.sudo.extraConfig = ''
    Defaults:emma rootpw
  '';

  environment.systemPackages = with pkgs; [

  ];

  system.stateVersion = "25.05";

}
