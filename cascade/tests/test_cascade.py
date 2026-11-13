"""Offline unit tests for the Cascade sidecar; no VPS/network required."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "kit_cascade.py"
spec = importlib.util.spec_from_file_location("kit_cascade", MODULE)
kit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kit)

P = {"version": 1, "address": "2001:db8::20", "port": 24443,
     "id": "01234567-89ab-4cde-8fab-0123456789ab",
     "publicKey": "test-public-key", "shortId": "0123456789abcdef",
     "serverName": "www.example.org"}

class Tests(unittest.TestCase):
    def test_peer_rejects_ipv4(self):
        with self.assertRaises(kit.Error):
            kit.peer("203.0.113.1", P["port"], P["id"], P["publicKey"], P["shortId"], P["serverName"])

    def test_entry_default_and_service_api(self):
        old = {"outbounds": [{"tag": "direct", "protocol": "freedom"},
                            {"tag": "api", "protocol": "freedom"}],
               "routing": {"rules": [
                   {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
                   {"type": "field", "domain": ["geosite:ru"], "outboundTag": "direct"}]}}
        out = kit.merge_entry(old, P)
        self.assertEqual(out["outbounds"][0]["tag"], kit.TAG)
        self.assertEqual(out["routing"]["rules"][0]["outboundTag"], "api")
        self.assertEqual(out["routing"]["rules"][1]["outboundTag"], kit.TAG)
        self.assertEqual(old["outbounds"][0]["tag"], "direct")

    def test_idempotency(self):
        old = {"outbounds": [{"tag": "direct", "protocol": "freedom"}]}
        a = kit.merge_entry(old, P)
        self.assertEqual(a, kit.merge_entry(a, P))
        self.assertEqual(a["inbounds"][0]["listen"], "127.0.0.1")

    def test_exit_has_private_key_peer_does_not(self):
        cfg = kit.config_exit(P, "private-test-key")
        self.assertEqual(cfg["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"], "private-test-key")
        self.assertNotIn("privateKey", json.dumps(P))

    def test_atomic_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "nested" / "test.json"
            kit.save(p, kit.j(P))
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(kit.read(p)["address"], P["address"])

if __name__ == "__main__":
    unittest.main()
