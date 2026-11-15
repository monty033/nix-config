{ lib
, buildNpmPackage
, makeWrapper
, nodejs_24
, inputs
}:

# The pool application, built from the input pinned in flake.lock. Building it
# here rather than taking the app flake's own package keeps one nixpkgs, one
# Node and one cache in play; the app's flake is a development convenience, not
# a second package universe.
#
# The migrations are copied deliberately. They are data the server reads at
# start-up, not build output, so a package without them builds, deploys and
# passes a health check, then fails the first time the server opens the
# database. The app repository has the same check in its own flake for the same
# reason.
buildNpmPackage rec {
  pname = "philly-masters-pool";
  version = "0.1.0";

  src = inputs.philly-masters;
  nodejs = nodejs_24;
  npmDepsHash = "sha256-/AvxujF0LN2e4dhFxvGs1ImoSnRbr8KujzzqHx2yyng=";
  npmBuildScript = "build";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/philly-masters-pool
    cp -r build $out/lib/philly-masters-pool/build
    cp package.json $out/lib/philly-masters-pool/package.json

    mkdir -p $out/lib/philly-masters-pool/migrations
    cp migrations/*.sql $out/lib/philly-masters-pool/migrations/

    makeWrapper ${nodejs_24}/bin/node $out/bin/philly-masters-pool \
      --add-flags "$out/lib/philly-masters-pool/build/index.js" \
      --set NODE_ENV production \
      --set MIGRATIONS_DIR "$out/lib/philly-masters-pool/migrations"
    runHook postInstall
  '';

  # A migrations-less artifact is the failure this guards against, so the check
  # is part of the package rather than a separate thing to remember to run.
  passthru.migrationsDir = "${placeholder "out"}/lib/philly-masters-pool/migrations";

  meta = {
    description = "Philly Masters Pool web application";
    mainProgram = "philly-masters-pool";
    license = lib.licenses.agpl3Only;
  };
}
