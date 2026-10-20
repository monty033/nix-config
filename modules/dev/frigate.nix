{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.extra-services.frigate;

  # Python environment with OpenVino and model optimizer
  openvinoEnv = pkgs.python3.withPackages (ps: with ps; [
    openvino
    tensorflow
    numpy
  ]);

  # Python script to convert the model using modern OpenVino API
  convertModelScript = pkgs.writeText "convert_ov_model.py" ''
    import openvino as ov
    import sys
    import os

    models_dir = sys.argv[1]
    output_dir = sys.argv[2]

    model_path = os.path.join(models_dir, "ssdlite_mobilenet_v2_coco_2018_05_09/frozen_inference_graph.pb")
    pipeline_config = os.path.join(models_dir, "ssdlite_mobilenet_v2_coco_2018_05_09/pipeline.config")

    print(f"Converting model from {model_path}")
    print(f"Output directory: {output_dir}")

    # Convert the model using modern OpenVino API
    try:
        ov_model = ov.convert_model(model_path)

        # Save the model (compress to FP16 if supported)
        output_path = os.path.join(output_dir, "ssdlite_mobilenet_v2.xml")
        try:
            ov.save_model(ov_model, output_path, compress_to_fp16=True)
        except TypeError:
            # compress_to_fp16 not supported in this version, save without compression
            ov.save_model(ov_model, output_path)
        print(f"Model saved to {output_path}")
    except Exception as e:
        print(f"Error converting model: {e}")
        print("This might be due to TensorFlow model format not being fully supported")
        print("Consider using a pre-converted OpenVino model or ONNX format")
        raise
  '';

  # OpenVino model download and conversion script
  # This matches the Frigate Dockerfile approach
  setupOpenVino = pkgs.writeShellScript "setup-openvino" ''
    set -e
    
    MODEL_CACHE_DIR="$1"
    DETECTOR_MODEL_DIR="$MODEL_CACHE_DIR/openvino-model"
    
    # Create directories if they don't exist
    mkdir -p "$DETECTOR_MODEL_DIR"
    
    # Check if model already exists
    if [ -f "$DETECTOR_MODEL_DIR/ssdlite_mobilenet_v2.xml" ] && \
       [ -f "$DETECTOR_MODEL_DIR/ssdlite_mobilenet_v2.bin" ]; then
      echo "OpenVino model already exists, skipping download"
      exit 0
    fi
    
    echo "Downloading and setting up OpenVino model..."
    
    # Create temporary working directory
    WORK_DIR=$(mktemp -d)
    cd "$WORK_DIR"
    
    # Download the TensorFlow model (same as Dockerfile)
    echo "Downloading TensorFlow model..."
    ${pkgs.wget}/bin/wget -q http://download.tensorflow.org/models/object_detection/ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz
    ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf ssdlite_mobilenet_v2_coco_2018_05_09.tar.gz
    
    # Convert the model using OpenVino's Python API (matches Dockerfile's build_ov_model.py)
    echo "Converting model with OpenVino..."
    ${openvinoEnv}/bin/python ${convertModelScript} "$WORK_DIR" "$DETECTOR_MODEL_DIR"
    
    # Download the labels file (same as Dockerfile)
    echo "Downloading labels..."
    ${pkgs.wget}/bin/wget -q https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt \
      -O "$DETECTOR_MODEL_DIR/coco_91cl_bkgr.txt"
    
    # Modify labels (replace 'truck' with 'car' - same as Dockerfile)
    ${pkgs.gnused}/bin/sed -i 's/truck/car/g' "$DETECTOR_MODEL_DIR/coco_91cl_bkgr.txt"
    
    # Clean up
    cd /
    rm -rf "$WORK_DIR"
    
    echo "OpenVino model setup complete"
    
    # Verify files exist
    if [ ! -f "$DETECTOR_MODEL_DIR/ssdlite_mobilenet_v2.xml" ] || \
       [ ! -f "$DETECTOR_MODEL_DIR/ssdlite_mobilenet_v2.bin" ]; then
      echo "Error: Model files not found after setup!"
      exit 1
    fi
    
    # Set proper permissions
    chown -R ${cfg.user}:${cfg.group} "$MODEL_CACHE_DIR"
    
    echo "Model files ready at: $DETECTOR_MODEL_DIR"
  '';

in {
  options.extra-services.frigate = {
    enable = mkEnableOption "Frigate NVR with OpenVino support";

    package = mkOption {
      type = types.package;
      default = pkgs.frigate;
      defaultText = literalExpression "pkgs.frigate";
      description = "The Frigate package to use.";
    };

    configFile = mkOption {
      type = types.path;
      description = ''
        Path to the Frigate configuration file.
        See https://docs.frigate.video/configuration/ for configuration options.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/frigate";
      description = "Directory where Frigate stores its data.";
    };

    mediaDir = mkOption {
      type = types.path;
      default = "/var/lib/frigate/media";
      description = "Directory where Frigate stores media files (recordings, clips, etc).";
    };

    modelCacheDir = mkOption {
      type = types.path;
      default = "/var/lib/frigate/model_cache";
      description = "Directory where Frigate caches downloaded models.";
    };

    setupOpenVino = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to automatically download and setup OpenVino models.";
    };

    user = mkOption {
      type = types.str;
      default = "frigate";
      description = "User account under which Frigate runs.";
    };

    group = mkOption {
      type = types.str;
      default = "frigate";
      description = "Group account under which Frigate runs.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [ ffmpeg-full ];
      description = "Extra packages to make available to Frigate.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Environment variables to set for Frigate.";
      example = literalExpression ''
        {
          FRIGATE_RTSP_PASSWORD = "secret";
        }
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing environment variables to set for Frigate.
        This is more secure than using the environment option for secrets
        as it keeps them out of the Nix store.

        The file should contain KEY=value pairs, one per line.
      '';
      example = "/run/secrets/frigate-env";
    };
  };

  config = mkIf cfg.enable {
    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      description = "Frigate NVR user";
      extraGroups = [ "video" "render" ]; # For hardware acceleration
    };

    users.groups.${cfg.group} = {};

    # Ensure directories exist with proper permissions
    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0755 ${cfg.user} ${cfg.group} -"
      "d '${cfg.mediaDir}' 0755 ${cfg.user} ${cfg.group} -"
      "d '${cfg.modelCacheDir}' 0755 ${cfg.user} ${cfg.group} -"
    ];

    # OpenVino model setup service (runs before frigate)
    systemd.services.frigate-openvino-setup = mkIf cfg.setupOpenVino {
      description = "Setup OpenVino models for Frigate";
      wantedBy = [ "frigate.service" ];
      before = [ "frigate.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root"; # Need root to create directories and set ownership
        ExecStart = "${setupOpenVino} ${cfg.modelCacheDir}";
      };
    };

    # Main Frigate service
    systemd.services.frigate = {
      description = "Frigate NVR";
      after = [ "network.target" ] ++ optional cfg.setupOpenVino "frigate-openvino-setup.service";
      wants = optional cfg.setupOpenVino "frigate-openvino-setup.service";
      wantedBy = [ "multi-user.target" ];

      environment = cfg.environment // {
        CONFIG_FILE = mkDefault "${cfg.configFile}";
        FRIGATE_MEDIA_DIR = cfg.mediaDir;
        FRIGATE_MODEL_CACHE_DIR = cfg.modelCacheDir;
        PYTHONPATH = cfg.package.pythonPath;
        PYTHONUNBUFFERED = "1";
      };

      path = cfg.extraPackages;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${cfg.package.python.interpreter} -m frigate";
        Restart = "on-failure";
        RestartSec = "5s";

        # Environment file for secrets
        EnvironmentFile = mkIf (cfg.environmentFile != null) cfg.environmentFile;

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir cfg.mediaDir cfg.modelCacheDir ];

        # Resource limits
        MemoryMax = "4G";
        TasksMax = 4096;

        # Device access for hardware acceleration
        DeviceAllow = [
          "/dev/dri rw"
          "/dev/video rw"
        ];
        SupplementaryGroups = [ "video" "render" ];
      };
    };

    # Open firewall for web interface (default port 5000)
    # Users can override this in their configuration
    networking.firewall.allowedTCPPorts = mkDefault [ 5000 ];
  };
}
