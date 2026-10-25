{ lib
, buildNpmPackage
, gnumake
, makeWrapper
, nodejs_22
, openssl
, pkg-config
, stdenv
, glibc
, binutils
, python3
, inputs
, zlib
}:

buildNpmPackage rec {
  pname = "nookbridge";
  version = "0.0.0-stage.0";

  # The source input is pinned in flake.lock to the merged NookBridge source
  # tree. Build against this host's pinned nixpkgs rather than using
  # NookBridge's development flake as a second package universe.
  src = inputs.nookbridge;
  nodejs = nodejs_22;

  npmDepsHash = "sha256-BtaHuNOkEVYKPBhNC1ki9gvxDejYbHwGg1mXVCnizhs=";
  npmRebuildFlags = [ "--ignore-scripts" ];

  preBuild = ''
    substituteInPlace node_modules/better-sqlite3-multiple-ciphers/src/better_sqlite3.hpp \
      --replace-fail '#include <sqlite3.h>' '#include "../deps/sqlite3/sqlite3.h"'
    npm rebuild better-sqlite3-multiple-ciphers --build-from-source
  '';

  nativeBuildInputs = [
    gnumake
    makeWrapper
    nodejs_22
    pkg-config
    python3
  ];

  buildInputs = [
    openssl.dev
    zlib.dev
  ];

  # Use an explicit build phase because the install phase below copies the
  # generated dist tree and must never rely on an implicit hook ordering.
  dontNpmBuild = true;
  buildPhase = ''
    runHook preBuild
    npm run build

    # The operator socket resolves peer credentials by exec'ing
    # `<dist>/../../operator-peercred-helper` (see
    # src/service/peer-credentials.ts). That binary must be fully static:
    # glibc NSS, locale, and gconv data paths would otherwise point into the
    # build host's /nix/store and be invalid on the target. Mirrors the
    # compile line in .forgejo/workflows/linux-artifact.yml.
    ${stdenv.cc}/bin/cc \
      -O2 -std=c11 -Wall -Wextra -Werror -ffreestanding -fno-builtin \
      -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables \
      -fno-pie -no-pie -nostdlib -static -Wl,-e,_start -Wl,--build-id=none \
      -L${glibc.static}/lib \
      -o operator-peercred-helper native/operator-peercred.c

    if ${binutils}/bin/readelf -l operator-peercred-helper \
         | grep -E 'INTERP' >/dev/null; then
      echo "operator-peercred-helper is dynamically linked" >&2
      exit 1
    fi
    if ${binutils}/bin/strings operator-peercred-helper \
         | grep -E '/nix/store/[[:alnum:]]|(^|[[:space:]])/build/|/tmp/nookbridge/|libnss_|gconv-modules|/usr/lib/locale|/etc/localtime' >/dev/null; then
      echo "operator-peercred-helper contains a host or NSS/locale path" >&2
      exit 1
    fi

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    npm prune --omit=dev --no-save
    mkdir -p "$out/libexec/nookbridge"
    cp -r dist "$out/libexec/nookbridge/"
    cp -r node_modules "$out/libexec/nookbridge/"
    install -Dm755 operator-peercred-helper \
      "$out/libexec/nookbridge/operator-peercred-helper"
    install -Dm644 package.json "$out/libexec/nookbridge/package.json"
    install -Dm644 LICENSE "$out/share/licenses/nookbridge/LICENSE"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookd" \
      --add-flags "$out/libexec/nookbridge/dist/nookd.js"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/nook-mcp" \
      --add-flags "$out/libexec/nookbridge/dist/mcp/cli.js"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookbridge-provision-cli" \
      --add-flags "$out/libexec/nookbridge/dist/provision.js"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookbridge-sync-cli" \
      --add-flags "$out/libexec/nookbridge/dist/sync.js"

    # Do NOT install the bare `nookbridge-provision` / `nookbridge-sync` names
    # here. modules/nookbridge.nix owns those names as privileged wrappers that
    # enforce a root check, then re-exec through systemd-run with the service
    # user/group, credentials and sandboxing. Shipping the same names from the
    # package shadows them in the system path and silently bypasses all of that.

    # Parity with the release artifact builder
    # (scripts/build-linux-artifact.sh:235-236): the categorical liveness and
    # runtime-check entrypoints ship as their own wrappers.
    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookbridge-health" \
      --add-flags "$out/libexec/nookbridge/dist/health.js"

    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookbridge-runtime-check" \
      --add-flags "$out/libexec/nookbridge/dist/runtime-check.js"

    # `nookctl` is the admin-only operator CLI. Stage 8 packages it
    # alongside the service binaries so the structural check and the
    # NixOS VM isolation test can exercise the `doctor` subcommand
    # against a real on-host wrapper without touching source.
    makeWrapper ${nodejs_22}/bin/node "$out/bin/nookctl" \
      --set NOOKBRIDGE_SERVICE_CONFIG /etc/nookbridge/service.json \
      --set NOOKBRIDGE_SETTINGS_PATH /etc/nookbridge/settings.json \
      --add-flags "$out/libexec/nookbridge/dist/cli.js"

    runHook postInstall
  '';

  meta = {
    description = "NookBridge Notesnook read-write Unix-socket service with settings-gated delete";
    homepage = "https://git.montycasa.net/patrick/NookBridge";
    license = lib.licenses.gpl3Plus;
    mainProgram = "nookd";
    platforms = lib.platforms.linux;
  };
}
