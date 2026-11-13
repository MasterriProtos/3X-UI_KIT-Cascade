"""Regression tests for existing KIT nginx files with ad hoc localhost MTProto ingress."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "mtproto_nginx.py"
spec = importlib.util.spec_from_file_location("mtproto_nginx", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BASE = """# generated
stream {
    map $ssl_preread_server_name $kit_upstream {
        vk.ru 127.0.0.1:10445;
        default 127.0.0.1:10446;
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass $kit_upstream;
        proxy_protocol on;
    }
}
"""

TEST_LOCAL = """    server {
        listen 127.0.0.1:24445;
        proxy_pass 127.0.0.1:10445;
        proxy_protocol on;
    }
"""

class MtprotoNginxTests(unittest.TestCase):
    def test_generated_stream(self):
        rendered = mod.render(BASE)
        self.assertEqual(rendered.count(mod.MARKER), 1)
        self.assertIn("listen 8445;", rendered)
        self.assertIn("listen [::]:8445;", rendered)
        self.assertIn("proxy_pass 127.0.0.1:10445;", rendered)
        self.assertIn("listen 443;", rendered)
        self.assertEqual(mod.render(rendered), rendered)

    def test_existing_temporary_local_server(self):
        changed = BASE.replace("    server {\n        listen 443;", TEST_LOCAL + "    server {\n        listen 443;")
        rendered = mod.render(changed)
        self.assertIn("listen 127.0.0.1:24445;", rendered)
        self.assertIn("listen 8445;", rendered)
        self.assertEqual(rendered.count(mod.MARKER), 1)

    def test_whitespace_variations(self):
        changed = BASE.replace("stream {", "stream  {").replace(
            "    server {\n        listen 443;", "  server {\n          listen 443;"
        )
        self.assertIn("listen 8445;", mod.render(changed))

    def test_reject_unknown_config(self):
        with self.assertRaisesRegex(mod.ConfigError, "listen 443"):
            mod.render(BASE.replace("listen 443;", "listen 9999;"))
        with self.assertRaisesRegex(mod.ConfigError, "10445"):
            mod.render(BASE.replace("127.0.0.1:10445;", "127.0.0.1:10447;"))
        with self.assertRaisesRegex(mod.ConfigError, "listen 8445"):
            mod.render(BASE.replace("listen 443;", "listen 8445;"))

    def test_cli_check_does_not_modify(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "kit-stream.conf"
            p.write_text(BASE)
            cp = subprocess.run(
                ["python3", str(SCRIPT), "check", str(p)],
                capture_output=True, text=True
            )
            self.assertEqual(cp.returncode, 0, cp.stderr)
            self.assertEqual(p.read_text(), BASE)
            ap = subprocess.run(
                ["python3", str(SCRIPT), "apply", str(p)],
                capture_output=True, text=True
            )
            self.assertEqual(ap.returncode, 0, ap.stderr)
            self.assertIn("listen 8445;", p.read_text())

if __name__ == "__main__":
    unittest.main()
