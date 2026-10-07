{ lib, writeShellApplication, curl, jq, coreutils, gnused }:

# Guardrailed helper for the OpenCode v2 server on Hermes. The free-model
# deny-list and the new-session guard live in the script so that changing
# them requires a reviewed PR. The server password is parsed from the
# sops-rendered file at runtime and never enters the store.
writeShellApplication {
  name = "opencode-api";
  runtimeInputs = [ curl jq coreutils gnused ];
  text = builtins.readFile ./opencode-api.sh;
  meta = {
    description = "Guardrailed OpenCode v2 API helper for Hermes";
    mainProgram = "opencode-api";
    platforms = lib.platforms.linux;
  };
}
