# Non-production Stage 9 recovery-CLI and server-boundary drill for NookBridge.
# This is NOT gate G2 evidence: the daemon below is a stub, the policy is
# chosen by this test, and the corrupted bundle is never recovered.
#
# Negative control: run the same imported test on a KVM-capable host with
# `enableCorruption = false` (for example, by changing only that argument in
# the check expression for a local run).  The run must fail at the corruption
# assertion, proving the corruption-inspection half of assertion 3 is live;
# do not add a second check.
#
# This is deliberately a self-contained test module.  Its root boot service
# creates three encrypted SQLite members and a systemd-shaped credential from
# VM-local randomness.  Its nookd service validates that generated bundle,
# creates a synthetic lock file at the path the recovery command checks (this
# is test code, not the shipped lock), and runs the real framed NookBridge
# server with a small in-memory runtime.  No account, network, production
# module, or live Notesnook state is involved.

{ pkgs, inputs, enableCorruption ? true }:

let
  nookbridge = pkgs.callPackage ../packages/nookbridge.nix {
    inherit inputs;
  };

  # Use the shipped storage wrapper so the fixture has real SQLCipher pages;
  # plain SQLite files would make a corruption/recovery check meaningless.
  fixtureBuilder = pkgs.writeText "nookbridge-recovery-fixture.mjs" ''
    import { mkdirSync, readFileSync } from "node:fs";
    import { join } from "node:path";
    import { SqliteStorage } from "${nookbridge}/libexec/nookbridge/dist/storage/sqlite-storage.js";

    const stateDir = process.argv[2];
    const credentialsDir = process.argv[3];
    const canaryPath = process.argv[4];
    const key = readFileSync(join(credentialsDir, "nookbridge-db-key"), "utf8").trim();
    const canary = readFileSync(canaryPath, "utf8").trim();
    mkdirSync(stateDir, { recursive: true, mode: 0o750 });

    for (const member of [
      "nookbridge-storage.db",
      "notesnook.db",
      "notesnook-logs.db",
    ]) {
      const storage = new SqliteStorage({
        dbPath: join(stateDir, member),
        key,
        withExtensions: false,
      });
      storage.exec("CREATE TABLE IF NOT EXISTS recovery_fixture(value TEXT NOT NULL)");
      storage.run("INSERT INTO recovery_fixture(value) VALUES(?)", [canary + ":" + member]);
      storage.close();
    }
  '';

  # This is the service process used by the VM only.  The database probe is
  # intentionally before lock creation, so a corrupt bundle cannot leave a
  # misleading lock or create replacement files during a failed start.
  nookdRuntime = pkgs.writeText "nookbridge-recovery-runtime.mjs" ''
    import { closeSync, existsSync, openSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
    import { join } from "node:path";
    import { SqliteStorage } from "${nookbridge}/libexec/nookbridge/dist/storage/sqlite-storage.js";
    import { startNookdServer } from "${nookbridge}/libexec/nookbridge/dist/service/nookd-server.js";
    import { createReadWriteNoDeleteServicePolicy } from "${nookbridge}/libexec/nookbridge/dist/service/service-policy.js";

    const stateDir = "/var/lib/nookbridge";
    const socketPath = "/run/nookbridge/nookbridge.sock";
    const lockPath = join(stateDir, "nookbridge.lock");
    const credentialPath = join(process.env.CREDENTIALS_DIRECTORY, "nookbridge-db-key");
    const key = readFileSync(credentialPath, "utf8").trim();
    const members = [
      "nookbridge-storage.db",
      "notesnook.db",
      "notesnook-logs.db",
    ];

    for (const member of members) {
      const dbPath = join(stateDir, member);
      if (!existsSync(dbPath)) process.exit(71);
      let storage;
      try {
        storage = new SqliteStorage({ dbPath, key, withExtensions: false });
        storage.get("SELECT count(*) AS count FROM sqlite_master");
      } catch {
        process.exit(72);
      } finally {
        try { storage?.close(); } catch { /* categorical startup failure */ }
      }
    }

    let lockFd = -1;
    try {
      lockFd = openSync(lockPath, "wx", 0o600);
      closeSync(lockFd);
    } catch {
      process.exit(73);
    }

    const policy = createReadWriteNoDeleteServicePolicy();
    writeFileSync("/run/nookbridge/effective-policy", policy.profile + "\n", { mode: 0o640 });
    let server;
    let stopping = false;
    const stop = async () => {
      if (stopping) return;
      stopping = true;
      try { await server?.shutdown(); } finally {
        try { unlinkSync(lockPath); } catch { /* already gone */ }
        process.exit(0);
      }
    };
    process.on("SIGTERM", () => { void stop(); });
    process.on("SIGINT", () => { void stop(); });
    try {
      const groupLine = readFileSync("/etc/group", "utf8")
        .split("\n")
        .find((line) => line.startsWith("nookbridge-clients:"));
      const groupId = Number(groupLine?.split(":")[2]);
      if (!Number.isSafeInteger(groupId)) throw new Error("group unavailable");
      server = await startNookdServer({
        socketPath,
        socketGroup: "nookbridge-clients",
        resolveGroupId: async () => groupId,
        policy,
        runtime: {
          search: async () => [],
          cleanup: async () => undefined,
        },
        installSignalHandlers: false,
      });
    } catch (error) {
      // Surface the reason in the journal; a silent restart loop would look
      // like a healthy daemon that simply never holds the lock.
      console.error("nookd start failed:", error);
      try { unlinkSync(lockPath); } catch { /* best effort */ }
      process.exit(74);
    }
    await new Promise(() => undefined);
  '';

  nookdExec = pkgs.writeShellScript "nookbridge-recovery-nookd" ''
    exec ${pkgs.nodejs_22}/bin/node ${nookdRuntime}
  '';

  fixtureService = pkgs.writeShellScript "nookbridge-recovery-fixture-service" ''
    set -eu
    state=/var/lib/nookbridge
    root=/run/nookbridge-recovery
    credentials="$root/credentials"
    clean="$root/clean"
    install -d -m 0750 -o nookbridge -g nookbridge "$state"
    install -d -m 0700 -o root -g root "$credentials" "$clean"
    key="$(${pkgs.coreutils}/bin/od -An -N32 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')"
    canary="nookbridge-canary-$RANDOM-$RANDOM-$(printf '%s' '${nookbridge}' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-16)"
    printf '%s\n' "$key" > "$credentials/nookbridge-db-key"
    printf '%s\n' "$canary" > "$root/canary"
    chmod 0400 "$credentials/nookbridge-db-key"
    chmod 0600 "$root/canary"
    ${pkgs.nodejs_22}/bin/node ${fixtureBuilder} "$state" "$credentials" "$root/canary"
    for member in nookbridge-storage.db notesnook.db notesnook-logs.db; do
      cp -- "$state/$member" "$clean/$member"
      chown nookbridge:nookbridge "$state/$member"
      chmod 0600 "$state/$member"
    done
    chmod 0750 "$state"
  '';

  fixtureKeyPath = "/run/nookbridge-recovery/credentials/nookbridge-db-key";
  fixtureState = "/var/lib/nookbridge";
  fixtureCanary = "/run/nookbridge-recovery/canary";
in
{
  name = "nookbridge-recovery";

  nodes.machine =
    { config, lib, pkgs, ... }:
    {
      environment.systemPackages = [ nookbridge ];

      users.groups.nookbridge = { };
      users.groups.nookbridge-clients = { };
      users.users.nookbridge = {
        isSystemUser = true;
        group = "nookbridge";
        home = fixtureState;
        createHome = false;
        shell = "${pkgs.shadow}/bin/nologin";
        extraGroups = [ "nookbridge-clients" ];
      };
      users.users.hermes = {
        isNormalUser = true;
        uid = 1111;
        group = "users";
        extraGroups = [ "nookbridge-clients" ];
      };
      users.users.outsider = {
        isNormalUser = true;
        uid = 2222;
        group = "users";
      };

      systemd.tmpfiles.rules = [
        "d ${fixtureState} 0750 nookbridge nookbridge - -"
        "d /run/nookbridge 0750 nookbridge nookbridge-clients - -"
      ];

      systemd.services.nookbridge-recovery-fixture = {
        description = "Generated NookBridge recovery fixture";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-tmpfiles-setup.service" ];
        before = [ "nookd.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = fixtureService;
        };
      };

      systemd.services.nookd = {
        description = "NookBridge recovery-drill daemon";
        wantedBy = [ "multi-user.target" ];
        after = [
          "nookbridge-recovery-fixture.service"
          "systemd-tmpfiles-setup.service"
        ];
        wants = [ "nookbridge-recovery-fixture.service" ];
        serviceConfig = {
          Type = "simple";
          User = "nookbridge";
          Group = "nookbridge-clients";
          WorkingDirectory = fixtureState;
          Environment = "HOME=${fixtureState}";
          ExecStart = nookdExec;
          LoadCredential = [ "nookbridge-db-key:${fixtureKeyPath}" ];
          StateDirectory = "nookbridge";
          StateDirectoryMode = "0750";
          RuntimeDirectory = "nookbridge";
          RuntimeDirectoryMode = "0750";
          UMask = "0007";
          ReadWritePaths = [ fixtureState "/run/nookbridge" ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictNamespaces = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          SystemCallArchitectures = "native";
          Restart = "no";
          TimeoutStopSec = "15s";
        };
      };
    };

  testScript =
    { ... }:
    let
      corruptionEnabled = if enableCorruption then "True" else "False";
    in
    ''
      import re
      import shlex

      STATE = ${builtins.toJSON fixtureState}
      CREDENTIALS = ${builtins.toJSON (builtins.dirOf fixtureKeyPath)}
      CANARY_PATH = ${builtins.toJSON fixtureCanary}
      MEMBERS = [
          "nookbridge-storage.db",
          "notesnook.db",
          "notesnook-logs.db",
      ]

      def recover(arguments):
          command = (
              "CREDENTIALS_DIRECTORY=" + shlex.quote(CREDENTIALS) + " "
              "NOOKBRIDGE_STATE_DIR=" + shlex.quote(STATE) + " "
              "/run/current-system/sw/bin/nookctl recover-local-state bundle "
              + arguments
              + " 2>&1"
          )
          return machine.execute(command)

      def hashes_for(root):
          return machine.succeed(
              "sha256sum " + " ".join(
                  shlex.quote(root + "/" + member) for member in MEMBERS
              )
              + " | cut -d' ' -f1"
          ).strip()

      def member_hashes():
          return hashes_for(STATE)

      def tree_snapshot():
          # Size alone cannot distinguish a move from a delete-and-recreate;
          # include inode, link count, mode, owner and content hash.
          listing = machine.succeed(
              "find " + shlex.quote(STATE)
              + " -mindepth 1 -maxdepth 3 -type f -printf '%P %s %m %u %g %i %n %C@\\n' | sort"
          ).strip()
          digests = machine.succeed(
              "find " + shlex.quote(STATE)
              + " -mindepth 1 -maxdepth 3 -type f -exec sha256sum {} + | sort"
          ).strip()
          return listing + "\n" + digests

      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("nookbridge-recovery-fixture.service")

      # `inspect` is an offline tool: it takes the state lock itself, so a
      # running daemon makes it report `locked` instead of reading the bundle.
      # Stop the daemon for the healthy read, then start it again for the
      # locked case below.
      machine.wait_for_unit("nookd.service")
      machine.wait_until_succeeds("test -S /run/nookbridge/nookbridge.sock", timeout=120)
      machine.succeed("systemctl stop nookd.service")
      machine.wait_until_succeeds("test \"$(systemctl is-active nookd.service)\" = inactive")

      with subtest("healthy generated bundle inspects healthy"):
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is healthy"), output

      with subtest("daemon is active"):
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")
          assert machine.succeed("systemctl is-active nookd.service").strip() == "active"
          # The stub daemon validates every bundle member before it takes the
          # lock, so systemd reports "active" several seconds before the lock
          # exists.
          try:
              machine.wait_until_succeeds(
                  "test -f " + shlex.quote(STATE + "/nookbridge.lock"), timeout=120
              )
          except Exception:
              raise AssertionError(
                  "daemon did not hold the lock\n--- state dir ---\n"
                  + machine.succeed("ls -la " + shlex.quote(STATE))
                  + "\n--- unit ---\n"
                  + machine.succeed("systemctl status nookd.service --no-pager -l || true")
                  + "\n--- journal ---\n"
                  + machine.succeed("journalctl -u nookd.service --no-pager -n 30 || true")
              )

      with subtest("running daemon makes inspect report locked without touching lock"):
          lock_before = machine.succeed(
              "stat -c '%i %s %a' " + shlex.quote(STATE + "/nookbridge.lock")
          ).strip()
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is currently locked"), output
          lock_after = machine.succeed(
              "stat -c '%i %s %a' " + shlex.quote(STATE + "/nookbridge.lock")
          ).strip()
          assert lock_after == lock_before, (lock_before, lock_after)

      with subtest("corruption is detected and failed start is byte-stable"):
          machine.succeed("systemctl stop nookd.service")
          machine.succeed("test ! -e " + shlex.quote(STATE + "/nookbridge.lock"))
          clean_names = machine.succeed(
              "find " + shlex.quote(STATE) + " -maxdepth 1 -type f -printf '%f\\n' | sort"
          ).strip()
          if ${corruptionEnabled}:
              # Damage page 1 (the SQLCipher header page). A later page can leave
              # a cheap validation query working, which lets the daemon start on
              # a bundle the offline inspect has already called corrupt.
              machine.succeed(
                  "dd if=/dev/zero bs=512 count=1 status=none | tr '\\000' '\\245' | "
                  + "dd of=" + shlex.quote(STATE + "/notesnook.db")
                  + " bs=512 seek=0 conv=notrunc status=none"
              )
          corrupt_hashes = member_hashes()
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is corrupt"), output
          # Type=simple means `systemctl start` returns before the process can
          # fail, so wait for the unit itself to reach the failed state.
          machine.succeed("systemctl start nookd.service || true")
          try:
              machine.wait_until_succeeds("systemctl is-failed nookd.service", timeout=180)
          except Exception:
              raise AssertionError(
                  "daemon did not fail on a corrupt bundle\n--- unit ---\n"
                  + machine.succeed("systemctl status nookd.service --no-pager -l || true")
                  + "\n--- journal ---\n"
                  + machine.succeed("journalctl -u nookd.service --no-pager -n 40 || true")
              )
          assert machine.succeed("systemctl is-failed nookd.service").strip() == "failed"
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is corrupt"), output
          assert member_hashes() == corrupt_hashes
          assert machine.succeed(
              "find " + shlex.quote(STATE) + " -maxdepth 1 -type f -printf '%f\\n' | sort"
          ).strip() == clean_names

      # The rest of the drill exercises reinitialize/rollback on the original
      # healthy generated fixture. Restore only after all corruption evidence
      # has been captured; this keeps the workflow in one throwaway state root.
      machine.succeed(
          "for member in nookbridge-storage.db notesnook.db notesnook-logs.db; do "
          + "cp -- " + shlex.quote("/run/nookbridge-recovery/clean/")
          + "$member " + shlex.quote(STATE + "/") + "$member; "
          + "chown nookbridge:nookbridge " + shlex.quote(STATE + "/") + "$member; "
          + "chmod 0600 " + shlex.quote(STATE + "/") + "$member; done"
      )
      machine.succeed("systemctl reset-failed nookd.service")
      machine.succeed("systemctl start nookd.service")
      machine.wait_for_unit("nookd.service")
      machine.succeed("systemctl stop nookd.service")

      with subtest("missing approvals refuse without changing every bundle hash"):
          before = member_hashes()
          for arguments in [
              "reinitialize",
              "reinitialize --approve-reinitialize",
              "reinitialize --accept-unsynced-loss",
          ]:
              rc, output = recover(arguments)
              assert rc == 2, (arguments, rc, output)
              assert "requires" in output, output
              assert member_hashes() == before, arguments

      with subtest("both approvals quarantine originals and create fresh state"):
          original_hashes = member_hashes()
          rc, output = recover(
              "reinitialize --approve-reinitialize --accept-unsynced-loss"
          )
          assert rc == 0, output
          match = re.search(r"id=([A-Za-z0-9_-]+)", output)
          assert match is not None, output
          quarantine_id = match.group(1)
          quarantine = STATE + "/.recovery-quarantine/" + quarantine_id
          machine.succeed("test -d " + shlex.quote(quarantine))
          assert machine.succeed(
              "stat -c '%a' " + shlex.quote(STATE + "/.recovery-quarantine")
          ).strip() == "700"
          assert machine.succeed(
              "stat -c '%a' " + shlex.quote(quarantine)
          ).strip() == "700"
          preserved = hashes_for(quarantine)
          assert preserved == original_hashes
          machine.succeed(
              "test -f " + " && test -f ".join(
                  shlex.quote(STATE + "/" + member) for member in MEMBERS
              )
          )
          # The originals must actually have moved: fresh bytes differ from the
          # quarantined bytes, and nothing is hardlinked back into place.
          fresh_hashes = member_hashes()
          assert fresh_hashes != original_hashes, (fresh_hashes, original_hashes)
          for member in MEMBERS:
              member_path = shlex.quote(STATE + "/" + member)
              # Different bytes alone would also be satisfied by re-encrypting
              # the same rows under a new salt, and `stat %h` is 1 for a symlink
              # too. A fresh bundle here is a set of empty regular files.
              assert machine.execute("test -f " + member_path)[0] == 0, member
              assert machine.execute("test ! -L " + member_path)[0] == 0, member
              size = machine.succeed("stat -c '%s' " + member_path).strip()
              assert size == "0", (member, size)
          for member in MEMBERS:
              links = machine.succeed(
                  "stat -c '%h' " + shlex.quote(STATE + "/" + member)
              ).strip()
              assert links == "1", (member, links)
          for member in MEMBERS:
              machine.succeed(
                  "chown nookbridge:nookbridge " + shlex.quote(STATE + "/" + member)
                  + " && chmod 0600 " + shlex.quote(STATE + "/" + member)
              )
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")
          machine.wait_until_succeeds(
              "test -f " + shlex.quote(STATE + "/nookbridge.lock"), timeout=120
          )
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is currently locked"), output
          machine.succeed("systemctl stop nookd.service")
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith("production database bundle is healthy"), output
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")
          machine.succeed("systemctl stop nookd.service")

      with subtest("rollback refuses an occupied fresh destination without moving"):
          before_tree = tree_snapshot()
          before_quarantine = hashes_for(
              STATE + "/.recovery-quarantine/" + quarantine_id
          )
          rc, output = recover(
              "rollback --approve-rollback " + shlex.quote(quarantine_id)
          )
          assert rc == 2, output
          assert "destination is occupied" in output, output
          assert tree_snapshot() == before_tree
          assert hashes_for(STATE + "/.recovery-quarantine/" + quarantine_id) == before_quarantine

      with subtest("rollback restores the quarantined bytes onto cleared state"):
          quarantine = STATE + "/.recovery-quarantine/" + quarantine_id
          preserved_hashes = hashes_for(quarantine)
          machine.succeed(
              "install -d -m 0700 -o root -g root /run/nookbridge-recovery/fresh-aside && "
              + "for member in nookbridge-storage.db notesnook.db notesnook-logs.db; do "
              + "mv -- " + shlex.quote(STATE + "/") + "$member "
              + shlex.quote("/run/nookbridge-recovery/fresh-aside/") + "$member; done"
          )
          rc, output = recover(
              "rollback --approve-rollback " + shlex.quote(quarantine_id)
          )
          assert rc == 0, output
          assert member_hashes() == preserved_hashes
          machine.fail("test -e " + shlex.quote(quarantine))
          for member in MEMBERS:
              machine.succeed(
                  "chown nookbridge:nookbridge " + shlex.quote(STATE + "/" + member)
                  + " && chmod 0600 " + shlex.quote(STATE + "/" + member)
              )
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")

      with subtest("socket ownership and client boundary survive restarts"):
          # Cycle the daemon so the socket permissions are proven to be applied
          # on every start, not only on first creation. `start` is a no-op when
          # the unit is already active.
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")
          machine.wait_until_succeeds("test -S /run/nookbridge/nookbridge.sock", timeout=120)
          machine.succeed("systemctl stop nookd.service")
          machine.wait_until_succeeds("test ! -e /run/nookbridge/nookbridge.sock")
          machine.succeed("systemctl start nookd.service")
          machine.wait_for_unit("nookd.service")
          machine.wait_until_succeeds("test -S /run/nookbridge/nookbridge.sock")
          socket_info = machine.succeed(
              "stat -c '%U %G %a' /run/nookbridge/nookbridge.sock"
          ).strip().split()
          assert socket_info == ["nookbridge", "nookbridge-clients", "770"], socket_info
          machine.succeed(
              "runuser -u hermes -- " + "${pkgs.python3}/bin/python3" + " -c "
              + shlex.quote(
                  "import socket; s=socket.socket(socket.AF_UNIX); "
                  "s.connect('/run/nookbridge/nookbridge.sock'); s.close()"
              )
          )
          machine.fail(
              "runuser -u outsider -- " + "${pkgs.python3}/bin/python3" + " -c "
              + shlex.quote(
                  "import socket; s=socket.socket(socket.AF_UNIX); "
                  "s.connect('/run/nookbridge/nookbridge.sock')"
              )
          )
          # Directory traversal for the client group is intentional (0750);
          # the bundle members themselves are what must stay confidential.
          assert machine.succeed(
              "stat -c '%U %G %a' " + shlex.quote(STATE)
          ).strip() == "nookbridge nookbridge-clients 750"
          for member in MEMBERS:
              member_path = shlex.quote(STATE + "/" + member)
              # A deleted member would make `cat` fail for the wrong reason, and
              # a symlink would make `stat -c %h` look like a fresh file.
              assert machine.succeed("stat -c '%F' " + member_path).strip() == "regular file", member
              assert machine.succeed("stat -c '%h' " + member_path).strip() == "1", member
              machine.fail("runuser -u hermes -- cat " + member_path)
          machine.fail(
              "runuser -u hermes -- cat "
              + shlex.quote(${builtins.toJSON fixtureKeyPath})
          )

      with subtest("synthetic readWriteNoDelete policy denies a delete request on the MCP socket"):
          assert machine.succeed(
              "cat /run/nookbridge/effective-policy"
          ).strip() == "readWriteNoDelete"
          mcp_messages = [
              '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"recovery-test","version":"1"}}}',
              '{"jsonrpc":"2.0","method":"notifications/initialized"}',
              '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notesnook_delete_note","arguments":{"path":"Fixture/Canary"}}}',
          ]
          mcp_input = " ".join(shlex.quote(message) for message in mcp_messages)
          rc, output = machine.execute(
              "printf '%s\\n' " + mcp_input + " | runuser -u hermes -- "
              + "/run/current-system/sw/bin/nook-mcp --socket "
              + shlex.quote("/run/nookbridge/nookbridge.sock") + " 2>&1"
          )
          assert rc == 0, output
          assert "permission_denied" in output, output

      with subtest("canary and database key do not leak"):
          canary = machine.succeed("cat " + shlex.quote(CANARY_PATH)).strip()
          assert canary
          # The canary lives inside an encrypted SQLCipher database, so it must
          # never appear as plaintext at all. Prove the search method itself can
          # find it when it IS written in the clear, then assert absence below;
          # without this control an always-empty grep would pass silently.
          machine.succeed(
              "printf '%s' " + shlex.quote(canary) + " > /run/canary-control"
          )
          assert machine.execute(
              "grep -a -q -F -- " + shlex.quote(canary) + " /run/canary-control"
          )[0] == 0, "canary search method does not detect a known-present value"
          machine.succeed("rm -f /run/canary-control")

          journal = machine.succeed("journalctl --no-pager -o cat")
          assert journal.strip(), "journal is empty; the absence checks below would be vacuous"

          assert canary not in journal
          machine.fail(
              "journalctl --no-pager -o cat | grep -F -- " + shlex.quote(canary)
          )

          key = machine.succeed("cat " + shlex.quote(${builtins.toJSON fixtureKeyPath})).strip()
          assert key
          assert key not in journal, "database key is in the journal"

          unit_environment = machine.succeed(
              "systemctl show nookd.service -p Environment --value"
          )
          assert "NOOKBRIDGE_DATABASE_KEY" not in unit_environment
          pid = machine.succeed(
              "systemctl show nookd.service -p MainPID --value"
          ).strip()
          assert pid.isdigit() and pid != "0", pid
          environment_path = "/proc/" + pid + "/environ"
          assert machine.execute("test -r " + environment_path)[0] == 0, (
              "cannot read the daemon environment: " + environment_path
          )
          process_environment = machine.succeed(
              "tr '\\000' '\\n' < " + environment_path
          )
          assert process_environment.strip(), "daemon environment is empty"
          assert key not in process_environment, "database key is in the daemon environment"
          assert "NOOKBRIDGE_DATABASE_KEY" not in process_environment
    '';
}
