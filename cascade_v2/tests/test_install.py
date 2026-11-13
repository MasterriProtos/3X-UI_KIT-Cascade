"""Pure/offline tests for clean EXIT/RELAY installer. No server changes."""
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hops
import install

PUBLIC_IPV6 = "2606:4700:4700::1111"
KEY = "A" * 43
USER_ID = "8e1f4d93-6f8f-4e36-aea5-94b309de42e1"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.local = {
            "address": PUBLIC_IPV6, "port": 24443, "id": USER_ID,
            "serverName": "www.example.com", "publicKey": KEY,
            "privateKey": KEY, "shortId": "0123456789abcdef",
        }

    def test_exit_config_contains_no_ip_forwarding(self):
        cfg = hops.node_config("exit", self.local)
        self.assertEqual(cfg["inbounds"][0]["listen"], PUBLIC_IPV6)
        self.assertEqual(cfg["inbounds"][0]["settings"]["users"][0]["id"], USER_ID)
        self.assertEqual(cfg["inbounds"][0]["streamSettings"]["realitySettings"]["target"],
                         "www.example.com:443")
        self.assertEqual(cfg["outbounds"][0]["tag"], "internet")
        self.assertNotIn("iptables", json.dumps(cfg))

    def test_relay_contains_no_direct_outbound(self):
        cfg = hops.node_config("relay", self.local, hops.link(self.local))
        self.assertEqual([p["tag"] for p in cfg["outbounds"]],
                         ["to-next-hop", "block"])
        self.assertEqual(cfg["routing"]["rules"][0]["outboundTag"], "to-next-hop")
        self.assertIn("password",
                      cfg["outbounds"][0]["streamSettings"]["realitySettings"])

    def test_link_does_not_expose_private_key(self):
        uri = hops.link(self.local)
        self.assertEqual(hops.parse_link(uri)["address"], PUBLIC_IPV6)
        self.assertNotIn("privateKey", uri)
        self.assertNotIn("privateKey", hops.entry_plan(uri)["outbound"])

    def test_sni_validation(self):
        with self.assertRaises(hops.ChainError):
            hops.check_sni("bad_domain.example")
        self.assertEqual(hops.check_sni("WWW.Example.COM"), "www.example.com")

    def test_global_address_discovery_filters_linklocal_and_tentative(self):
        result = [
            {"addr_info": [
                {"family": "inet6", "local": "fe80::1", "flags": []},
                {"family": "inet6", "local": "2001:db8::1", "flags": []},
                {"family": "inet6", "local": PUBLIC_IPV6, "flags": ["tentative"]},
                {"family": "inet6", "local": "2606:4700:4700::1001", "flags": []}
            ]}
        ]
        with mock.patch.object(install, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout=json.dumps(result))):
            self.assertEqual(install.global_ipv6(), ["2606:4700:4700::1001"])

    def test_atomic_file_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "secret.txt"
            install.write_atomic(target, b"secret")
            self.assertEqual(target.read_bytes(), b"secret")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            install.write_atomic(target, b"new")
            self.assertEqual(target.read_bytes(), b"new")

    def test_refuses_existing_unmanaged_xray(self):
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            (tmp / "xray").write_bytes(b"fake")
            with mock.patch.multiple(
                install, STATE_FILE=tmp / "state.json", MANAGED_CORE=tmp / "marker",
                XRAY=tmp / "xray", XRAY_UNIT=tmp / "unit",
                CONFIG_FILE=tmp / "config.json",
            ):
                with self.assertRaises(install.InstallError):
                    install.ensure_clean()

    def test_restore_retries_are_allowed_only_for_our_placeholder(self):
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            (tmp / "xray").write_bytes(b"binary")
            (tmp / "unit").write_text("service")
            (tmp / "marker").write_text("managed")
            (tmp / "config.json").write_text("{}")
            with mock.patch.multiple(
                install, STATE_FILE=tmp / "state.json", MANAGED_CORE=tmp / "marker",
                XRAY=tmp / "xray", XRAY_UNIT=tmp / "unit",
                CONFIG_FILE=tmp / "config.json",
            ), mock.patch.object(install, "run", return_value=subprocess.CompletedProcess(
                [], 3, stdout="inactive")):
                install.ensure_clean()
                (tmp / "config.json").write_text('{"inbounds":[]}')
                with self.assertRaises(install.InstallError):
                    install.ensure_clean()

    def test_key_parser_accepts_current_xray_output(self):
        example = "PrivateKey: " + KEY + "\nPassword: " + KEY + "\nHash32: abc\n"
        with mock.patch.object(install, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout=example)):
            private, public = install.generate_keys()
            self.assertEqual((private, public), (KEY, KEY))


if __name__ == "__main__":
    unittest.main()
