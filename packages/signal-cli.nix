{ lib, stdenv, fetchurl, makeWrapper, jre_headless }:

# signal-cli ships a ready-to-run distribution: shell entry point plus jars. The
# packaged build in nixpkgs lags upstream, and Signal's servers refuse to link —
# and refuse to open an account store written by — a client that old, so this
# takes the upstream release and wraps it with a JRE on PATH.
stdenv.mkDerivation rec {
  pname = "signal-cli";
  version = "0.14.10";

  src = fetchurl {
    url = "https://github.com/AsamK/signal-cli/releases/download/v${version}/signal-cli-${version}.tar.gz";
    hash = "sha256-cGpX2fqudSXPcyk279q/IQFG48g/norn5OYvWUYSHDM=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/signal-cli $out/bin
    cp -r . $out/share/signal-cli
    # JAVA_HOME wins over PATH in the upstream start script, so setting only a
    # PATH prefix leaves a stale JAVA_HOME able to select an incompatible
    # runtime and fail at startup with UnsupportedClassVersionError.
    makeWrapper $out/share/signal-cli/bin/signal-cli $out/bin/signal-cli \
      --prefix PATH : ${lib.makeBinPath [ jre_headless ]} \
      --set JAVA_HOME ${jre_headless}
    runHook postInstall
  '';

  meta = {
    description = "Signal messenger CLI and JSON-RPC daemon";
    homepage = "https://github.com/AsamK/signal-cli";
    license = lib.licenses.gpl3Only;
    mainProgram = "signal-cli";
    # The release bundles a native libsignal-client library, so the platform set
    # is narrower than "linux" and the provenance is not bytecode alone.
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryBytecode lib.sourceTypes.binaryNativeCode ];
  };
}
