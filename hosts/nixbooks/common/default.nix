{ config, lib, pkgs, ... }:
{
  imports = [ ../../common ];

  extra-services.auto-upgrade = {
    enable = true;
    buildHost = "root@nix-fury";
  };

  extra-services.host-checkin.enable = true;
  nix.settings.auto-optimise-store = true;

  environment.systemPackages = with pkgs; [
    git
    firefox
    libnotify
    gawk
    sudo
    gnome-calculator
    # gnome-calendar
    gnome-screenshot
    system-config-printer

    # SSH client wrappers - require sudo for non-root users
    (writeShellScriptBin "ssh" ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "Error: SSH requires elevated privileges. Please use: sudo ssh $*" >&2
        exit 1
      fi
      exec ${openssh}/bin/ssh "$@"
    '')
    (writeShellScriptBin "scp" ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "Error: SCP requires elevated privileges. Please use: sudo scp $*" >&2
        exit 1
      fi
      exec ${openssh}/bin/scp "$@"
    '')
    (writeShellScriptBin "sftp" ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "Error: SFTP requires elevated privileges. Please use: sudo sftp $*" >&2
        exit 1
      fi
      exec ${openssh}/bin/sftp "$@"
    '')
  ];

  services.flatpak.enable = true;
  programs.firefox.enable = true;

  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;
  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon
  services.openssh.enable = true;

  zramSwap.enable = true;
  zramSwap.memoryPercent = 100;
  systemd.settings.Manager = {
    DefaultTimeoutStopSec = "10s";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  # nixpkgs.config.allowUnfree is set in hosts/common/default.nix.
  hardware.bluetooth.enable = true;

  # Enable the Cinnamon Desktop Environment.
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.desktopManager.cinnamon.enable = true;
  xdg.portal.enable = true;

  # Enable Printing
  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Fix for the pesky "insecure" broadcom
  nixpkgs.config.allowInsecurePredicate = pkg:
    builtins.elem (lib.getName pkg) [
    "broadcom-sta" # aka “wl”
  ];

  # Override the default nh clean to reduce disk space on nixbooks
  programs.nh.clean = {
    dates = lib.mkForce "daily";
    extraArgs = lib.mkForce "--keep 3";
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

}
