# Disk Configuration for ThinkPad P53s
# 1TB NVMe with LUKS encryption, TPM2 auto-unlock, btrfs, and hibernation

{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1";  # Adjust if your disk is different (check with lsblk)
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              priority = 1;
              name = "ESP";
              size = "1G";  # Larger for multiple kernel versions
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                  "umask=0077"
                ];
              };
            };

            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";

                settings = {
                  # Allow TRIM for SSD performance
                  allowDiscards = true;

                  # Performance optimization
                  bypassWorkqueues = true;
                };

                extraOpenArgs = [
                  "--allow-discards"
                  "--perf-no_read_workqueue"
                  "--perf-no_write_workqueue"
                ];

                # Password will be prompted during installation
                # TPM2 enrollment happens after first boot

                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" "-L" "nixos" ];

                  subvolumes = {
                    "/root" = {
                      mountpoint = "/";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                        "space_cache=v2"
                      ];
                    };

                    "/home" = {
                      mountpoint = "/home";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                        "space_cache=v2"
                      ];
                    };

                    "/nix" = {
                      mountpoint = "/nix";
                      mountOptions = [
                        "compress=zstd:1"  # Light compression for Nix store (saves 20-30% with minimal CPU cost)
                        "noatime"
                        "space_cache=v2"
                      ];
                    };

                    "/log" = {
                      mountpoint = "/var/log";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                        "space_cache=v2"
                      ];
                    };

                    # Swap subvolume for hibernation
                    # 32GB = RAM size for P53s
                    "/swap" = {
                      mountpoint = "/swap";
                      mountOptions = [ "noatime" ];
                      swap = {
                        swapfile = {
                          size = "32G";  # Match your 32GB RAM
                        };
                      };
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  boot.initrd.luks.devices."cryptroot" = {
    # Device will be set automatically by disko

    # Performance settings
    allowDiscards = true;
    bypassWorkqueues = true;

    # TPM2 unlock configuration
    # This will be enrolled after first boot with:
    # sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p2
    # Note: fallbackToPassword is automatically enabled in systemd stage 1
    crypttabExtraOpts = [
      "tpm2-device=auto"
      "tpm2-pcrs=0+7"
    ];
  };

  # =============================
  # Hibernation Configuration
  # =============================
  # After installation, you'll need to:
  # 1. Find the swap file offset:
  #    sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
  # 2. Add to boot.kernelParams:
  #    "resume_offset=<offset_value>"
  # 3. Set boot.resumeDevice (done in main config)

  # Enable swap
  swapDevices = [ ];  # Managed by disko
}