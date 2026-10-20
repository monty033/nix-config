{ config, lib, pkgs, ... }:

{

  imports = [

  ];

  networking.hostName = "nixbook";

  users.users.rocket = {
    isNormalUser = true;
    description = "Rocket";
    extraGroups = [ "networkmanager" "wheel" "storage" ];
    packages = with pkgs; [

    ];
  };

  environment.systemPackages = with pkgs; [

  ];

  system.stateVersion = "25.05";

}
