{ lib
, stdenvNoCC
, fetchurl
, autoPatchelfHook
, stdenv
}:

stdenvNoCC.mkDerivation rec {
  pname = "antigravity-cli";
  version = "1.5.14";

  # Google's own release artifact (Linux x64, glibc), fetched directly instead of
  # running the vendor install script, whose only step beyond downloading is
  # reading that manifest:
  #   https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json
  # That endpoint is unversioned and always serves the current release, and the
  # URL below carries TWO tokens from it: the version AND an opaque build id
  # (5302690847260672) that `version` does not determine. Bumping `version` alone
  # therefore cannot resolve — re-read the manifest and change both together. The
  # hash is a locally computed sha256 of the tarball; the manifest also publishes
  # a sha512 for the same file, so a bump's pin can be cross-checked against it.
  #
  # The tarball holds one file named `antigravity`; the vendor install script
  # installs that member as `agy` (read from the script, which was not run here).
  #
  # This is the successor to Gemini CLI for individuals: Gemini CLI stopped
  # serving Google AI Pro, AI Ultra and free-tier personal accounts on
  # 2026-06-18 (google-gemini/gemini-cli discussion #28017), so the nixpkgs
  # `gemini-cli` still installs but will not answer for a personal subscription.
  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-5302690847260672/linux-x64/cli_linux_x64.tar.gz";
    hash = "sha256-1YOGMi0gc+lrM/fMMrTpri22Io9YRANpcllnst5Ix7U=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # packages/opencode-v2.nix needs `dontStrip = true` because strip discards the
  # payload appended to that Bun single-file binary. This 261 MiB executable is
  # not the same case: a `dontStrip = false` build of the 1.5.14 artifact differs
  # by 4 KiB (273240152 vs 273244248 bytes) and still prints `1.5.14` and still
  # reaches the Google sign-in gate on a headless run. Stripping removed nothing
  # those two checks depend on, so the default is kept and there is no flag here.
  # Re-measure before copying the sibling's flag over.

  installPhase = ''
    runHook preInstall
    install -Dm755 antigravity $out/bin/agy
    runHook postInstall
  '';

  meta = {
    description = "Antigravity CLI (agy) — Google's terminal coding agent";
    homepage = "https://antigravity.google/docs/cli/overview";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "agy";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
