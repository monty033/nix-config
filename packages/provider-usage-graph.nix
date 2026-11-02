{
  lib,
  writeShellApplication,
  python3,
}:

# Renders the provider-quota history chart for the /myusage quick command.
# The script and matplotlib are both inputs of this derivation, so a call runs
# no nix evaluation and downloads nothing: the previous wrapper shelled out to
# nix-shell against a pinned nixpkgs source path that no longer exists, which
# turned every invocation into an instantiate-and-fetch of the Python closure.
writeShellApplication {
  name = "provider-usage-graph";
  runtimeInputs = [ (python3.withPackages (ps: [ ps.matplotlib ])) ];
  text = ''
    exec python3 ${./provider-usage-graph.py} "$@"
  '';
  meta = {
    description = "Render the provider quota usage history chart";
    mainProgram = "provider-usage-graph";
    platforms = lib.platforms.linux;
  };
}
