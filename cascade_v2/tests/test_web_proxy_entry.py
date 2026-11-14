"""Tests for the WEB staging helper. No network or system changes."""
import json
import tempfile
import unittest
from pathlib import Path
from cascade_v2 import web_proxy_entry as web

SAMPLE = """# KIT example
stream {
    map_hash_bucket_size 512;
    map $ssl_preread_server_name $kit_upstream {
        example.org 127.0.0.1:10443;
        mt.example.org 127.0.0.1:10445;
        default 127.0.0.1:10446;
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass $kit_upstream;
        proxy_protocol on;
    }
    # KIT CASCADE MTProto direct 8445
    server {
        listen 8445;
        listen [::]:8445;
        proxy_pass 127.0.0.1:10445;
        proxy_protocol on;
    }
}
"""


class WebProxyStagingTests(unittest.TestCase):
    def test_render_preserves_existing_routes(self):
        rendered = web.render_stream(SAMPLE, "web.example.org", 18443)
        self.assertIn("web.example.org 127.0.0.1:18443;", rendered)
        for line in ("default 127.0.0.1:10446;",
                     "mt.example.org 127.0.0.1:10445;",
                     "listen 8445;", "proxy_pass $kit_upstream;"):
            self.assertIn(line, rendered)
        self.assertEqual(rendered.count("listen 443;"), 1)

    def test_collision_and_duplicate_rejected(self):
        rendered = web.render_stream(SAMPLE, "web.example.org", 18443)
        with self.assertRaises(web.WebConfigError):
            web.render_stream(rendered, "web.example.org", 18443)
        for hostname in ("example.org", "mt.example.org", "WEB.example.org",
                         "127.0.0.1", "evil/host.org"):
            with self.subTest(hostname=hostname), self.assertRaises(web.WebConfigError):
                web.render_stream(SAMPLE, hostname, 18443)
        with self.assertRaises(web.WebConfigError):
            web.render_stream(SAMPLE, "web.example.org", 8445)

    def test_unknown_nginx_layout_fails_closed(self):
        with self.assertRaises(web.WebConfigError):
            web.render_stream("stream { server { listen 443; } }", "web.example.org", 18443)

    def test_stage_only_writes_new_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / "source.conf"
            conf.write_text(SAMPLE)
            state = root / "state.json"
            state.write_text(json.dumps({"role": "entry", "status": "installed"}))
            out = root / "candidate.conf"
            args = ["stage", "--host", "web.example.org", "--stream", str(conf),
                    "--state", str(state), "--output", str(out)]
            self.assertEqual(web.main(args), 0)
            self.assertEqual(conf.read_text(), SAMPLE)
            self.assertIn("web.example.org 127.0.0.1:18443;", out.read_text())
            self.assertEqual(web.main(args), 2)


if __name__ == "__main__":
    unittest.main()
