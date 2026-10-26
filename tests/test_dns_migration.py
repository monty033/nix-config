#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

from scripts.dns_migration import render_dnsmasq_plan  # noqa: E402
from scripts.dns_migration import render_inventory  # noqa: E402


class InventoryRenderingTests(unittest.TestCase):
    def setUp(self):
        self.inventory_path = ROOT / "inventory" / "default.nix"
        self.fixture_path = ROOT / "tests" / "fixtures" / "dns_migration" / "minimal-inventory.json"

    def test_real_nix_inventory_is_valid_and_deterministic(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        first = render_inventory.render(inventory)
        second = render_inventory.render(inventory)
        self.assertEqual(first, second)
        # Counts follow the household inventory and change whenever a device is added,
        # so assert the relationships that must hold rather than a snapshot number.
        reservations = first["networkReservations"]
        self.assertEqual(len(reservations), len(inventory["devices"]))
        self.assertEqual({item["device"] for item in reservations}, set(inventory["devices"]))
        self.assertEqual(len(first["piholeClients"]), len(reservations))
        self.assertEqual(
            first["unresolvedIdentityRefs"],
            sorted({item["identityRef"] for item in reservations}),
        )
        self.assertEqual(len(first["services"]), 0)
        self.assertEqual(first["unboundHostOverrides"], [])
        self.assertEqual(first["unboundHostAliases"], [])
        self.assertEqual(first["ownership"]["dhcpv6"], "opnsense")
        self.assertEqual(first["ownership"]["routerAdvertisements"], "opnsense")
        self.assertEqual(first["ownership"]["localDns"], "opnsense-unbound")
        self.assertEqual(first["policy"], {
            "base": {
                "upstreams": ["192.168.86.1"],
                "listeningInterfaces": ["eth0"],
                "queryLogging": True,
                "retention": 91,
            },
            "adlists": {
                "standard": [],
                "kids": [],
            },
            "groups": {
                "normal": {"description": "Normal clients"},
                "kids": {"description": "Kids clients"},
            },
            "groupAssignments": {},
            "localDns": [],
            "rules": {"allow": [], "block": []},
        })
        self.assertEqual(first["staticGuests"], [
            {
                "guest": "pihole1",
                "hostname": "pihole1",
                "address": "192.168.86.101",
                "interface": "lan",
                "placement": {"fallbackNodes": ["stark"], "preferredNode": "loki"},
            },
            {
                "guest": "pihole2",
                "hostname": "pihole2",
                "address": "192.168.86.102",
                "interface": "lan",
                "placement": {"fallbackNodes": ["stark"], "preferredNode": "starlord"},
            },
        ])

    def test_static_guest_rejects_dynamic_pool_address(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        inventory["staticGuests"]["bad-guest"] = {
            "network": {"hostname": "bad-guest", "address": "192.168.86.210", "interface": "lan"},
            "placement": {"preferredNode": "loki", "fallbackNodes": ["stark"]},
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_static_guest_rejects_duplicate_fallback_nodes(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        inventory["staticGuests"]["bad-guest"] = {
            "network": {"hostname": "bad-guest", "address": "192.168.86.103", "interface": "lan"},
            "placement": {"preferredNode": "loki", "fallbackNodes": ["stark", "stark"]},
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_fixture_renders_service_and_caddy_route(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        rendered = render_inventory.render(inventory)
        self.assertEqual(len(rendered["networkReservations"]), 2)
        self.assertEqual(len(rendered["piholeClients"]), 2)
        self.assertEqual(rendered["caddyRoutes"][0]["hostname"], "test.home.montycasa.net")
        self.assertEqual(rendered["caddyRoutes"][0]["upstream"], "192.168.86.10:8080")
        self.assertIsNone(rendered["piholeClients"][0]["identifier"])
        self.assertEqual(rendered["piholeClients"][0]["status"], "pending-encrypted-identity-resolution")

    def test_mac_only_device_requires_explicit_null_address(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"]["address"] = None
        rendered = render_inventory.render(inventory)
        tablet = next(r for r in rendered["networkReservations"] if r["device"] == "test-tablet")
        self.assertIsNone(tablet["address"])
        self.assertFalse(tablet["_hasStaticAddress"])

        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"].pop("address")
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_policy_is_required_at_the_inventory_boundary(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory.pop("policy", None)
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_policy_schema_rejects_unsupported_baseline_fields(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        inventory["policy"]["base"]["safeSearch"] = True
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_renders_opnsense_unbound_host_overrides_and_aliases(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [
                        {
                            "hostname": "router",
                            "rr": "A",
                            "server": "192.168.86.1",
                            "ttl": 300,
                            "addptr": False,
                            "enabled": True,
                            "description": "Local gateway",
                        }
                    ],
                    "aliases": [
                        {
                            "hostname": "gateway",
                            "target": "router",
                            "enabled": True,
                            "description": "Gateway alias",
                        }
                    ],
                }
            }
        }
        rendered = render_inventory.render(inventory)
        self.assertEqual(rendered["unboundHostOverrides"], [
            {
                "recordRef": "home.example/router/A",
                "hostname": "router",
                "domain": "home.example",
                "rr": "A",
                "server": "192.168.86.1",
                "ttl": 300,
                "addptr": False,
                "enabled": True,
                "description": "Local gateway",
            }
        ])
        self.assertEqual(rendered["unboundHostAliases"], [
            {
                "aliasRef": "home.example/gateway",
                "hostname": "gateway",
                "domain": "home.example",
                "targetRef": "home.example/router/A",
                "enabled": True,
                "description": "Gateway alias",
            }
        ])

    def test_local_dns_rejects_alias_target_and_duplicate_records(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [
                        {
                            "hostname": "router",
                            "rr": "A",
                            "server": "192.168.86.1",
                            "ttl": 300,
                            "addptr": False,
                            "enabled": True,
                            "description": "",
                        },
                        {
                            "hostname": "router",
                            "rr": "A",
                            "server": "192.168.86.2",
                            "ttl": 300,
                            "addptr": False,
                            "enabled": True,
                            "description": "",
                        }
                    ],
                    "aliases": [
                        {
                            "hostname": "gateway",
                            "target": "missing",
                            "enabled": True,
                            "description": "",
                        }
                    ],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_alias_override_name_collision(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": "A",
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": True,
                        "description": "router",
                    }],
                    "aliases": [{
                        "hostname": "router",
                        "target": "router",
                        "enabled": True,
                        "description": "collision",
                    }],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_oversized_description(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": "A",
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": True,
                        "description": "x" * 256,
                    }],
                    "aliases": [],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_malformed_record_types_without_traceback(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": ["A"],
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": True,
                        "description": "router",
                    }],
                    "aliases": [{
                        "hostname": "gateway",
                        "target": "router",
                        "targetRr": {"A": True},
                        "enabled": True,
                        "description": "alias",
                    }],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_malformed_alias_target_type(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": "A",
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": True,
                        "description": "router",
                    }],
                    "aliases": [{
                        "hostname": "gateway",
                        "target": "router",
                        "targetRr": {"A": True},
                        "enabled": True,
                        "description": "alias",
                    }],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_accepts_single_label_zone(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "lan": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": "A",
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": True,
                        "description": "router",
                    }],
                    "aliases": [],
                }
            }
        }
        self.assertEqual(render_inventory.render(inventory)["unboundHostOverrides"][0]["domain"], "lan")

    def test_local_dns_rejects_enabled_alias_to_disabled_target(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [{
                        "hostname": "router",
                        "rr": "A",
                        "server": "192.168.86.1",
                        "ttl": 300,
                        "addptr": False,
                        "enabled": False,
                        "description": "router",
                    }],
                    "aliases": [{
                        "hostname": "gateway",
                        "target": "router",
                        "enabled": True,
                        "description": "alias",
                    }],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_duplicate_enabled_ptr_ownership(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "home.example": {
                    "hostOverrides": [
                        {
                            "hostname": "one",
                            "rr": "A",
                            "server": "192.168.86.1",
                            "ttl": 300,
                            "addptr": True,
                            "enabled": True,
                            "description": "one",
                        },
                        {
                            "hostname": "two",
                            "rr": "A",
                            "server": "192.168.86.1",
                            "ttl": 300,
                            "addptr": True,
                            "enabled": True,
                            "description": "two",
                        },
                    ],
                    "aliases": [],
                }
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_canonical_zone_collisions_and_bad_trailing_dots(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {
            "zones": {
                "Home.Example": {"hostOverrides": [], "aliases": []},
                "home.example": {"hostOverrides": [], "aliases": []},
            }
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["localDns"] = {"zones": {"home.example..": {"hostOverrides": [], "aliases": []}}}
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_rejects_overlong_zone(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        long_zone = ".".join(["a" * 63] * 5)
        inventory["localDns"] = {"zones": {long_zone: {"hostOverrides": [], "aliases": []}}}
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_local_dns_ownership_is_required(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        del inventory["ownership"]["localDns"]
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_forbidden_client_identifier_is_rejected_case_insensitively(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-server"]["network"]["mac_address"] = "00:11:22:33:44:55"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_unknown_service_field_is_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-server"]["services"]["web"]["apiKey"] = "not-a-secret"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_invalid_proxy_is_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-server"]["services"]["web"]["proxy"] = "unknown"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_invalid_service_types_and_placement_are_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-server"]["services"]["web"]["upstreamPort"] = True
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-server"]["placement"] = {
            "preferredNode": "",
            "fallbackNodes": ["stark", "stark"],
        }
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_duplicate_address_is_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"]["address"] = "192.168.86.10"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_duplicate_identity_ref_is_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"]["identityRef"] = "lan-test-server"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_missing_profile_and_out_of_subnet_are_rejected(self):
        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"]["interface"] = "iot"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

        inventory = render_inventory.load_source(None, self.fixture_path)
        inventory["devices"]["test-tablet"]["network"]["address"] = "192.168.10.11"
        with self.assertRaises(render_inventory.InventoryError):
            render_inventory.render(inventory)

    def test_dnsmasq_plan_excludes_mac_only_devices(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        inventory["devices"]["emma-book"]["network"]["address"] = None
        rendered = render_inventory.render(inventory)
        plan = render_dnsmasq_plan.render(rendered)
        device_addresses = [
            reservation["device"]
            for profile in plan["profiles"]
            for reservation in profile["reservations"]
        ]
        self.assertNotIn("emma-book", device_addresses)
        self.assertEqual(
            {p["profile"]: p["reservationCount"] for p in plan["profiles"]},
            {"lan": 6, "iot": 7, "guest": 2},
        )

    def test_dnsmasq_plan_is_review_only_and_preserves_ownership(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        rendered = render_inventory.render(inventory)
        plan = render_dnsmasq_plan.render(rendered)
        self.assertEqual({p["profile"]: p["reservationCount"] for p in plan["profiles"]}, {"lan": 6, "iot": 7, "guest": 2})
        self.assertEqual(plan["target"], "opnsense-dnsmasq-dhcpv4")
        self.assertFalse(plan["apply"])
        self.assertEqual(plan["dhcpv6AndRA"]["dhcpv6"], "opnsense")
        self.assertEqual(plan["dhcpv6AndRA"]["routerAdvertisements"], "opnsense")
        self.assertEqual(plan["dhcpv6AndRA"]["rdnss"], "opnsense")
        self.assertEqual(plan["dnsDuringPhase1"], "adguard")
        self.assertEqual(plan["poolWarnings"], [])
        self.assertNotIn("macAddress", json.dumps(plan))

    def test_dnsmasq_plan_rejects_dropped_profile_join(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        rendered = render_inventory.render(inventory)
        rendered["networkReservations"][0]["interface"] = "phantom"
        with self.assertRaises(render_dnsmasq_plan.PlanError):
            render_dnsmasq_plan.render(rendered)

    def test_dnsmasq_plan_rejects_tampered_client_reference(self):
        inventory = render_inventory.load_source(self.inventory_path, None)
        rendered = render_inventory.render(inventory)
        rendered["piholeClients"][0]["clientRef"] = "identityRef:not-a-reservation"
        with self.assertRaises(render_dnsmasq_plan.PlanError):
            render_dnsmasq_plan.render(rendered)

    def test_no_production_source_uses_stale_port_5353_upstream(self):
        """Regression guard for the 2026-08-22 guest internet outage.

        OPNsense Unbound moved to port 53 at Gate 4 (2026-08-21). The Nix
        source-of-truth was left at ``192.168.86.1#5353`` in three places,
        which caused every uncached DNS lookup to time out before FTL fell
        back to the working port. This test fails if any production file
        (outside the disposable pihole-native-test host and the encrypted
        Ansible hex blob) reintroduces the stale port.
        """
        files_to_check = [
            ROOT / "inventory" / "default.nix",
            ROOT / "hosts" / "nxc" / "pihole" / "configuration.nix",
            ROOT / "scripts" / "pihole" / "live_reconcile.py",
            ROOT / "scripts" / "pihole" / "policy_reconcile.py",
            ROOT / "scripts" / "dns_migration" / "render_inventory.py",
        ]
        offenders = [p for p in files_to_check if "192.168.86.1#5353" in p.read_text()]
        self.assertEqual(
            offenders,
            [],
            f"production source still references stale :5353 upstream: {offenders}",
        )

    def test_inventory_device_key_matches_identityRef(self):
        """Convention: inventory device KEY equals ``identityRef``.

        A device's inventory key should be the same as its ``identityRef``
        field, with no interface prefix or other decoration. This decouples
        device identity from operational state (which VLAN it sits on) so a
        device that moves between VLANs retains its identity and SOPS mapping.
        """
        inventory = render_inventory.load_source(self.inventory_path, None)
        devices = inventory["devices"]
        mismatched = [
            (name, dev["network"].get("identityRef"))
            for name, dev in devices.items()
            if dev["network"].get("identityRef") and dev["network"]["identityRef"] != name
        ]
        self.assertEqual(
            mismatched,
            [],
            f"device keys must equal their identityRef (no interface prefix): {mismatched}",
        )

    def test_no_production_identityRef_carries_interface_prefix(self):
        """Regression guard for the 2026-08-22 identityRef-rename refactor.

        ``identityRef`` is a stable, host-only identifier that follows a
        device across VLAN changes. It must never encode the current
        interface (no ``lan-``, ``iot-``, or ``guest-`` prefix). This test
        fails if any production file re-introduces such a prefix.
        """
        import re

        inventory = render_inventory.load_source(self.inventory_path, None)
        prefixed = [
            (name, dev["network"]["identityRef"])
            for name, dev in inventory["devices"].items()
            if re.match(r"^(lan|iot|guest)-", dev["network"]["identityRef"])
        ]
        self.assertEqual(
            prefixed,
            [],
            f"identityRef must not encode the current interface: {prefixed}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
