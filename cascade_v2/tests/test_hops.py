"""Offline tests for VLESS chain generator. Run: python3 -m unittest discover -s cascade_v2/tests -v"""
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import hops

KEY="A"*43
UUID="9b6ca4b3-70b1-4e85-a4f5-fc37520b0c10"
IP="2606:4700:4700::1111"

class ChainTests(unittest.TestCase):
    def setUp(self):
        self.node={"address":IP,"port":24443,"id":UUID,"publicKey":KEY,
                   "privateKey":KEY,"shortId":"0123456789abcdef","serverName":"example.org"}
        self.url=hops.link(self.node)
    def test_link_roundtrip(self):
        self.assertEqual(hops.parse_link(self.url)["address"],IP)
    def test_no_secret_in_link(self):
        self.assertNotIn("privateKey",self.url)
    def test_exit_uses_internet(self):
        self.assertEqual(hops.node_config("exit",self.node)["outbounds"][0]["protocol"],"freedom")
    def test_relay_never_direct(self):
        config=hops.node_config("relay",self.node,self.url)
        self.assertEqual([x["tag"] for x in config["outbounds"]],["to-next-hop","block"])
    def test_relay_must_have_successor(self):
        with self.assertRaises(hops.ChainError):hops.node_config("relay",self.node)
    def test_exit_must_not_have_successor(self):
        with self.assertRaises(hops.ChainError):hops.node_config("exit",self.node,self.url)
    def test_entry(self):
        self.assertEqual(hops.entry_plan(self.url)["outbound"]["tag"],"to-next-hop")
    def test_ipv4_rejected(self):
        with self.assertRaises(hops.ChainError):hops.parse_link(self.url.replace("["+IP+"]","1.2.3.4"))
    def test_linklocal_rejected(self):
        with self.assertRaises(hops.ChainError):hops.check_ip("fe80::1")
    def test_invalid_protocol_rejected(self):
        with self.assertRaises(hops.ChainError):hops.parse_link(self.url.replace("type=tcp","type=ws"))
    def test_duplicate_parameter_rejected(self):
        with self.assertRaises(hops.ChainError):hops.parse_link(self.url+"&sni=evil.org")
    def test_missing_key_rejected(self):
        with self.assertRaises(hops.ChainError):hops.parse_link(self.url.replace("pbk="+KEY,"pbk=bad"))

if __name__=="__main__":
    unittest.main()
