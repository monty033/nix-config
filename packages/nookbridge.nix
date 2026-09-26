{ lib
, buildNpmPackage
, gnumake
, makeWrapper
, nodejs_22
, openssl
, pkg-config
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

  npmDepsHash = "sha256-rJzPX6rnXgoCpKMbmigvEYw5xIh5bWdTebgsf2iMDEc=";
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
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    npm prune --omit=dev --no-save
    mkdir -p "$out/libexec/nookbridge"
    cp -r dist "$out/libexec/nookbridge/"
    cp -r node_modules "$out/libexec/nookbridge/"
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
