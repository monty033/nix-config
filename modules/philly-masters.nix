{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.extra-services.philly-masters;
  app = pkgs.callPackage ../packages/philly-masters.nix { inherit inputs; };
  stateDir = "/var/lib/philly-masters";
  # The signing secret is generated here rather than declared, because nobody
  # needs to know it: it keys sessions, so a fresh one costs only a re-login. It
  # lives in the state directory, which survives reinstalls and is not in the
  # store — a secret in the Nix store is a secret in every build log and every
  # cache upload, and sops would mean an operator handling a value that exists
  # only to be random.
  secretFile = "${stateDir}/auth-secret.env";

  # The launcher owns the secret, so the first start is the same path as every
  # later start. An ExecStartPre that creates the file while `EnvironmentFile`
  # has already been read means the first boot has no AUTH_SECRET and dies into
  # a restart — worked around by an accident of timing rather than by design.
  #
  # The secret is written once and left alone: regenerating it invalidates every
  # live session.
  launcher = pkgs.writeShellScript "philly-masters-run" ''
    set -eu
    # Generated only when the file is absent. A file that exists and carries no
    # secret is a fault — truncated by a full disk, or written by hand — and
    # regenerating it would silently log every session out and hide the fault.
    if [ ! -e ${secretFile} ]; then
      umask 077
      secret=$(${pkgs.coreutils}/bin/head -c 48 /dev/urandom | ${pkgs.coreutils}/bin/base64 -w0)
      printf 'AUTH_SECRET=%s\n' "$secret" > ${secretFile}.new
      ${pkgs.coreutils}/bin/mv ${secretFile}.new ${secretFile}
    fi
    # Parsed, not sourced: an environment file is data, and a shell would run
    # whatever a corrupted line contained.
    AUTH_SECRET=$(${pkgs.gnused}/bin/sed -n 's/^AUTH_SECRET=//p' ${secretFile})
    if [ -z "$AUTH_SECRET" ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' \
        "philly-masters: ${secretFile} exists but has no AUTH_SECRET; refusing to start rather than rotating the signing key" >&2
      exit 78
    fi
    export AUTH_SECRET
    ${cfg.package}/bin/philly-masters-pool
  '';
in
{
  options.extra-services.philly-masters = {
    enable = lib.mkEnableOption "the Philly Masters Pool application";

    package = lib.mkOption {
      type = lib.types.package;
      default = app;
      defaultText = lib.literalExpression "pkgs.callPackage ../packages/philly-masters.nix { inherit inputs; }";
      description = "The application package the service runs.";
    };

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        The address the server listens on. The default is loopback: no peer
        elsewhere on the network can connect to this port, and public traffic
        reaches the server only through the reverse proxy on this host.

        That closes remote forgery of the X-Forwarded-For header the rate limits
        are keyed on. It does not close host-local access — a process running on
        this machine can connect to the port and write its own header, which is
        the trust every service on the host already extends to the others. It is
        also not a socket: setting this to a path configures nothing, because the
        adapter binds a TCP address.

        Nothing else in the module narrows the field: the server has no way to
        tell a proxied request from a host-local one, so the header it trusts is
        exactly as trustworthy as the host.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3440;
      description = "Port the application listens on. The reverse proxy on the same host uses it.";
    };

    publicOrigin = lib.mkOption {
      type = lib.types.str;
      default = "https://phillymasters.montycasa.com";
      description = ''
        The browser-facing origin. Two things depend on it: link and form targets
        SvelteKit builds, and the origin check that refuses cross-site form posts.
        It must match the hostname Caddy serves, or every POST is refused.
      '';
    };

    adminEmails = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "demo-one@example.com" "demo-two@example.com" ];
      description = ''
        The two administrator addresses. The application refuses to start with
        any other number, because the pool's operating model is two people who
        can both do everything. Administration is configuration only: an address
        here is an administrator, and no membership row can grant it.

        The defaults are placeholders for the demo. The demo page is public and
        needs no account, so nothing is lost until real addresses replace them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.adminEmails == 2;
        message = "extra-services.philly-masters.adminEmails must hold exactly two addresses";
      }
    ];

    users.groups.philly-masters = { };
    users.users.philly-masters = {
      isSystemUser = true;
      group = "philly-masters";
      home = stateDir;
      description = "Philly Masters Pool application";
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 philly-masters philly-masters -"
    ];

    systemd.services.philly-masters = {
      description = "Philly Masters Pool";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOST = cfg.bindAddress;
        PORT = toString cfg.port;
        ORIGIN = cfg.publicOrigin;
        PUBLIC_ORIGIN = cfg.publicOrigin;
        # The address the rate limits are keyed on. One proxy deep: the Caddy on
        # this host terminates TLS and adds the client address. A process
        # already running on this host can forge the header; nothing else can.
        ADDRESS_HEADER = "X-Forwarded-For";
        XFF_DEPTH = "1";
        DATABASE_PATH = "${stateDir}/pool.sqlite";
        ADMIN_EMAILS = lib.concatStringsSep "," cfg.adminEmails;
        # The demo has no members to mail, and the outbox is not a silent
        # fallback: the application refuses to use it in production unless it is
        # asked for by name. Swap for EMAIL_PROVIDER=zeptomail, its API key and
        # sender when logins become real. Until then, no login email is sent.
        EMAIL_PROVIDER = "outbox";
        ALLOW_OUTBOX = "1";
      };

      serviceConfig = {
        ExecStart = launcher;
        User = "philly-masters";
        Group = "philly-masters";
        WorkingDirectory = stateDir;
        StateDirectory = "philly-masters";
        StateDirectoryMode = "0750";

        Restart = "always";
        RestartSec = 3;

        # A single-purpose server: it needs its state directory, the network,
        # and nothing else on the host.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        # MemoryDenyWriteExecute is deliberately absent: V8 compiles JavaScript
        # to machine code at runtime, so the sandbox would kill the server on
        # the first request.
      };
    };

  };
}
