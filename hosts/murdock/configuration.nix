# ThinkPad T15 Gen 2 Configuration
# Intel i7-1185G7 (Tiger Lake) @ 3.0GHz, 24GB RAM, Intel Iris Xe Graphics
# Intel-only graphics (no discrete GPU), LUKS encryption, mobile use

{ config, lib, pkgs, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; config = pkgs.config; };
  pkgs-elegoo-compat = import inputs.nixpkgs-elegoo-compat { inherit (pkgs.stdenv) system; config = { allowUnfree = true; }; };
in
{
  nixpkgs.overlays = [
    (final: prev: {
      orca-slicer = prev.symlinkJoin {
        name = "orca-slicer-wrapped";
        paths = [ prev.orca-slicer ];
        buildInputs = [ prev.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/orca-slicer \
            --prefix LD_LIBRARY_PATH : "${pkgs-unstable.pango}/lib:${pkgs-unstable.pango.out}/lib"
        '';
      };
    })
  ];

  imports = [
    # ./hardware-configuration.nix  # Not needed - disko manages filesystems
    ./disk-config.nix
    ../../users/patrick/hosts/murdock
    ../../users/lina/hosts/murdock
    ../../secrets
  ];

  # Reuse Hermes' encrypted OpenCode environment file for the client wrapper.
  # SOPS materializes a Murdock-local copy readable only by Patrick.
  sops.secrets."opencode-server-env" = {
    owner = "patrick";
    mode = "0400";
  };

  extra-services.desktop.enable = true;
  extra-services.tailscale.enable = true;
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

    loader.systemd-boot.configurationLimit = 10;

    kernelParams = [
      "quiet"
      "splash"
      "mem_sleep_default=deep"
      "intel_pstate=active"
      "i915.enable_fbc=1"
      "i915.enable_psr=1"
      "pcie_aspm=force"
      # IMPORTANT: Recalculate after install with:
      # sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
      # Then update this value and rebuild.
      "resume_offset=533760"
      "nvme_core.default_ps_max_latency_us=5000"
    ];

    initrd.availableKernelModules = [
      "xhci_pci"
      "nvme"
      "usb_storage"
      "sd_mod"
      "rtsx_pci_sdmmc"
    ];

    # NOTE: iwlwifi/iwlmvm are deliberately NOT force-loaded here. Loading them
    # in the initrd or eagerly at stage-2 races the linux-firmware store mount:
    # the AX201 firmware (iwlwifi-QuZ-a0-hr-b0-77.ucode) lives in /nix/store and
    # isn't reachable that early, so the request fails with ENOENT and the kernel
    # never retries → no wlan interface. Letting PCI probing auto-load the module
    # after userspace/firmware is up makes wifi come up reliably.
    kernelModules = [ "kvm-intel" ];
    initrd.kernelModules = [ "i915" ];

    resumeDevice = "/dev/mapper/cryptroot";

    extraModprobeConfig = ''
      options i915 enable_guc=3
      options i915 enable_fbc=1

      options btusb enable_autosuspend=0
      options bluetooth disable_ertm=1

      options iwlwifi power_save=0
      options iwlmvm power_scheme=1
    '';
  };

  networking = {
    hostName = "murdock";
    networkmanager = {
      enable = true;
      wifi = {
        powersave = false;
        scanRandMacAddress = true;
      };
      unmanaged = [ ];
    };

    useDHCP = lib.mkDefault true;
    wireless.enable = lib.mkDefault false;

    firewall = {
      enable = true;
    };
  };

  hardware.enableRedistributableFirmware = lib.mkForce true;

  hardware.firmware = with pkgs; [
    wireless-regdb
    linux-firmware
  ];

  hardware = {
    cpu.intel.updateMicrocode = true;

    enableAllFirmware = lib.mkForce true;

    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-media-driver   # LIBVA_DRIVER_NAME=iHD (recommended for Iris Xe)
        intel-vaapi-driver   # LIBVA_DRIVER_NAME=i965 (fallback)
        libva-vdpau-driver
        libvdpau-va-gl
      ];
    };

    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          Experimental = false;
        };
        Policy = {
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
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
    priority = 100;
  };

  # Offload builds to nix-fury. Applies to `nix build` / `nixos-rebuild`
  # commands run locally on murdock — including cross-host builds like
  # `nix build .#nixosConfigurations.hermes.config.system.toplevel` and
  # `nixos-rebuild switch --target-host hermes`.
  nix.buildMachines = [{
    hostName = "nix-fury";
    systems = [ "x86_64-linux" ];
    maxJobs = 8;
    speedFactor = 4;
    supportedFeatures = [ "big-parallel" "nixos-test" "kvm" ];
  }];
  nix.distributedBuilds = true;

  services = {

    power-profiles-daemon.enable = true;

    fstrim.enable = true;

    btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
      fileSystems = [ "/" ];
    };

    btrbk.instances.btrbk = {
      onCalendar = "hourly";
      settings = {
        timestamp_format = "long";
        snapshot_preserve_min = "latest";
        snapshot_preserve = "48h 7d 4w 6m";

        volume."/" = {
          snapshot_dir = ".snapshots";
          subvolume = ".";
        };

        volume."/home" = {
          snapshot_dir = ".snapshots";
          subvolume = ".";
        };
      };
    };

    # Verified USB IDs from `lsusb` on T15 Gen 2:
    # Bluetooth: 8087:0026, Fingerprint: 06cb:00bd
    udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0026", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0026", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="06cb", ATTR{idProduct}=="00bd", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="06cb", ATTR{idProduct}=="00bd", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
      ACTION=="add", SUBSYSTEM=="usb", DRIVER=="btusb", TEST=="power/control", ATTR{power/control}="on"
      ACTION=="add", SUBSYSTEM=="bluetooth", TEST=="power/control", ATTR{power/control}="on"
    '';

    thermald.enable = true;

    throttled.enable = true;

    fwupd.enable = true;

    logind.settings.Login = {
      HandleLidSwitch = "suspend-then-hibernate";
      HandleLidSwitchDocked = "ignore";
      HandleLidSwitchExternalPower = "suspend-then-hibernate";
    };
  };

  systemd.sleep.settings.Sleep = {
    HibernateDelaySec = "20min";
  };

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

  systemd.tmpfiles.rules = [
    "d /.snapshots 0755 root root -"
    "d /home/.snapshots 0755 root root -"
  ];

  environment.etc."systemd/system-sleep/fix-bluetooth-fprintd".source = pkgs.writeShellScript "fix-bluetooth-fprintd" ''
    set -eu

    # systemd-sleep runs hooks with a minimal PATH that does not include
    # coreutils, so every external command must be referenced by store path.
    sleep_bin="${pkgs.coreutils}/bin/sleep"
    timeout_bin="${pkgs.coreutils}/bin/timeout"
    systemctl_bin="${pkgs.systemd}/bin/systemctl"
    fprintd_verify_bin="${pkgs.fprintd}/bin/fprintd-verify"
    pkill_bin="${pkgs.procps}/bin/pkill"

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

    case "$1" in
      pre)
        "$systemctl_bin" stop fprintd.service || true
        "$systemctl_bin" stop bluetooth.service || true
        ;;
      post)
        # Drop any daemon carrying a stale claim from before the sleep
        # transition; a fresh one is warmed below.
        "$systemctl_bin" stop fprintd.service || true

        # Let the xHCI controller finish re-initialising before touching the
        # devices that hang off it.
        "$sleep_bin" 2

        bluetooth_usb_device="$(find_usb_device 8087 0026 || true)"
        fingerprint_usb_device="$(find_usb_device 06cb 00bd || true)"

        if [ -n "$fingerprint_usb_device" ]; then
          fingerprint_path="/sys/bus/usb/devices/$fingerprint_usb_device"

          # The controller reset on resume leaves the Synaptics reader in a
          # state where the first fprintd open can fail with protocol error
          # 789.  Deauthorising and reauthorising the device tears down and
          # reprobes its USB interfaces, which clears that state more
          # thoroughly than unbinding the generic usb driver.
          if [ -w "$fingerprint_path/authorized" ]; then
            if ! printf '0\n' > "$fingerprint_path/authorized"; then
              printf 'fix-bluetooth-fprintd: failed to deauthorize %s\n' "$fingerprint_usb_device" >&2
            fi
            "$sleep_bin" 1

            if ! printf '1\n' > "$fingerprint_path/authorized"; then
              printf 'fix-bluetooth-fprintd: failed to reauthorize %s\n' "$fingerprint_usb_device" >&2
            fi
            "$sleep_bin" 1
          fi
        fi

        [ -n "$bluetooth_usb_device" ] && set_usb_power_policy "$bluetooth_usb_device"
        [ -n "$fingerprint_usb_device" ] && set_usb_power_policy "$fingerprint_usb_device"

        # The first libfprint open after the resume reset can fail with
        # protocol error 789 even after re-enumeration; the next open works.
        # Absorb that failing open here, retrying until the reader
        # initialises, so the lock screen's first attempt is already a warm
        # open.  If warm-up succeeds, keep fprintd running so the greeter's
        # fresh PAM conversation connects to the warmed daemon; otherwise
        # stop it and let D-Bus activation retry on demand.
        if [ -n "$fingerprint_usb_device" ]; then
          # patrick has the enrolled fingerprint; only the reader needs to be
          # initialised, not a successful match.
          warmup_user="patrick"
          warmup_attempt=0
          warmup_ready=0

          while [ "$warmup_attempt" -lt 4 ]; do
            "$systemctl_bin" stop fprintd.service >/dev/null 2>&1 || true
            warmup_output="$("$timeout_bin" 2 "$fprintd_verify_bin" "$warmup_user" 2>&1 || true)"

            case "$warmup_output" in
              *"Verify started!"*)
                warmup_ready=1
                break
                ;;
            esac

            warmup_attempt=$((warmup_attempt + 1))
            "$sleep_bin" 1
          done

          # Keep the warmed daemon running for the lock screen.  Stopping it
          # here makes the lock screen's already-started PAM conversation see
          # the D-Bus name owner change, which breaks its first attempt.
          if [ "$warmup_ready" -eq 0 ]; then
            "$systemctl_bin" stop fprintd.service >/dev/null 2>&1 || true
            printf 'fix-bluetooth-fprintd: fingerprint warm-up failed after %s attempts\n' "$warmup_attempt" >&2
          fi

          # KDE's pre-sleep greeter keeps a PAM conversation tied to the old
          # fprintd D-Bus name owner.  Restart it so the post-resume prompt
          # establishes a fresh conversation against the warmed daemon
          # instead of aborting with "name owner changed".
          "$pkill_bin" -KILL -f '^/[^ ]*/libexec/kscreenlocker_greet( |$)' >/dev/null 2>&1 || true
        fi

        "$systemctl_bin" reset-failed bluetooth.service fprintd.service 2>/dev/null || true
        "$systemctl_bin" start bluetooth.service || true
        # fprintd is either already running from the warm-up above or will be
        # D-Bus activated by the lock screen; do not start it explicitly here.
        ;;
    esac
  '';

  security.tpm2 = {
    enable = true;
    pkcs11.enable = true;
    tctiEnvironment.enable = true;
  };

  boot.initrd.systemd.enable = true;

  systemd.settings.Manager = {
    DefaultTimeoutStopSec = "10s";
    RuntimeWatchdogSec = "0";
    RebootWatchdogSec = "10min";
  };

  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableUserSlices = true;
  };

  services.xserver = {
    enable = true;
    videoDrivers = [ "modesetting" ];

    xkb = {
      layout = "us";
      variant = "";
    };
  };

  services.displayManager.sddm = {
    enable = true;
    autoNumlock = true;
    # Run the greeter on Wayland to match the Plasma Wayland session. On 26.05
    # a Wayland session started under an X11 greeter can hang after login
    # (wallpaper shows, plasmashell never finishes). Aligning both avoids that.
    wayland.enable = true;
  };

  # Pin the Plasma Wayland session explicitly ("plasma" is the Wayland session
  # on 26.05); plasmax11 stays selectable in SDDM as a manual fallback if a
  # boot hangs.
  services.displayManager.defaultSession = "plasma";

  # Auto-unlock KWallet with the login password so it can't block session
  # startup with a prompt (a known Plasma-6 post-login hang cause).
  security.pam.services.sddm.kwallet.enable = true;

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

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  services.printing = {
    enable = true;
    browsing = true;
  };

  # Canon imageCLASS MF650C Series (192.168.20.40, guest network). The printer advertises
  # AirPrint 2.1 / IPP Everywhere, so the queue is expressed driverless
  # (`model = everywhere`) and no vendor UFR II driver is installed.
  hardware.printers = {
    ensurePrinters = [
      {
        name = "Canon_MF650C";
        location = "Home";
        description = "Canon imageCLASS MF650C Series";
        deviceUri = "ipp://192.168.20.40/ipp/print";
        model = "everywhere";
      }
    ];
    ensureDefaultPrinter = "Canon_MF650C";
  };

  # Queue creation queries the printer over IPP. Murdock reaches the printer
  # directly on the home LAN but through an accepted tailnet subnet route
  # elsewhere, and that route is only installed once the autoconnect unit has
  # brought the node up, so order after it.
  systemd.services.ensure-printers = {
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
      "tailscaled-autoconnect.service"
    ];
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
    # T15 Gen 2 fingerprint sensor — verify vendor/product with `lsusb` after install
  };

  environment.systemPackages = with pkgs; [
    (ansible.overridePythonAttrs (old: {
      propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [
        python3Packages.docker
      ];
    }))
    terraform
    sshpass
    vlc
    jq
    numlockx

    # ThinkPad tools
    lm_sensors
    powertop
    acpi
    tpm2-tools
    throttled

    # Hibernation tools
    pmutils

    # Intel GPU tools
    intel-gpu-tools
    libva-utils

    android-studio
    android-tools

    # 3D printing
    orca-slicer
    (pkgs-elegoo-compat.callPackage ../../packages/elegoo-slicer.nix {})
  ];

  fonts.packages = with pkgs; [
    source-han-sans
    noto-fonts
  ];

  environment.variables = {
    LIBVA_DRIVER_NAME = "iHD";
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

  system.stateVersion = "25.11";
}
