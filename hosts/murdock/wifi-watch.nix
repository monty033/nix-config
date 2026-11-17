# Keeps the wifi profile in step with the user who is in front.
#
# Both networks broadcast the same SSID, and NetworkManager will not move off
# the profile it is already associated with, so something has to re-point the
# interface when the foreground user changes. Doing that from a login unit is
# not enough: switching to an *already running* session (Plasma "Switch User"
# -> pick the existing session) starts no new session unit, and a resume
# restores whichever profile NetworkManager prefers.
#
# So watch the two things that actually change instead: logind's active session
# on the seat, and the state of the wifi device. On either signal re-assert the
# profile that belongs to the user currently in front.
{ pkgs }:

let
  switchScript = import ./wifi-switch.nix { inherit pkgs; };
in
pkgs.writeShellScript "monty-wifi-watch" ''
  set -u
  export PATH=${
    pkgs.lib.makeBinPath [
      pkgs.systemd
      pkgs.dbus
      pkgs.coreutils
      pkgs.util-linux
    ]
  }

  switch=${switchScript}

  # "lan" or "guest". Only patrick gets the LAN; lina, the sddm greeter and
  # anything else that can hold the seat get the guest network, so the machine
  # never sits on the LAN after patrick's session ends. A failed lookup returns
  # non-zero so the caller does nothing rather than guessing.
  desired() {
    local session user
    session=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null) || return 1
    [ -n "$session" ] || { echo guest; return 0; }
    user=$(loginctl show-session "$session" -p Name --value 2>/dev/null) || return 1
    case "$user" in
      patrick) echo lan ;;
      *) echo guest ;;
    esac
  }

  sync() {
    local want
    want=$(desired) || return 0
    [ -n "$want" ] || return 0
    "$switch" "$want" || true
  }

  # --profile makes dbus-monitor print exactly one line per message, and
  # stdbuf keeps those lines flowing instead of sitting in a stdio buffer.
  #
  # logind is matched on sender only: an active-session change shows up as
  # PropertiesChanged on either the Seat or the Session object, and which one
  # is an implementation detail we do not want to depend on. logind is quiet,
  # so the extra matches cost nothing.
  #
  # timeout is a safety net, not the mechanism: the monitor is torn down and
  # restarted every five minutes, and the restart re-asserts the profile. That
  # heals a missed signal without anyone having to log in again.
  while :; do
    sync
    started=$SECONDS
    stdbuf -oL timeout 300 dbus-monitor --profile --system \
      "type='signal',sender='org.freedesktop.login1'" \
      "type='signal',interface='org.freedesktop.NetworkManager.Device',member='StateChanged'" \
      | while IFS= read -r line; do
          # --profile prints one tab-separated line per message, tagged "sig".
          case "$line" in
            sig*) sync ;;
          esac
        done
    # The monitor is expected to be torn down every five minutes; only a
    # shorter life means it died (bus restart, NetworkManager reload). Either
    # way the loop head re-syncs and starts a new one.
    if [ $((SECONDS - started)) -lt 290 ]; then
      logger -t monty-wifi-watch "wifi event monitor exited early; restarting" || true
    fi
    sleep 2
  done
''
