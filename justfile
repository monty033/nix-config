nrs host="$HOSTNAME":
  sudo nixos-rebuild switch --flake /home/patrick/nix-config#{{host}}

nrs-r host:
  sudo nixos-rebuild switch --flake /home/patrick/nix-config#{{host}} --target-host root@{{host}}

cache-push host="":
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -n "{{host}}" ]; then
    ssh root@{{host}} 'cachix push monty-nix-config /run/current-system' &
  else
    # sudo so cachix picks up /root/.config/cachix/cachix.dhall (root-owned).
    # cachix reads from $HOME/.config/cachix, not $XDG_CONFIG_HOME.
    sudo cachix push monty-nix-config /run/current-system &
  fi

cache-nrs host="$HOSTNAME":
  sudo nixos-rebuild switch --flake /home/patrick/nix-config#{{host}}
  just cache-push

cache-nrs-r host:
  sudo nixos-rebuild switch --flake /home/patrick/nix-config#{{host}} --target-host root@{{host}} --build-host root@nix-fury
  just cache-push {{host}}

nrb-r host:
  sudo nixos-rebuild boot --flake /home/patrick/nix-config#{{host}} --target-host root@{{host}}


nrsb-r host:
  nixos-rebuild switch --flake /home/patrick/nix-config#{{host}} --build-host root@nix-fury --target-host root@{{host}}

nrs-wtf host="$HOSTNAME":
  sudo nixos-rebuild switch --flake /home/patrick/nix-config#{{host}} --show-trace --print-build-logs --verbose

nfc:
  sudo nix flake check

# Python unit tests. Hermetic: no network, no sudo, no host access.
# Every suite here was verified passing without contacting live infrastructure.
# Two suites are deliberately excluded, both failing on master before this recipe:
#   test_dns_migration              one assertion fails (17 != 16 in the rendered plan)
#   test_hermes_relay_plugin_import needs `requests`, which the devshell provides
# Add a suite here only once it passes; a recipe that is red on arrival teaches
# everyone to ignore it.

# run the hermetic Python unit tests
test:
  python3 -m unittest \
    tests.test_nix_pr \
    tests.test_pihole_audit \
    tests.test_pihole_baseline \
    tests.test_pihole_deploy_setup_reconcile \
    tests.test_pihole_deploy_transport_recovery \
    tests.test_pihole_list_authority \
    tests.test_pihole_live_adapter \
    tests.test_pihole_live_apply \
    tests.test_pihole_live_dry_run \
    tests.test_pihole_live_reconcile \
    tests.test_pihole_policy_adlist_discard \
    tests.test_pihole_policy_reconcile \
    tests.test_pihole_setup_behavior \
    tests.test_pihole_setup_script \
    tests.test_pihole_setup_sops_credential \
    tests.test_switch_dns_path

secrets:
  -nix-shell -p sops --run "SOPS_AGE_KEY_FILE='/home/patrick/.config/sops/age/keys.txt' sops secrets/secrets.yaml"

pihole-identities:
  #!/usr/bin/env bash
  set -euo pipefail
  export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/home/patrick/.config/sops/age/keys.txt}"
  exec nix shell nixpkgs#sops --command sops secrets/pihole-identities.yaml

git-acpush message branch="master":
  git add .
  git commit -m "{{message}}"
  git push origin "{{branch}}"

git-cpush message branch="master":
  git commit -m "{{message}}"
  git push origin "{{branch}}"

git-rpull remote:
  ssh root@{{remote}} "cd /etc/nixos && git pull https://github.com/monty033/nix-config.git"

rescue-build:
  nix build .#nixosConfigurations.rescue.config.system.build.isoImage --impure

rescue-flash device:
  sudo dd if=$(ls result/iso/*.iso) of={{device}} bs=4M status=progress conv=fsync

rescue-build-flash device: rescue-build
  just rescue-flash {{device}}

rescue-flash-remote host device:
  cat result/iso/*.iso | ssh root@{{host}} "dd of={{device}} bs=4M status=progress conv=fsync"

rescue-build-flash-remote host device: rescue-build
  just rescue-flash-remote {{host}} {{device}}

rescue-test:
  nix shell nixpkgs#qemu --command sudo qemu-system-x86_64 -m 4G -enable-kvm -cpu host -drive file=/dev/sda,format=raw,if=virtio

ap host tags="all" vars="":
  ansible-playbook ansible/playbooks/host_{{host}}.yml --tags "{{tags}}" -e "{{vars}}"

ap-bootstrap host:
  ansible-playbook ansible/playbooks/bootstrap_new_host.yml -e "host={{host}}"

av-edit-vars:
  ansible-vault edit ansible/playbooks/vars/homelab_secret_vars.yml

reqs:
  ansible-galaxy install -r ansible/requirements.yml

pihole-deploy host="all":
  python3 scripts/pihole/deploy.py {{host}}
