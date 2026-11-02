{ lib, writeShellApplication, python3, opencode-api }:

# Tier dispatcher: resolves a work tier to a model from the routing roster.
#
# The roster is two layers. The base inventory lives in ./routing/models and the
# host installs it read-only at /etc/hermes/routing/models through its own
# environment.etc entry - this package does not carry it, and the two are
# independent artifacts. A local overlay at ~/.hermes/routing/models adds
# candidates and replaces base entries by id, so a route that dies between
# rebuilds is a file edit rather than a pull request.
#
# The wrapper lives here rather than in ~/.hermes/scripts so that changing how a
# session is created - the announcement, the deny-list, the quota pre-flight -
# needs a reviewed change, for the same reason opencode-api is packaged here.
writeShellApplication {
  name = "oc-tier";
  text = ''
    # Pin the API helper to this build of the package rather than whatever is on
    # PATH, so a wrapper from a newer generation cannot drift onto an older binary.
    export OC_TIER_API="${opencode-api}/bin/opencode-api"
    exec ${python3}/bin/python3 ${./oc-tier.py} "$@"
  '';
  meta = {
    description = "Resolve a work tier to a model from the routing roster";
    mainProgram = "oc-tier";
    platforms = lib.platforms.linux;
  };
}
