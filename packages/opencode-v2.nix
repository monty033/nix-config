{ lib
, stdenv
, stdenvNoCC
, fetchurl
, autoPatchelfHook
, zlib
}:

stdenvNoCC.mkDerivation rec {
  pname = "opencode-v2";
  version = "2.0.23";

  # Official upstream standalone release artifact (Linux x64, glibc).
  src = fetchurl {
    url = "https://opencode.ai/files/bin/${version}/opencode-linux-x64.tar.gz";
    hash = "sha256-E9HUX8HSBdv8i8maB7WfMNHhkjdbdRMWIO8wzH7dD38=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib zlib ];

  # OpenCode is a Bun single-file executable: the application is appended to
  # the binary, and strip discards it, leaving a bare Bun runtime.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 opencode $out/bin/opencode
    runHook postInstall
  '';

  meta = {
    description = "OpenCode v2 CLI and server (official standalone release)";
    homepage = "https://opencode.ai/";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "opencode";
  };
}
