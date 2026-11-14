"""Safe partial ENTRY resume tests. All databases, credentials and binaries are fake."""
from pathlib import Path
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install
import entry
import hops


NODE = {
    "address": "2606:4700:4700::1111",
    "port": 443,
    "id": "8e1f4d93-6f8f-4e36-aea5-94b309de42e1",
    "serverName": "www.example.com",
    "publicKey": "A" * 43,
    "shortId": "0123456789abcdef",
}


class EntryResumeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.edir = self.folder / "entry"
        self.edir.mkdir()
        self.peerfile = self.edir / "next-hop.txt"
        self.peerfile.write_text(hops.link(NODE))
        self.peerfile.chmod(0o600)
        self.dbfile = self.folder / "x-ui.db"
        with sqlite3.connect(self.dbfile) as db:
            db.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT)")
            db.commit()
        self.panel = self.folder / "x-ui"
        self.panel.write_text("fake binary")
        self.envfile = self.folder / "install-result.env"
        self.envfile.write_text("fake env")
        self.patches = [
            mock.patch.object(entry, "STATE_DIR", self.edir),
            mock.patch.object(entry, "STATE_FILE", self.edir / "state.json"),
            mock.patch.object(entry, "PEER_FILE", self.peerfile),
            mock.patch.object(entry, "ENV_FILE", self.envfile),
            mock.patch.object(entry, "DB_FILE", self.dbfile),
            mock.patch.object(install, "PANEL_BINARY", self.panel),
            mock.patch.object(install, "PANEL_RESULT", self.folder / "result"),
            mock.patch.object(install, "KIT_BINARY", self.folder / "kit"),
            mock.patch.object(install, "STATE_FILE", self.folder / "standalone-state"),
            mock.patch.object(install, "XRAY", self.folder / "standalone-xray"),
            mock.patch.object(install, "XRAY_UNIT", self.folder / "standalone.service"),
            mock.patch.object(entry, "Panel"),
            mock.patch.object(entry, "check_exit_connectivity"),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        entry.Panel.return_value.get_template.return_value = {
            "outbounds": [{"tag": "direct", "protocol": "freedom"}]
        }

    def test_can_resume_partial_with_zero_clients(self):
        root, script, peer = install.inspect_entry_resume()
        self.assertEqual(peer["address"], NODE["address"])
        self.assertTrue(script.name == "3x-ui.sh")
        self.assertTrue((root / "cascade_v2" / "entry.py").is_file())

    def test_continue_reuses_panel_and_asks_protocols_again(self):
        with mock.patch.object(install, "confirm", return_value=True), \
             mock.patch.object(install, "run_entry_kit_script") as run:
            install.resume_entry()
            run.assert_called_once()
            self.assertTrue(self.peerfile.is_file())

    def test_no_answer_does_not_restart_installer(self):
        with mock.patch.object(install, "confirm", return_value=False), \
             mock.patch.object(install, "run_entry_kit_script") as run:
            install.resume_entry()
            run.assert_not_called()

    def test_refuses_user_inbounds(self):
        with sqlite3.connect(self.dbfile) as db:
            db.execute("INSERT INTO inbounds (remark) VALUES ('Manual service')")
            db.commit()
        with self.assertRaisesRegex(install.InstallError, "inbounds"):
            install.inspect_entry_resume()

    def test_refuses_missing_or_finished_panel(self):
        self.panel.unlink()
        with self.assertRaisesRegex(install.InstallError, "не установлена"):
            install.inspect_entry_resume()
        self.panel.write_text("fake binary")
        install.PANEL_RESULT.write_text("finished")
        with self.assertRaisesRegex(install.InstallError, "уже завершил"):
            install.inspect_entry_resume()

    def test_refuses_backup_or_state(self):
        backup = self.edir / "xray-template-before.json"
        backup.write_text("{}")
        with self.assertRaisesRegex(install.InstallError, "резервные копии"):
            install.inspect_entry_resume()
        backup.unlink()
        entry.STATE_FILE.write_text("{}")
        with self.assertRaisesRegex(install.InstallError, "другие роли"):
            install.inspect_entry_resume()

    def test_refuses_unknown_outbound_without_state(self):
        entry.Panel.return_value.get_template.return_value = {
            "outbounds": [{"tag": entry.OUTBOUND_TAG, "protocol": "vless"}]
        }
        with self.assertRaisesRegex(install.InstallError, "уже есть"):
            install.inspect_entry_resume()


if __name__ == "__main__":
    unittest.main()
