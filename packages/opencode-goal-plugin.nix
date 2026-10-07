{ lib, buildNpmPackage, fetchFromGitHub }:
buildNpmPackage rec {
  pname = "opencode-goal-plugin";
  version = "1.2.0";
  src = fetchFromGitHub {
    owner = "zignd";
    repo = "opencode-goal-plugin";
    rev = "3ba0c50e585f7c3d6202fc72984b73b72de03aea";
    hash = "sha256-JPBY8mTkPKboy6xgDl8VIxjL+NwGYY5SUX1sbUAPMDg=";
  };
  npmDepsHash = "sha256-hAEklmcLzPISXAfDIlsuvUvSnIJ8OncFSOGZdJhuZdw=";
  postPatch = ''
    cp ${./opencode-goal-package-lock.json} package-lock.json
  '';
  dontNpmBuild = true;
  postInstall = ''
    plugin="$out/lib/node_modules/opencode-goal-plugin"
    runtime="$out/share/opencode-goal-plugin"
    mkdir -p "$runtime"
    cp "$plugin/package.json" "$plugin/index.ts" "$plugin/tui.ts" "$plugin/tsconfig.json" "$runtime/"
    cp -r "$plugin/src" "$plugin/skills" "$runtime/"
    ln -s ../../lib/node_modules/opencode-goal-plugin/node_modules "$runtime/node_modules"
  '';
  meta = {
    description = "Persistent /goal command and TUI for OpenCode";
    homepage = "https://github.com/zignd/opencode-goal-plugin";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
