# Root-only helper for monty-wifi-watch.
#
# Kept in its own file so the NixOS module and the watcher module reference the
# same store path. A switch means replacing the private connection owned by the
# other user, which NetworkManager only permits for root.
{ pkgs }:

pkgs.writeShellScript "monty-wifi-switch" ''
  set -eu
  nmcli=${pkgs.networkmanager}/bin/nmcli
  logger=${pkgs.util-linux}/bin/logger

  case "''${1:-}" in
    lan) want="MontyWifi LAN" ;;
    guest) want="MontyWifi Guest" ;;
    *) echo "usage: $0 lan|guest" >&2; exit 2 ;;
  esac

  cur=$("$nmcli" -t -g GENERAL.CONNECTION device show wlp0s20f3 2>/dev/null || true)
  [ "$cur" = "$want" ] && exit 0

  # Only take the interface over from one of our own profiles, or from nothing.
  # A network the user deliberately joined elsewhere (cafe, hotel, phone
  # hotspot) must not be torn down every time a wifi signal fires.
  case "$cur" in
    "" | "--" | "MontyWifi LAN" | "MontyWifi Guest") ;;
    *) exit 0 ;;
  esac

  if ! "$nmcli" connection up "$want" >/dev/null 2>&1; then
    "$logger" -t monty-wifi-switch "could not activate $want (was ''${cur:-disconnected})" || true
    exit 1
  fi
''
