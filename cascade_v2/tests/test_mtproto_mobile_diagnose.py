"""Unit checks for packet metadata-only mobile diagnosis."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "mtproto-mobile-diagnose.py"
spec = importlib.util.spec_from_file_location("mtproto_mobile_diagnose", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class MobileIngressTests(unittest.TestCase):
    def test_ipv4_syn_to_server(self):
        data = mod.parse_packet(
            "12345.0 IP 198.51.100.10.49282 > 203.0.113.20.8445: Flags [S], seq 1, win 1, length 0",
            8445
        )
        self.assertEqual(data, ("incoming", "S", 0))

    def test_ipv6_syn_ack_from_server(self):
        data = mod.parse_packet(
            "12345.0 IP6 2001:db8::1.8445 > 2001:db8::2.50322: Flags [S.], seq 1, ack 1, length 0",
            8445
        )
        self.assertEqual(data, ("outgoing", "S.", 0))

    def test_payload_and_other_ports(self):
        self.assertEqual(
            mod.parse_packet(
                "12345 IP 198.51.100.10.50322 > 203.0.113.20.8445: Flags [P.], seq 1, length 128",
                8445),
            ("incoming", "P.", 128)
        )
        self.assertIsNone(mod.parse_packet(
            "12345 IP 198.51.100.10.50322 > 203.0.113.20.443: Flags [S], length 0", 8445
        ))

    def test_unrecognised_line(self):
        self.assertIsNone(mod.parse_packet("tcpdump: listening on any", 8445))


if __name__ == "__main__":
    unittest.main()
