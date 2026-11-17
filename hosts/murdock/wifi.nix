# Per-user network access for murdock.
#
# The two networks share the SSID "MontyWifi" and are told apart only by the
# PSK the client presents; the AP places the client on the LAN or the guest
# VLAN accordingly. NetworkManager cannot infer that, and it will not switch
# profiles for an SSID it is already associated with -- which is why the link
# used to stay on the previous user's network until hibernate tore it down.
# Hence one profile per network, plus monty-wifi-watch, which re-points the
# interface whenever a different user comes to the front (see wifi-watch.nix).
#
# Both PSKs are stored in the root-only profile files, not in a KWallet: a
# wallet only exists inside one unlocked user session, while the wifi link is
# system-wide and must work before anyone logs in / for the other account.
# The guest profile is unrestricted so the machine has network before login
# and for anything that runs outside a session; the LAN profile is restricted
# to patrick and hidden from everyone else.
#
# To change a key: update the sops secrets below and rebuild.
{ config, pkgs, ... }:

let
  # Root-only helper shared with the watcher (see wifi-switch.nix). A switch
  # replaces the private connection owned by the other user, which
  # NetworkManager only allows for root.
  switchScript = import ./wifi-switch.nix { inherit pkgs; };
  watchScript = import ./wifi-watch.nix { inherit pkgs; };
in
{
  sops.secrets."wifi-monty-lan-psk" = { };
  sops.secrets."wifi-monty-guest-psk" = { };

  sops.templates."networkmanager-wifi.env" = {
    content = ''
      MONTY_LAN_PSK=${config.sops.placeholder."wifi-monty-lan-psk"}
      MONTY_GUEST_PSK=${config.sops.placeholder."wifi-monty-guest-psk"}
    '';
    mode = "0400";
    owner = "root";
    group = "root";
    # Re-render the profiles when either PSK is rotated.
    restartUnits = [ "NetworkManager-ensure-profiles.service" ];
  };

  # ensure-profiles expands the placeholders in the keyfile with envsubst, so
  # it needs the rendered environment and must run after the secrets exist.
  systemd.services.NetworkManager-ensure-profiles = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    # sops-nix re-runs restartUnits with `systemctl try-restart`, which only
    # touches a unit that is still active. A plain oneshot has already
    # finished, so without this a rotated PSK would sit unapplied in /run
    # until the next boot.
    serviceConfig.RemainAfterExit = true;
  };

  # The switch must run as root: it replaces the other user's private
  # connection, which NetworkManager refuses for a non-root caller ("Private
  # connection already active on the device", nm-manager.c). One system
  # service does it for everybody, so no user needs network privileges.
  systemd.services.monty-wifi-watch = {
    description = "Keep the MontyWifi profile in step with the foreground user";
    wantedBy = [ "multi-user.target" ];
    wants = [ "NetworkManager.service" ];
    after = [ "NetworkManager.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = watchScript;
      Restart = "always";
      RestartSec = 2;
    };
    # Load-bearing: if systemd hit its default 5-starts-in-10s limit the wifi
    # would silently stop following the user, so never give up on it.
    unitConfig.StartLimitIntervalSec = 0;
  };

  networking.networkmanager.ensureProfiles = {
    environmentFiles = [ config.sops.templates."networkmanager-wifi.env".path ];

    profiles = {
      # LAN (192.168.86.0/24): patrick only.
      "monty-lan" = {
        connection = {
          id = "MontyWifi LAN";
          uuid = "82dae82c-9aa7-4852-9df8-e4712df3a958";
          type = "wifi";
          autoconnect = true;
          autoconnect-priority = 10;
          permissions = "user:patrick:;";
        };
        wifi = {
          mode = "infrastructure";
          ssid = "MontyWifi";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$MONTY_LAN_PSK";
        };
        ipv4.method = "auto";
        ipv6 = {
          method = "auto";
          addr-gen-mode = "stable-privacy";
        };
      };

      # Guest (192.168.20.0/24): usable by everyone, so the machine has
      # network before login and whenever no user session is in front. Reuses
      # the UUID of the profile the applet created (the one currently active),
      # so replacing the live connection does not leave two competing profiles
      # for the same SSID.
      "monty-guest" = {
        connection = {
          id = "MontyWifi Guest";
          uuid = "28a0be7e-f975-427e-972f-545d989134d0";
          type = "wifi";
          autoconnect = true;
          permissions = "";
        };
        wifi = {
          mode = "infrastructure";
          ssid = "MontyWifi";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$MONTY_GUEST_PSK";
        };
        ipv4.method = "auto";
        ipv6 = {
          method = "auto";
          addr-gen-mode = "stable-privacy";
        };
      };
    };
  };
}
