{ lib, buildNpmPackage, fetchurl }:
buildNpmPackage rec {
  pname = "opencode-claude";
  version = "1.3.7";
  src = fetchurl {
    url = "https://registry.npmjs.org/@openchamber/opencode-claude/-/opencode-claude-${version}.tgz";
    hash = "sha512-3MpuKr+1mm+k6YkwFsge3n/SH4P7zi2SrEsu5lRaXQwVfM3PR3fLEKDK15jr/EiowN26cJrdLARx5sDCbD0X7g==";
  };
  npmDepsHash = "sha256-Dy1/Q+RMbjwcGLydrJ/pCR8ZKxxkgqzCe1IZYJL3CN8=";
  postPatch = ''
    cp ${./opencode-claude-package-lock.json} package-lock.json
  '';
  dontNpmBuild = true;
  postInstall = ''
    ln -s opencode-claude.js "$out/lib/node_modules/@openchamber/opencode-claude/index.js"
  '';
  meta = {
    description = "OpenChamber Claude Code integration for OpenCode";
    homepage = "https://github.com/openchamber/opencode-claude";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
