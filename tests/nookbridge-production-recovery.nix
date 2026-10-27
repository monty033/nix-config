# Stage 9 G2: the production NookBridge module, daemon, bundle recovery, and
# Unix-socket boundary in one TCG-only NixOS VM.
#
# This is deliberately different from nookbridge-recovery.nix: it imports the
# production module and leaves its nookd.service and ExecStart untouched.  The
# daemon creates the encrypted production bundle and its own lock; the test
# never supplies a replacement daemon, policy, lock file, or post-recovery
# ownership fix.  It does not exercise a real Notesnook account or sync: the
# VM starts with empty local state and uses the daemon's offline runtime only.
#
# The pinned production CLI exposes this database-bundle workflow as
# `recover-local-state bundle {inspect,reinitialize,rollback}`.  The shorter
# `recover-local-state reinitialize` command is the separate single-database
# development path and rejects --accept-unsynced-loss; using `bundle` here is
# required to exercise the production members and is derived from the pinned
# package contract.

{ pkgs, inputs, readableCorruption ? true }:

let
  nookbridge = pkgs.callPackage ../packages/nookbridge.nix {
    inherit inputs;
  };

  # The pinned upstream core exports the real log-database initializer, but
  # nookd does not call it until an authenticated Notesnook session emits a
  # persistent log.  The offline VM intentionally has no account or sync, so
  # use that upstream initializer once to create the lazy production member.
  # This is not a fixture database: the pinned core opens and migrates the
  # encrypted file with the production credential and the production service
  # identity.  The daemon, lock, recovery tool, and policy remain untouched.
  logDatabaseInitializer = pkgs.writeText "nookbridge-production-recovery-log-init.mjs" ''
    import { createRequire } from "node:module";
    import { readFileSync } from "node:fs";

    const require = createRequire(import.meta.url);
    const core = await import("${nookbridge}/libexec/nookbridge/node_modules/@notesnook/core/dist/index.js");
    const Database = require("${nookbridge}/libexec/nookbridge/node_modules/better-sqlite3-multiple-ciphers");
    const { SqliteDialect } = require("${nookbridge}/libexec/nookbridge/node_modules/@streetwriters/kysely");
    const stateDir = "/var/lib/nookbridge";
    const key = readFileSync(
      process.env.CREDENTIALS_DIRECTORY + "/nookbridge-db-key",
      "utf8",
    ).trim();
    const databases = [];
    const escapeKey = (value) => value.replaceAll("\"", "\"\"");

    await core.initialize({
      dialect: (name) => {
        if (name !== "notesnook-logs") throw new Error("unexpected database");
        const database = new Database(stateDir + "/notesnook-logs.db");
        database.pragma("cipher='sqlcipher'");
        database.pragma("key=\"" + escapeKey(key) + "\"");
        databases.push(database);
        return new SqliteDialect({ database });
      },
      journalMode: "WAL",
      synchronous: "normal",
    }, true);
    for (const database of databases) database.close();
    // The upstream logger owns a timer; this one-shot initializer has already
    // closed the real SQLCipher handle, so terminate the helper explicitly.
    process.exit(0);
  '';

  stateDir = "/var/lib/nookbridge";
  socketPath = "/run/nookbridge/nookbridge.sock";
  members = [
    "nookbridge-storage.db"
    "notesnook.db"
    "notesnook-logs.db"
  ];
in
{
  name = "nookbridge-production-recovery";

  nodes.machine =
    { config, lib, pkgs, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../modules/nookbridge.nix
      ];
      # The production module's package call follows the same special-args
      # convention as nookbridge-settings-module.nix.
      _module.args.inputs = inputs;

      system.stateVersion = "26.05";

      extra-services.nookbridge = {
        enable = true;
        # Select the real repository settings file.  Do not choose a test
        # policy: the final RPC assertion reads this deployed file and derives
        # its denied notebook from its delete=false override.
        settings = null;
        settingsFile = ../modules/nookbridge/settings.json;
      };

      sops = {
        # Both the identity and ciphertext are made inside the VM.  A runtime
        # path is intentional here: validating a build-time sops file would
        # put decryptable fixture material in /nix/store.
        validateSopsFiles = false;
        defaultSopsFile = "/run/nookbridge-sops/secret.yaml";
        age.keyFile = "/run/nookbridge-sops/age-key.txt";
        secrets."nookbridge-db-key".sopsFile = "/run/nookbridge-sops/secret.yaml";
      };

      # sops-nix decrypts regular secrets from the setupSecrets activation
      # script. Generate this boot's identity and ciphertext immediately
      # before that script, so neither decryptable material nor the identity is
      # present in the store. The runtime paths are reset with /run on reboot.
      system.activationScripts.nookbridge-sops-fixture = lib.stringAfter [ "etc" ] ''
        set -eu
        umask 077
        runtime_dir=/run/nookbridge-sops
        age_key="$runtime_dir/age-key.txt"
        secret="$runtime_dir/secret.yaml"
        plain="$runtime_dir/plain.yaml"
        ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root "$runtime_dir"
        ${pkgs.coreutils}/bin/rm -f -- "$age_key" "$secret" "$plain"
        ${pkgs.age}/bin/age-keygen -o "$age_key" 2>/dev/null
        ${pkgs.coreutils}/bin/chmod 0400 "$age_key"
        recipient="$(${pkgs.age}/bin/age-keygen -y "$age_key")"
        db_key="$(${pkgs.coreutils}/bin/od -An -N32 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')"
        ${pkgs.coreutils}/bin/printf 'nookbridge-db-key: %s\n' "$db_key" > "$plain"
        ${pkgs.sops}/bin/sops --encrypt --age "$recipient" \
          --input-type yaml --output-type yaml "$plain" > "$secret"
        ${pkgs.coreutils}/bin/rm -f -- "$plain"
        ${pkgs.coreutils}/bin/chmod 0400 "$secret"
      '';
      system.activationScripts.setupSecrets.deps = [ "nookbridge-sops-fixture" ];
      environment.systemPackages = [ pkgs.nodejs_22 pkgs.python3 ];

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
    };

  testScript = { ... }:
    let
      membersJson = builtins.toJSON members;
      stateJson = builtins.toJSON stateDir;
      socketJson = builtins.toJSON socketPath;
    in
    ''
      import json
      import re
      import shlex

      STATE = ${stateJson}
      SOCKET = ${socketJson}
      MEMBERS = ${membersJson}
      SECRET_SOURCE = "/run/secrets/nookbridge-db-key"
      AGE_KEY = "/run/nookbridge-sops/age-key.txt"
      RECOVERY = "/run/current-system/sw/bin/nookbridge-recovery"
      SECRET_SCAN_DIR = "/run/nookbridge-g2-secret-scans"
      CLI_OUTPUT = SECRET_SCAN_DIR + "/recovery-cli-output"
      KEY_PATTERN = SECRET_SCAN_DIR + "/db-key-pattern"
      AGE_PATTERN = SECRET_SCAN_DIR + "/age-key-pattern"
      POSITIVE_CONTROL = SECRET_SCAN_DIR + "/positive-control"
      ARGV_POSITIVE_CONTROL = SECRET_SCAN_DIR + "/argv-positive-control"
      JOURNAL_SCAN = SECRET_SCAN_DIR + "/journal-scan"
      ARGV_SCAN = SECRET_SCAN_DIR + "/argv-scan"
      PROC_ARGV_SCAN = SECRET_SCAN_DIR + "/proc-argv-scan"
      PROC_ARGV_ERRORS = SECRET_SCAN_DIR + "/proc-argv-errors"
      PROC_ARGV_ONE_ERROR = SECRET_SCAN_DIR + "/proc-argv-one-error"
      RUN_LEAK_SCAN = SECRET_SCAN_DIR + "/run-leaks"
      RUN_LEAK_ERRORS = SECRET_SCAN_DIR + "/run-leak-errors"
      RUN_FILES = SECRET_SCAN_DIR + "/run-files"
      ETC_LEAK_SCAN = SECRET_SCAN_DIR + "/etc-leaks"
      ETC_LEAK_ERRORS = SECRET_SCAN_DIR + "/etc-leak-errors"
      ETC_FILES = SECRET_SCAN_DIR + "/etc-files"
      READABLE_CORRUPTION = ${if readableCorruption then "True" else "False"}

      def diagnostics(label):
          status_rc, status = machine.execute(
              "systemctl status nookd.service --no-pager -l"
          )
          journal_rc, journal = machine.execute(
              "journalctl -u nookd.service --no-pager -n 40"
          )
          state_rc, state = machine.execute(
              "find " + shlex.quote(STATE)
              + " -maxdepth 2 -printf '%M %U %G %s %p\\n' | sort"
          )
          return "{}\n--- unit (rc {}) ---\n{}\n--- journal (rc {}) ---\n{}".format(
              label, status_rc, status, journal_rc, journal
          ) + "\n--- state (rc {}) ---\n{}".format(state_rc, state)

      def wait_until(command, label, timeout=180):
          try:
              machine.wait_until_succeeds(command, timeout=timeout)
          except Exception as exc:
              raise AssertionError(diagnostics(label)) from exc

      def wait_stopped():
          wait_until(
              "test \"$(systemctl is-active nookd.service)\" = inactive || test \"$(systemctl is-active nookd.service)\" = failed",
              "nookd did not stop",
          )
          wait_until(
              "test ! -e " + shlex.quote(STATE + "/nookbridge.lock"),
              "nookd did not release its production lock",
          )
          wait_until(
              "test \"$(systemctl show -p MainPID --value nookd.service)\" = 0",
              "nookd process did not exit",
          )

      def wait_started():
          try:
              machine.wait_for_unit("nookd.service", timeout=180)
          except Exception as exc:
              raise AssertionError(diagnostics("nookd did not become active")) from exc
          wait_until(
              "test -S " + shlex.quote(SOCKET),
              "nookd did not create its production socket",
          )
          # systemd Type=simple reports active before the runtime has opened
          # PersistentStorage.  Wait for the real daemon's lock rather than
          # racing the production recovery probe against startup.
          wait_until(
              "test -f " + shlex.quote(STATE + "/nookbridge.lock"),
              "real nookd did not hold the production lock",
          )

      def assert_secret_absent(command, label):
          rc, output = machine.execute(command)
          # grep: 0 = match (a leak), 1 = no match (good), >1 = the scan itself
          # failed.  Reporting a broken scan as a leak hides real failures and
          # sends the reader hunting a product bug that does not exist.
          assert rc != 0, (label + ": leaked", rc, output)
          assert rc == 1, (label + ": scan failed", rc, output)

      def cleanup_secret_scans():
          machine.succeed(
              "if test -d " + shlex.quote(SECRET_SCAN_DIR) + "; then "
              + "rm -f -- " + " ".join(
                  shlex.quote(path) for path in [
                      CLI_OUTPUT,
                      KEY_PATTERN,
                      AGE_PATTERN,
                      POSITIVE_CONTROL,
                      ARGV_POSITIVE_CONTROL,
                      JOURNAL_SCAN,
                      ARGV_SCAN,
                      PROC_ARGV_SCAN,
                      PROC_ARGV_ERRORS,
                      PROC_ARGV_ONE_ERROR,
                      RUN_LEAK_SCAN,
                      RUN_LEAK_ERRORS,
                      RUN_FILES,
                      ETC_LEAK_SCAN,
                      ETC_LEAK_ERRORS,
                      ETC_FILES,
                  ]
              ) + " && rmdir -- " + shlex.quote(SECRET_SCAN_DIR) + "; fi"
          )

      def prepare_secret_scans():
          machine.succeed(
              "install -d -m 0700 -o root -g root " + shlex.quote(SECRET_SCAN_DIR)
              + " && umask 077 && test -s " + shlex.quote(SECRET_SOURCE)
              + " && tr -d '\\n' < " + shlex.quote(SECRET_SOURCE)
              + " > " + shlex.quote(KEY_PATTERN)
              + " && chmod 0600 " + shlex.quote(KEY_PATTERN)
              + " && test -s " + shlex.quote(AGE_KEY)
              + " && cat " + shlex.quote(AGE_KEY)
              + " > " + shlex.quote(AGE_PATTERN)
              + " && chmod 0600 " + shlex.quote(AGE_PATTERN)
          )
          # Positive control: the exact grep method used by the negative scans
          # must find the key when a controlled file contains it.
          machine.succeed(
              "umask 077 && cat " + shlex.quote(SECRET_SOURCE)
              + " > " + shlex.quote(POSITIVE_CONTROL)
              + " && chmod 0600 " + shlex.quote(POSITIVE_CONTROL)
          )
          machine.succeed(
              "grep -Fq -f " + shlex.quote(SECRET_SOURCE)
              + " " + shlex.quote(POSITIVE_CONTROL)
          )
          machine.succeed(
              "umask 077 && printf 'argv-control=%s\\0' \"$(cat "
              + shlex.quote(SECRET_SOURCE) + ")\" > "
              + shlex.quote(ARGV_POSITIVE_CONTROL)
              + " && chmod 0600 " + shlex.quote(ARGV_POSITIVE_CONTROL)
          )
          machine.succeed(
              "grep -Fazq -f " + shlex.quote(KEY_PATTERN)
              + " " + shlex.quote(ARGV_POSITIVE_CONTROL)
          )

      def assert_no_key_leaks():
          try:
              prepare_secret_scans()
              machine.succeed(
                  "umask 077 && journalctl --no-pager -o cat > "
                  + shlex.quote(JOURNAL_SCAN) + " && chmod 0600 "
                  + shlex.quote(JOURNAL_SCAN)
              )
              machine.succeed("test -s " + shlex.quote(JOURNAL_SCAN))
              for pattern, label in [
                  (KEY_PATTERN, "database key"),
                  (AGE_PATTERN, "age identity"),
              ]:
                  assert_secret_absent(
                      "grep -Fq -f " + shlex.quote(pattern)
                      + " " + shlex.quote(JOURNAL_SCAN),
                      label + " leaked into the journal",
                  )
              main_pid = machine.succeed(
                  "systemctl show -p MainPID --value nookd.service"
              ).strip()
              assert main_pid.isdigit(), main_pid
              if main_pid != "0":
                  for pattern, label in [
                      (KEY_PATTERN, "database key"),
                      (AGE_PATTERN, "age identity"),
                  ]:
                      assert_secret_absent(
                          "grep -Fazq -f " + shlex.quote(pattern)
                          + " /proc/" + main_pid + "/environ",
                          label + " leaked into nookd environment",
                      )
              machine.succeed(
                  "umask 077 && ps -eww -eo args > " + shlex.quote(ARGV_SCAN)
                  + " && chmod 0600 " + shlex.quote(ARGV_SCAN)
              )
              machine.succeed("test -s " + shlex.quote(ARGV_SCAN))
              for pattern, label in [
                  (KEY_PATTERN, "database key"),
                  (AGE_PATTERN, "age identity"),
              ]:
                  assert_secret_absent(
                      "grep -Fq -f " + shlex.quote(pattern)
                      + " " + shlex.quote(ARGV_SCAN),
                      label + " leaked into CLI-visible argv",
                  )
              # Snapshot readable process cmdlines without swallowing either a
              # read failure or an empty snapshot. The positive control above
              # proves the grep method itself can still match the key.
              machine.succeed(
                  "umask 077; for f in /proc/[0-9]*/cmdline; do "
                  "if test -r \"$f\"; then "
                  "if ! tr '\\0' '\\n' < \"$f\" 2> "
                  + shlex.quote(PROC_ARGV_ONE_ERROR) + "; then "
                  "if test -e \"$f\"; then cat "
                  + shlex.quote(PROC_ARGV_ONE_ERROR) + " >&2; exit 1; fi; fi; fi; "
                  "done > " + shlex.quote(PROC_ARGV_SCAN) + " 2> "
                  + shlex.quote(PROC_ARGV_ERRORS) + " && chmod 0600 "
                  + shlex.quote(PROC_ARGV_SCAN) + " "
                  + shlex.quote(PROC_ARGV_ERRORS) + " && test -s "
                  + shlex.quote(PROC_ARGV_SCAN) + " && test ! -s "
                  + shlex.quote(PROC_ARGV_ERRORS)
              )
              for pattern, label in [
                  (KEY_PATTERN, "database key"),
                  (AGE_PATTERN, "age identity"),
              ]:
                  assert_secret_absent(
                      "grep -Fq -f " + shlex.quote(pattern)
                      + " " + shlex.quote(PROC_ARGV_SCAN),
                      label + " leaked into process argv",
                  )
              for root, scan, errors, files, label, excludes in [
                  ("/run", RUN_LEAK_SCAN, RUN_LEAK_ERRORS, RUN_FILES, "runtime files", [
                      "! -path " + shlex.quote(SECRET_SCAN_DIR + "/*"),
                      "! -path " + shlex.quote("/run/secrets/*"),
                      "! -path " + shlex.quote("/run/credentials/*"),
                      # The runtime identity itself is the declared protected
                      # source; scan every other runtime file for copies.
                      "! -path " + shlex.quote(AGE_KEY),
                      "! -path " + shlex.quote("/run/udev/*"),
                  ]),
                  ("/etc", ETC_LEAK_SCAN, ETC_LEAK_ERRORS, ETC_FILES, "etc files", []),
              ]:
                  # Enumerate regular files on the target filesystem, then
                  # inspect each with a bounded loop. This avoids recursive
                  # grep walking a runtime mount or symlink unexpectedly.
                  for pattern, pattern_label in [
                      (KEY_PATTERN, "database key"),
                      (AGE_PATTERN, "age identity"),
                  ]:
                      grep_command = (
                          "umask 077; find " + root + " -xdev -type f "
                          + " ".join(excludes) + " -print0 > " + shlex.quote(files)
                          + " && chmod 0600 " + shlex.quote(files)
                          + " && test -s " + shlex.quote(files)
                          + " && timeout 60s bash -c " + shlex.quote(
                              "if xargs -0 -r -a " + files
                              + " grep -F -l --binary-files=without-match -f "
                              + pattern + "; then :; "
                              "else rc=$?; test \"$rc\" -eq 123 || test \"$rc\" -eq 1; fi"
                          ) + " > " + shlex.quote(scan) + " 2> "
                          + shlex.quote(errors)
                          + "; scan_rc=$?; if test \"$scan_rc\" -ne 0; then "
                          + "echo 'bounded secret scan failed' >&2; cat "
                          + shlex.quote(errors) + " >&2; exit \"$scan_rc\"; fi; "
                          + "chmod 0600 " + shlex.quote(scan) + " "
                          + shlex.quote(errors) + " && if test -s " + shlex.quote(errors)
                          + "; then echo 'secret scan produced errors' >&2; cat "
                          + shlex.quote(errors) + " >&2; exit 1; fi"
                      )
                      machine.succeed(grep_command)
                      machine.succeed(
                          "test ! -s " + shlex.quote(scan)
                          + " || (echo '" + pattern_label + " leaked into " + label + "' >&2; cat "
                          + shlex.quote(scan) + "; exit 1)"
                      )
          finally:
              cleanup_secret_scans()

      def recover(arguments):
          # The module-owned privileged wrapper is the only recovery entry
          # point. It supplies the credential and service identity, suspends
          # nookd, and restores its prior active state.
          machine.succeed(
              "install -d -m 0700 -o root -g root " + shlex.quote(SECRET_SCAN_DIR)
              + " && rm -f -- " + shlex.quote(CLI_OUTPUT)
          )
          command = (
              shlex.quote(RECOVERY) + " "
              + arguments
          )
          result = machine.execute(
              "umask 077; " + command + " > " + shlex.quote(CLI_OUTPUT)
              + " 2>&1; chmod 0600 " + shlex.quote(CLI_OUTPUT)
          )
          captured_rc, captured = machine.execute("cat -- " + shlex.quote(CLI_OUTPUT))
          try:
              assert captured_rc == 0, ("recovery output capture failed", captured_rc, captured)
              output = result[1] + "\n" + captured
              assert database_key not in output, "database key leaked into recovery output"
              assert_no_key_leaks()
              wait_until(
                  "test -z \"$(systemctl list-units --all --type=service --no-legend 'nookbridge-recovery-*.service')\"",
                  "transient recovery unit did not finish collecting",
              )
              return result[0], output
          finally:
              machine.succeed("rm -f -- " + shlex.quote(CLI_OUTPUT))

      def hashes(root, names=MEMBERS):
          paths = " ".join(shlex.quote(root + "/" + name) for name in names)
          return machine.succeed("sha256sum -- " + paths + " | awk '{print $1}'").strip()

      def member_listing():
          names = machine.succeed(
              "find " + shlex.quote(STATE)
              + " -maxdepth 1 -type f -name '*.db' -printf '%f\\n' | sort"
          ).strip().splitlines()
          return sorted(names)

      def require_members(nonempty=True):
          assert member_listing() == sorted(MEMBERS), member_listing()
          for member in MEMBERS:
              path = shlex.quote(STATE + "/" + member)
              machine.succeed("test -f " + path)
              if nonempty:
                  machine.succeed("test -s " + path)
              # SQLCipher page 1 must not expose a plaintext SQLite header.
              machine.succeed(
                  "if head -c 15 " + path
                  + " | grep -Fq 'SQLite format 3'; then exit 1; fi"
              )

      def require_fresh_members():
          assert member_listing() == sorted(MEMBERS), member_listing()
          for member in MEMBERS:
              path = shlex.quote(STATE + "/" + member)
              ownership = machine.succeed(
                  "stat -c '%U %G %a' " + path
              ).strip()
              assert ownership == "nookbridge nookbridge 600", (member, ownership)
              # The wrapper may have already restored nookd by the time the
              # command returns, so a zero-length sample here would race the
              # daemon's first open.  Freshness is proved by the changed
              # hashes/inodes below; wait_started() and the post-start RPC then
              # wait for and verify the product's materialization condition.
              machine.succeed("test -f " + path)

      def mcp(messages, user="hermes"):
          payload = " ".join(shlex.quote(message) for message in messages)
          command = (
              "printf '%s\\n' " + payload + " | runuser -u " + user + " -- "
              + "/run/current-system/sw/bin/nook-mcp --socket "
              + shlex.quote(SOCKET) + " 2>&1"
          )
          return machine.execute(command)

      def notebook_listing():
          messages = [
              '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"g2-recovery","version":"1"}}}',
              '{"jsonrpc":"2.0","method":"notifications/initialized"}',
              '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notesnook_list_notebooks","arguments":{}}}',
          ]
          return mcp(messages)

      start_all()
      try:
          machine.wait_for_unit("multi-user.target", timeout=180)
      except Exception as exc:
          raise AssertionError(diagnostics("VM did not reach multi-user.target")) from exc
      wait_started()
      database_key = machine.succeed(
          "tr -d '\\n' < " + shlex.quote(SECRET_SOURCE)
      ).strip()
      assert database_key, "database key fixture is empty"
      assert_no_key_leaks()

      with subtest("sops age identity is runtime-only and root-only"):
          age_info = machine.succeed(
              "stat -c '%U %G %a %F' " + shlex.quote(AGE_KEY)
          ).strip().split()
          assert age_info == ["root", "root", "400", "regular", "file"], age_info
          machine.succeed("test ! -L " + shlex.quote(AGE_KEY))
          client_rc, client_output = machine.execute(
              "runuser -u hermes -- cat " + shlex.quote(AGE_KEY)
          )
          assert client_rc == 1, ("client cat age identity", client_rc, client_output)
          store_artifacts = machine.succeed(
              "find /nix/store -xdev -type f "
              "-path '*nookbridge-production-recovery-sops-fixture*' -print"
          ).strip().splitlines()
          # No build-time fixture derivation exists. If an artifact is ever
          # reintroduced, the client cat below must still be denied before the
          # test can accept it as a non-decryptable store copy.
          for artifact in store_artifacts:
              artifact_rc, artifact_output = machine.execute(
                  "runuser -u hermes -- cat " + shlex.quote(artifact)
              )
              assert artifact_rc != 0, (
                  "client cat store fixture artifact",
                  artifact,
                  artifact_rc,
                  artifact_output,
              )
          assert store_artifacts == [], store_artifacts

      with subtest("production daemon creates the encrypted bundle"):
          rc, output = notebook_listing()
          assert '\\"kind\\":\\"notebooks\\"' in output, (rc, output)
          assert '\\"notebooks\\":[' in output, (rc, output)
          # Empty offline startup lazily omits only the upstream log member;
          # materialize it through the real pinned core before the recovery
          # tool is asked to inspect the production bundle.
          machine.succeed(
              "systemd-run --quiet --wait --collect --pipe "
              "--unit=nookbridge-production-recovery-log-init.service "
              "--uid=nookbridge --gid=nookbridge-clients "
              "--property=TimeoutStartSec=2min --property=RuntimeMaxSec=2min "
              "--setenv=NOOKBRIDGE_STATE_DIR=" + shlex.quote(STATE) + " "
              "--property=WorkingDirectory=" + shlex.quote(STATE) + " "
              "--property=LoadCredential=nookbridge-db-key:" + shlex.quote(SECRET_SOURCE) + " "
              + shlex.quote("/run/current-system/sw/bin/node") + " "
              + shlex.quote("${logDatabaseInitializer}")
          )
          wait_until(
              "test -f " + shlex.quote(STATE + "/notesnook-logs.db"),
              "real upstream log initializer did not create its encrypted member",
          )
          require_members()

      machine.succeed("systemctl stop nookd.service")
      wait_stopped()

      with subtest("stopped production bundle inspects healthy"):
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is healthy"
          ), diagnostics(
              "healthy fixture inspect returned non-healthy: " + output
          )
          machine.succeed(
              "install -d -m 0750 -o nookbridge -g nookbridge /run/nookbridge-g2-clean"
          )
          machine.succeed(
              "runuser -u nookbridge -- cp -- "
              + " ".join(
                  shlex.quote(STATE + "/" + member) for member in MEMBERS
              )
              + " /run/nookbridge-g2-clean/"
          )

      with subtest("recovery wrapper restores a previously active daemon"):
          machine.succeed("systemctl start nookd.service")
          wait_started()
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is healthy"
          ), output
          wait_started()
          rc, output = recover("reinitialize")
          assert rc == 2, (rc, output)
          assert output.strip().endswith(
              "nookctl: nookctl recover-local-state bundle reinitialize requires --approve-reinitialize --accept-unsynced-loss"
          ), output
          # The daemon was active before the refusal and must be active after
          # the wrapper restores the prior state.
          wait_started()

      machine.succeed("systemctl stop nookd.service")
      wait_stopped()

      with subtest("page-one corruption is detected and prevents startup"):
          machine.succeed(
              "dd if=/dev/zero bs=512 count=1 status=none | tr '\\000' '\\245' | "
              + "dd of=" + shlex.quote(STATE + "/notesnook.db")
              + " bs=512 seek=0 conv=notrunc status=none"
          )
          corrupt_hashes = hashes(STATE)
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is corrupt"
          ), output
          machine.succeed("systemctl reset-failed nookd.service")
          start_rc, start_output = machine.execute("systemctl start nookd.service")
          assert start_rc in (0, 1), (start_rc, start_output)
          # The production unit deliberately has Restart=on-failure, so a
          # failed start may be retried before systemd settles in `failed`.
          # Observe the real failed-start journal line and a restart counter,
          # then stop the retry loop; this proves startup rejected the bytes
          # without depending on a transient unit state.
          wait_until(
              "test \"$(systemctl show -p NRestarts --value nookd.service)\" -ge 1",
              "nookd did not retry after corrupt SQLCipher state",
          )
          wait_until(
              "journalctl -u nookd.service --no-pager -o cat | grep -Fq 'nookd runtime startup failed'",
              "nookd failure was not recorded after corrupt SQLCipher state",
          )
          machine.succeed("systemctl stop nookd.service")
          wait_stopped()
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is corrupt"
          ), output
          assert hashes(STATE) == corrupt_hashes

      with subtest("destroyed header refuses reinitialize categorically"):
          machine.succeed("systemctl stop nookd.service")
          wait_stopped()
          rc, output = recover(
              "reinitialize --approve-reinitialize --accept-unsynced-loss"
          )
          assert rc == 2, (rc, output)
          assert output.strip().endswith(
              "nookctl recover-local-state: refusing unprobeable production database bundle"
          ), output
          assert hashes(STATE) == corrupt_hashes
          machine.succeed(
              "test ! -d " + shlex.quote(STATE + "/.recovery-quarantine")
          )

      # Start the second product branch from the healthy bundle. This reset is
      # before the readable-corrupt recovery, not a reset after recovery has
      # already claimed success.
      with subtest("readable-corrupt fixture is prepared without page-one damage"):
          machine.succeed("systemctl reset-failed nookd.service")
          machine.succeed(
              "runuser -u nookbridge -- cp -- "
              + " ".join(
                  shlex.quote("/run/nookbridge-g2-clean/" + member)
                  for member in MEMBERS
              )
              + " " + shlex.quote(STATE + "/")
          )
          machine.succeed("systemctl stop nookd.service")
          wait_stopped()
          require_members()
          if READABLE_CORRUPTION:
              # SQLCipher's page size is 4096 here. Flip one byte in page 2,
              # leaving page 1 and the encrypted header readable so the
              # product's SQLITE_CORRUPT branch, rather than its unprobeable
              # branch, is exercised.
              machine.succeed(
                  "printf '\\245' | dd of=" + shlex.quote(STATE + "/notesnook.db")
                  + " bs=1 seek=4096 conv=notrunc status=none"
              )

      with subtest("readable corruption is quarantined and fresh state starts"):
          corrupt_hashes = hashes(STATE)
          # This inspect is deliberately the load-bearing assertion for the
          # negative control: with readableCorruption=false the byte flip is
          # absent, so recovery must report healthy and this assertion fails
          # before reinitialize is attempted.
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is corrupt"
          ), output
          original_inodes = machine.succeed(
              "stat -c '%i' " + " ".join(
                  shlex.quote(STATE + "/" + member) for member in MEMBERS
              )
          ).strip()
          rc, output = recover(
              "reinitialize --approve-reinitialize --accept-unsynced-loss"
          )
          assert rc == 0, output
          match = re.search(r"id=([A-Za-z0-9_-]+)", output)
          assert match is not None, output
          quarantine_id = match.group(1)
          quarantine = STATE + "/.recovery-quarantine/" + quarantine_id
          assert machine.succeed(
              "stat -c '%a' " + shlex.quote(quarantine)
          ).strip() == "700"
          assert hashes(quarantine) == corrupt_hashes
          assert machine.succeed(
              "stat -c '%i' " + " ".join(
                  shlex.quote(quarantine + "/" + member) for member in MEMBERS
              )
          ).strip() == original_inodes
          require_fresh_members()
          fresh_hashes = hashes(STATE)
          assert fresh_hashes != corrupt_hashes
          fresh_inodes = machine.succeed(
              "stat -c '%i' " + " ".join(
                  shlex.quote(STATE + "/" + member) for member in MEMBERS
              )
          ).strip()
          assert fresh_inodes != original_inodes
          # Fresh state is not merely a renamed copy: wait for the real
          # daemon's post-start lock/socket condition before checking files.
          wait_started()
          require_members(nonempty=False)
          rc, listing = notebook_listing()
          assert '\\"kind\\":\\"notebooks\\"' in listing, (rc, listing)
          assert '\\"notebooks\\":[]' in listing, listing
          assert_no_key_leaks()

      with subtest("production socket and effective settings policy use recovered state"):
          # This is intentionally before rollback/fixture operations: the
          # daemon is serving the fresh bundle created by product recovery.
          socket_info = machine.succeed(
              "stat -c '%U %G %a' " + shlex.quote(SOCKET)
          ).strip().split()
          assert socket_info == ["nookbridge", "nookbridge-clients", "770"], socket_info
          machine.succeed(
              "runuser -u hermes -- " + shlex.quote("${pkgs.python3}/bin/python3")
              + " -c " + shlex.quote(
                  "import socket; s=socket.socket(socket.AF_UNIX); "
                  "s.connect(" + repr(SOCKET) + "); s.close()"
              )
          )
          machine.fail(
              "runuser -u outsider -- " + shlex.quote("${pkgs.python3}/bin/python3")
              + " -c " + shlex.quote(
                  "import socket; s=socket.socket(socket.AF_UNIX); "
                  "s.connect(" + repr(SOCKET) + ")"
              )
          )
          machine.fail(
              "runuser -u hermes -- cat " + shlex.quote(SECRET_SOURCE)
          )
          settings = json.loads(
              machine.succeed("cat /etc/nookbridge/settings.json")
          )
          denied_notebook = None
          for override in settings["overrides"]:
              if override.get("delete") is False:
                  denied_notebook = override["notebooks"][0]
                  break
          assert denied_notebook is not None, settings
          delete_path = denied_notebook + "/g2-policy-probe"
          messages = [
              '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"g2-policy","version":"1"}}}',
              '{"jsonrpc":"2.0","method":"notifications/initialized"}',
              json.dumps({
                  "jsonrpc": "2.0",
                  "id": 2,
                  "method": "tools/call",
                  "params": {
                      "name": "notesnook_delete_note",
                      "arguments": {"path": delete_path},
                  },
              }),
          ]
          rc, output = mcp(messages)
          assert rc == 0, output
          assert "permission_denied" in output, output

      with subtest("rollback refuses an occupied destination"):
          machine.succeed("systemctl stop nookd.service")
          wait_stopped()
          occupied_hashes = hashes(STATE)
          rc, output = recover(
              "rollback --approve-rollback " + shlex.quote(quarantine_id)
          )
          assert rc == 2, (rc, output)
          assert output.strip().endswith(
              "nookctl recover-local-state: nookctl recover-local-state bundle rollback: destination is occupied"
          ), output
          assert hashes(STATE) == occupied_hashes
          wait_stopped()

      with subtest("approved rollback restores the readable-corrupt originals"):
          # Removing fresh destinations is the product's explicit occupied-
          # destination escape hatch. No state-file ownership or permission
          # repair is performed by the test.
          machine.succeed(
              "rm -f -- " + " ".join(
                  shlex.quote(STATE + "/" + member) for member in MEMBERS
              ) + " " + " ".join(
                  shlex.quote(STATE + "/" + member + suffix)
                  for member in MEMBERS for suffix in ["-wal", "-shm"]
              )
          )
          machine.succeed("systemctl stop nookd.service")
          wait_stopped()
          rc, output = recover(
              "rollback --approve-rollback " + shlex.quote(quarantine_id)
          )
          assert rc == 0, ("rollback rc", rc, output)
          assert hashes(STATE) == corrupt_hashes
          require_members()
          rc, output = recover("inspect")
          assert rc == 0, diagnostics(
              "rolled-back corrupt state inspect failed: " + output
          )
          assert output.strip().endswith(
              "production database bundle is corrupt"
          ), output

      with subtest("rollback leaves restored corrupt state stopped"):
          active_rc, active_state = machine.execute("systemctl is-active nookd.service")
          assert active_rc != 0, (active_rc, active_state)
          assert active_state.strip() in ["inactive", "failed"], active_state
          machine.succeed(
              "test ! -e " + shlex.quote(STATE + "/nookbridge.lock")
          )

      with subtest("fresh orphan state refuses partial reinitialize"):
          machine.succeed(
              "rm -f -- "
              + " ".join(
                  shlex.quote(STATE + "/" + member + suffix)
                  for member in MEMBERS for suffix in ["-wal", "-shm"]
              )
          )
          machine.succeed("rm -- " + shlex.quote(STATE + "/notesnook.db"))
          machine.succeed(
              "touch -- "
              + shlex.quote(STATE + "/notesnook.db-wal")
          )
          rc, output = recover("inspect")
          assert rc == 0, output
          assert output.strip().endswith(
              "production database bundle is partial"
          ), output
          rc, output = recover(
              "reinitialize --approve-reinitialize --accept-unsynced-loss"
          )
          assert rc == 2, (rc, output)
          assert output.strip().endswith(
              "nookctl recover-local-state: refusing partial production database bundle"
          ), output
          assert machine.succeed(
              "test -e " + shlex.quote(STATE + "/notesnook.db-wal")
          ) == ""
          machine.succeed(
              "test ! -d " + shlex.quote(STATE + "/.recovery-quarantine/" + quarantine_id)
          )

    '';
}
