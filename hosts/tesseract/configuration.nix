# ThinkPad P53s Configuration
# Intel i7-8665U VPro @ 1.90GHz, 32GB RAM, 1TB NVMe, NVIDIA Quadro P520
# Optimized for Intel/NVIDIA hybrid graphics, LUKS encryption, and mobile use

{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    # ./hardware-configuration.nix  # Not needed - disko manages filesystems
    ./disk-config.nix
    ../../users/patrick/hosts/tesseract
    ../../users/lina/hosts/tesseract
    ../../secrets
  ];

  extra-services.desktop.enable = true;
  extra-services.tailscale.enable = true;
  # extra-services.mount_home_media.enable = true;
  extra-services.pbs-home-dirs.enable = true;
  extra-services.auto-upgrade.enable = true;
  extra-services.flutter = {
    enable = true;
    user = "patrick";
    enableAdb = true;
    addToKvmGroup = true;
  };
  extra-services.host-checkin = {
    enable = true;
    checkInInterval = "hourly";
    pullStates = true;
    stateFileDestination = "/home/patrick/nix-config";
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # Using LTS kernel for NVIDIA driver compatibility
    # Latest kernel (6.19+) has compatibility issues with NVIDIA proprietary drivers
    kernelPackages = pkgs.linuxPackages_6_12;

    # Keep more generations in bootloader for fallback
    loader.systemd-boot.configurationLimit = 10;

    kernelParams = [
      "quiet"
      "splash"
      "mem_sleep_default=deep"  # Better suspend support
      "intel_pstate=active"      # Intel Pstate for better power management
      "i915.enable_fbc=1"        # Framebuffer compression
      "i915.enable_psr=1"        # Panel self refresh
      "pcie_aspm=force"          # Force PCIe Active State Power Management
      "resume_offset=533760"    # IMPORTANT: Recalculate after install with: sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
      "nvme_core.default_ps_max_latency_us=5000"  # NVMe power saving (0=disabled, 5000=moderate savings) - test for stability
      "nvidia.NVreg_PreserveVideoMemoryAllocations=0"  # Disabled for conservative power mgmt - change to 1 if enabling finegrained
    ];

    initrd.availableKernelModules = [
      "xhci_pci"
      "nvme"
      "usb_storage"
      "sd_mod"
      "rtsx_pci_sdmmc"
      "iwlwifi"  # Intel WiFi driver
    ];

    # Enable Intel microcode updates and early KMS
    kernelModules = [ "kvm-intel" "iwlwifi" "iwlmvm" ];  # iwlwifi + iwlmvm for Intel WiFi
    initrd.kernelModules = [ "i915" ];  # Intel graphics early init for smoother boot

    # Hibernation configuration
    resumeDevice = "/dev/mapper/cryptroot";

    # Intel i915 graphics optimizations (UHD Graphics 620)
    extraModprobeConfig = ''
      options i915 enable_guc=3
      options i915 enable_fbc=1

      # Bluetooth fixes for resume from suspend/hibernate
      # Keep autosuspend disabled here; current kernels ignore btusb.reset_resume.
      options btusb enable_autosuspend=0
      options bluetooth disable_ertm=1

      # Intel WiFi (iwlwifi) fixes for resume from suspend/hibernate
      options iwlwifi power_save=0
      options iwlmvm power_scheme=1
    '';
  };

  networking = {
    hostName = "tesseract";
    networkmanager = {
      enable = true;
      wifi = {
        powersave = false;  # Disabled for reliable resume - change to true if battery life is critical
        scanRandMacAddress = true;
      };
      # Ensure WiFi is managed by NetworkManager
      unmanaged = [ ];
    };

    useDHCP = lib.mkDefault true;

    # Make sure wireless is enabled globally
    wireless.enable = lib.mkDefault false;  # Disable wpa_supplicant (conflicts with NetworkManager)

    # Firewall
    firewall = {
      enable = true;
      # Add any specific ports you need
      # allowedTCPPorts = [ ];
      # allowedUDPPorts = [ ];
    };
  };

  # Enable WiFi firmware for Intel WiFi (P53s: typically AX200/9560)
  hardware.enableRedistributableFirmware = lib.mkForce true;

  # Explicitly include Intel WiFi firmware packages
  hardware.firmware = with pkgs; [
    wireless-regdb
    linux-firmware
  ];

  hardware = {
    cpu.intel.updateMicrocode = true;

    # Ensure WiFi firmware is available
    enableAllFirmware = lib.mkForce true;

    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-media-driver  # LIBVA_DRIVER_NAME=iHD
        intel-vaapi-driver  # LIBVA_DRIVER_NAME=i965 (older but sometimes better)
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Disable experimental features that can cause resume issues
          Experimental = false;
        };
        Policy = {
          # Auto-enable Bluetooth controllers
          AutoEnable = true;
        };
      };
    };

    trackpoint = {
      enable = true;
      emulateWheel = true;
      sensitivity = 220;
      speed = 97;
    };

    # NVIDIA Configuration - Prime Offload (On-Demand)
    # Best for battery life - NVIDIA only used when explicitly requested
    nvidia = {
      modesetting.enable = true;
      powerManagement.enable = false;  # Disabled initially - enable after confirming hibernate works
      powerManagement.finegrained = false;  # Disabled initially - can enable for battery life after testing
      open = false;  # Use proprietary driver (better support for Quadro P520/Pascal)
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;  # Production driver for Quadro

      # NVIDIA Optimus PRIME - Offload Mode (Current)
      # Use 'nvidia-offload <command>' or 'nvidia-run <command>' to run apps with NVIDIA
      prime = {
        offload = {
          enable = true;
          enableOffloadCmd = true;  # Provides nvidia-offload command
        };

        # Alternative: Sync Mode (uncomment to use)
        # Both GPUs always active - worse battery, better compatibility
        # To switch: comment out 'offload' section above, uncomment below
        # sync.enable = true;

        # IMPORTANT: Verify these PCI Bus IDs after installation with: lspci | grep -E "VGA|3D"
        # Intel UHD Graphics 620 and NVIDIA Quadro P520
        # Verified: Intel at 00:02.0, NVIDIA at 3c:00.0 (60 in decimal)
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:60:0:0";  # 3c:00.0 in hex = 60:0:0 in decimal
      };
    };
  };

  # Enable zram for better performance
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;  # Reduced from 50% - with 32GB RAM, less zram needed
    priority = 100;  # Higher priority = used first (before disk swap)
  };

  # Disk swap is managed by disko (see disk-config.nix)
  # swapDevices removed to prevent duplicate entry error

  services = {

    power-profiles-daemon.enable = true;

    # Use TLP or power-profiles-daemon
    # tlp = {
    #   enable = true;
    #   settings = {
    #     # CPU scaling governor
    #     # On AC: full performance, On battery: balanced (can use 'sudo tlp ac' for temp performance boost)
    #     CPU_SCALING_GOVERNOR_ON_AC = "performance";
    #     CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

    #     # CPU Energy/Performance Policy (HWP)
    #     CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
    #     CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";

    #     # Allow turbo boost (can be enabled for performance when needed)
    #     CPU_BOOST_ON_AC = 1;
    #     CPU_BOOST_ON_BAT = 1;  # Enable turbo even on battery (you can disable if needed)

    #     # Platform profile (for systems that support it)
    #     PLATFORM_PROFILE_ON_AC = "performance";
    #     PLATFORM_PROFILE_ON_BAT = "balanced";

    #     # NVMe power management: Controlled via kernel parameter (nvme_core.default_ps_max_latency_us=0)
    #     # Set to 0 for max stability - prevents NVMe from entering power-saving states

    #     # WiFi power saving
    #     WIFI_PWR_ON_AC = "off";
    #     WIFI_PWR_ON_BAT = "on";
    #   };
    # };

    # Periodical TRIM for SSD longevity and performance
    fstrim.enable = true;

    # Btrfs automatic scrubbing for data integrity
    btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };

    # Btrfs snapshots with btrbk
    btrbk.instances.btrbk = {
      onCalendar = "hourly";
      settings = {
        timestamp_format = "long";
        snapshot_preserve_min = "latest";
        # Keep: 48 hourly, 7 daily, 4 weekly, 6 monthly
        snapshot_preserve = "48h 7d 4w 6m";

        # Snapshot root subvolume
        volume."/" = {
          snapshot_dir = ".snapshots";
          subvolume = ".";
        };

        # Snapshot home subvolume
        volume."/home" = {
          snapshot_dir = ".snapshots";
          subvolume = ".";
        };
      };
    };

    # udev rules for better power management
    udev.extraRules = ''
      # Disable autosuspend for the internal Bluetooth adapter and fingerprint reader.
      # TEST ensures the attribute exists before we try to write it.
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0aaa", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0aaa", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="06cb", ATTR{idProduct}=="00bd", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="06cb", ATTR{idProduct}=="00bd", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
      ACTION=="add", SUBSYSTEM=="usb", DRIVER=="btusb", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="bluetooth", TEST=="power/control", ATTR{power/control}="on"
    '';

    # Thermal management
    thermald.enable = true;

    # Intel CPU throttling fix (BD PROCHOT workaround)
    # Disables unnecessary throttling and can improve performance/thermals
    throttled.enable = true;

    # Firmware updates
    fwupd.enable = true;

    logind.settings.Login = {
      HandleLidSwitch = "suspend";  # Suspend first, then hibernate after timeout
      HandleLidSwitchDocked = "ignore";
      HandleLidSwitchExternalPower = "suspend";
    };
  };

  # Configure suspend-then-hibernate timing
  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "2h";
  };

  # Btrfs automatic balance for metadata optimization
  # Runs monthly to prevent metadata fragmentation and maintain performance
  systemd.services.btrfs-balance = {
    description = "Balance btrfs filesystem";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.btrfs-progs}/bin/btrfs balance start -dusage=50 -musage=50 /";
    };
  };

  systemd.timers.btrfs-balance = {
    description = "Monthly btrfs balance";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Create snapshot directories for btrbk
  systemd.tmpfiles.rules = [
    "d /.snapshots 0755 root root -"
    "d /home/.snapshots 0755 root root -"
  ];

  # Prepare Bluetooth and the Synaptics fingerprint reader for suspend/hibernate.
  # Starting fprintd from a system-sleep hook causes it to race the active sleep
  # transaction, so we stop it before sleep and let normal D-Bus activation bring
  # it back after resume.
  environment.etc."systemd/system-sleep/fix-bluetooth-fprintd".source = pkgs.writeShellScript "fix-bluetooth-fprintd" ''
    set -eu

    sleep_bin="${pkgs.coreutils}/bin/sleep"
    systemctl_bin="${pkgs.systemd}/bin/systemctl"

    find_usb_device() {
      wanted_vendor="$1"
      wanted_product="$2"

      for dev in /sys/bus/usb/devices/*; do
        [ -f "$dev/idVendor" ] || continue

        read -r vendor < "$dev/idVendor" || continue
        read -r product < "$dev/idProduct" || continue

        [ "$vendor" = "$wanted_vendor" ] || continue
        [ "$product" = "$wanted_product" ] || continue

        printf '%s\n' "''${dev##*/}"
        return 0
      done

      return 1
    }

    set_usb_power_policy() {
      dev="$1"
      dev_path="/sys/bus/usb/devices/$dev"

      [ -d "$dev_path" ] || return 0
      [ -w "$dev_path/power/control" ] && printf 'on\n' > "$dev_path/power/control" || true
      [ -w "$dev_path/power/autosuspend" ] && printf '%s\n' '-1' > "$dev_path/power/autosuspend" || true
    }

    case $1 in
      pre)
        "$systemctl_bin" stop fprintd.service || true
        "$systemctl_bin" stop bluetooth.service || true
        ;;
      post)
        # Wait a bit for devices to settle
        "$sleep_bin" 2

        bluetooth_usb_device="$(find_usb_device 8087 0aaa || true)"
        fingerprint_usb_device="$(find_usb_device 06cb 00bd || true)"

        [ -n "$bluetooth_usb_device" ] && set_usb_power_policy "$bluetooth_usb_device"
        [ -n "$fingerprint_usb_device" ] && set_usb_power_policy "$fingerprint_usb_device"

        "$systemctl_bin" reset-failed bluetooth.service fprintd.service || true
        "$systemctl_bin" start bluetooth.service || true
        ;;
    esac
  '';

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  # Use systemd in initrd (required for TPM2)
  boot.initrd.systemd.enable = true;

  # Systemd optimizations for faster shutdown/reboot
  systemd.settings.Manager = {
    DefaultTimeoutStopSec = "10s";

    # Configure watchdog to avoid shutdown delays while keeping hardware protection
    # RuntimeWatchdogSec=0: Don't ping watchdog during normal operation
    # RebootWatchdogSec=10min: Still use watchdog to recover from hangs during reboot
    # This prevents "watchdog did not stop" messages and speeds up shutdown
    RuntimeWatchdogSec = "0";      # Disable runtime watchdog pinging
    RebootWatchdogSec = "10min";   # Keep reboot protection
  };

  # Enable systemd-oomd for better memory pressure handling
  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };

  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" "modesetting" ];

    # Keyboard layout
    xkb = {
      layout = "us";
      variant = "";
    };
  };

  # Display Manager (moved out of xserver in 25.05)
  services.displayManager.sddm = {
    enable = true;
    autoNumlock = true;
  };

  # Session startup commands (for Plasma/X11 sessions)
  services.xserver.displayManager.sessionCommands = ''
    ${pkgs.numlockx}/bin/numlockx on
  '';

  # Touchpad configuration (moved out of xserver in 25.05)
  services.libinput = {
    enable = true;
    touchpad = {
      naturalScrolling = true;
      tapping = true;
      disableWhileTyping = true;
      accelProfile = "adaptive";
    };
  };

  services.desktopManager.plasma6.enable = true;

  # Audio configuration
  services.pulseaudio.enable = false;  # Using PipeWire instead
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Enable AppImage support
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  services.printing = {
    enable = true;
    # drivers = [ pkgs.canon-cups-ufr2 ];  # Disabled - causes build issues and may not be needed
    browsing = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      workstation = true;
      addresses = true;
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  services.fprintd = {
    enable = true;
    # P53s uses Synaptics fingerprint sensor
  };

  environment.systemPackages = with pkgs; [
    # From hp-nixos
    # Ansible with Docker SDK support for community.docker modules
    (ansible.overridePythonAttrs (old: {
      propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [
        python3Packages.docker
      ];
    }))
    # ansible-lint  # Temporarily disabled due to dependency conflict in nixpkgs 25.05
    terraform
    sshpass
    vlc
    jq
    numlockx

    # ThinkPad specific tools
    lm_sensors
    powertop
    acpi
    tpm2-tools
    throttled  # Intel throttling fix for better thermals/performance on i7-8665U

    # NVIDIA tools
    nvtopPackages.nvidia  # Use nvidia variant instead of full (avoids CUDA dependencies)

    # Hibernation tools
    pmutils

    # Intel GPU tools
    intel-gpu-tools
    libva-utils

    android-studio
    android-tools

    # 3D printing
    orca-slicer
    (pkgs.callPackage ../../packages/elegoo-slicer.nix {})
  ];

  fonts.packages = with pkgs; [
    source-han-sans
    noto-fonts
  ];

  environment.variables = {
    # Use Intel GPU by default
    # For NVIDIA, use: nvidia-offload <command>
    LIBVA_DRIVER_NAME = "iHD";  # or "i965" if iHD doesn't work well
  };

  environment.shellAliases = {
    # Run applications with NVIDIA GPU
    nvidia-run = "nvidia-offload";
  };

  time.timeZone = "America/New_York";

  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
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
  };

  system.stateVersion = "25.05";
}
