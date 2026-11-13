"""ENTRY routing and restore safety tests (no network or installed 3X-UI)."""
from pathlib import Path
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hops
import entry
import install

NODE = {
    "address": "2606:4700:4700::1111",
    "port": 443,
    "id": "8e1f4d93-6f8f-4e36-aea5-94b309de42e1",
    "serverName": "www.example.com",
    "publicKey": "A" * 43,
    "shortId": "0123456789abcdef",
}


def original():
    return {
        "inbounds": [{"tag": "api", "listen": "127.0.0.1", "port": 62789,
                      "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}],
        "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {}},
                      {"tag": "api", "protocol": "freedom", "settings": {}},
                      {"tag": "blocked", "protocol": "blackhole", "settings": {}}],
        "routing": {
            "rules": [
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
                {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
                {"type": "field", "domain": ["geosite:ru"], "outboundTag": "direct"}
            ]
        },
    }


class EntryTests(unittest.TestCase):
    def test_reality_outbound_legacy_aliases(self):
        val = entry.outbound_to_exit(NODE)
        self.assertEqual(val["streamSettings"]["network"], "tcp")
        self.assertEqual(val["tag"], "to-next-hop")
        reality = val["streamSettings"]["realitySettings"]
        self.assertEqual(reality["publicKey"], NODE["publicKey"])
        self.assertNotIn("password", reality)

    def test_rule_priority_and_default(self):
        cfg = entry.merge_template(original(), NODE)
        self.assertEqual(cfg["outbounds"][0]["tag"], "to-next-hop")
        self.assertEqual([r["outboundTag"] for r in cfg["routing"]["rules"]],
                         ["api", "to-next-hop", "blocked", "direct"])
        self.assertEqual(cfg["routing"]["rules"][1]["network"], "tcp,udp")
        self.assertEqual(cfg["routing"]["domainStrategy"], "AsIs")

    def test_idempotent_and_not_mutating_original(self):
        start = original()
        x = entry.merge_template(start, NODE)
        self.assertEqual(x, entry.merge_template(x, NODE))
        self.assertEqual(start["outbounds"][0]["tag"], "direct")

    def test_no_management_rule_when_no_api(self):
        cfg = entry.merge_template({"outbounds": [
            {"tag": "direct", "protocol": "freedom"}]}, NODE)
        self.assertEqual(cfg["routing"]["rules"][0]["outboundTag"], "to-next-hop")

    def test_invalid_template_rejected(self):
        for cfg in ({}, {"outbounds": {}}, {"outbounds": [], "routing": []},
                    {"outbounds": [{"tag": 123}]}):
            with self.assertRaises(entry.EntryError):
                entry.merge_template(cfg, NODE)

    def test_link_not_logged_or_exposed(self):
        text = entry.hops.link(NODE)
        self.assertNotIn("privateKey", text)
        merged = entry.merge_template(original(), NODE)
        self.assertNotIn("privateKey", json.dumps(merged))

    def test_panel_env_is_parsed_not_executed(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / "install-result.env"
            file.write_text(
                "XUI_API_TOKEN='secret-token-test'\n"
                "XUI_PANEL_PORT=12345\n"
                "XUI_WEB_BASE_PATH='/secretweb/'\n"
                "IGNORED=$(touch /tmp/should-never-be-created)\n"
            )
            self.assertEqual(entry.panel_env(file),
                             ("secret-token-test", 12345, "secretweb"))

    def test_load_link_requires_0600(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d) / "next-hop.txt"
            file.write_text(hops.link(NODE))
            file.chmod(0o644)
            with self.assertRaises(entry.EntryError):
                entry.load_link(file)
            file.chmod(0o600)
            self.assertEqual(entry.load_link(file)["address"], NODE["address"])

    def test_failed_probe_prevents_panel_update(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(
            entry, "BACKUP", Path(d) / "backup.json"
        ), mock.patch.object(entry, "STATE_FILE", Path(d) / "state.json"
        ), mock.patch.object(entry, "load_link", return_value=NODE
        ), mock.patch.object(entry, "check_exit_connectivity"
        ), mock.patch.object(entry, "Panel") as panel, mock.patch.object(
            entry.os, "geteuid", return_value=0
        ):
            panel.return_value.get_template.return_value = original()
            panel.return_value.test_outbound.side_effect = entry.EntryError("probe fail")
            with self.assertRaises(entry.EntryError):
                entry.apply("/secret/file")
            panel.return_value.put_template.assert_not_called()
            self.assertFalse(entry.STATE_FILE.exists())

    def test_restore_stops_before_sqlite_change(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            db = folder / "x-ui.db"
            backup = folder / "original.json"
            state = folder / "state.json"
            with sqlite3.connect(db) as sql:
                sql.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
                sql.execute("INSERT INTO settings (key,value) VALUES (?,?)",
                            ("xrayTemplateConfig", json.dumps({"outbounds": [{"tag": "to-next-hop"}]})))
                sql.commit()
            backup.write_text(hops.format_plan(original()))
            calls = []
            def fake_run(args, **kwargs):
                calls.append(args[:])
                return subprocess.CompletedProcess(args, 0)

            with mock.patch.multiple(
                entry, BACKUP=backup, DB_FILE=db,
                STATE_DIR=folder, STATE_FILE=state
            ), mock.patch("builtins.input", return_value="ОТКАТ"), \
                mock.patch.object(entry.subprocess, "run", side_effect=fake_run):
                entry.restore()
                self.assertEqual(calls[0], ["systemctl", "stop", "x-ui"])
                self.assertEqual(calls[1], ["systemctl", "disable", "x-ui"])
                with sqlite3.connect(db) as sql:
                    saved = sql.execute("SELECT value FROM settings WHERE key=?",
                                        ("xrayTemplateConfig",)).fetchone()[0]
                self.assertEqual(json.loads(saved), original())
                self.assertEqual(json.loads(state.read_text())["status"],
                                 "restored-disabled")
                self.assertTrue((folder / "x-ui-before-restore.db").exists())

    def test_cli_exposes_entry_role(self):
        with mock.patch.object(install, "require_environment"
        ), mock.patch.object(install, "install") as wrapped:
            self.assertEqual(install.main(["install", "--role", "entry"]), 0)
            self.assertEqual(wrapped.call_args.args[0].role, "entry")


    def test_original_kit_hook_precedes_all_client_inbounds(self):
        source = (Path(__file__).resolve().parents[2] /
                  "scripts" / "3x-ui.sh").read_text(encoding="utf-8")
        self.assertIn('python3 "$cascade_path" apply', source)
        self.assertIn('routeThroughXray', source)
        self.assertIn('routeXrayPort', source)
        self.assertLess(source.index('python3 "$cascade_path" apply'),
                        source.index('for p in "${PROTOS[@]}"; do "proto_$p"; done'))
        self.assertIn('[[ -z ${KIT_CASCADE_NEXT_LINK_FILE:-} ]] && ! telegram_reachable',
                      source)

    def test_kit_disables_upstream_update_in_cascade(self):
        source = (Path(__file__).resolve().parents[2] /
                  "scripts" / "kit.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ ${1:-} == update ]]', source)
        self.assertIn("KIT-Cascade alpha", source)


    def test_entry_refuses_existing_exit_xray_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            existing = Path(folder) / "xray"
            existing.write_bytes(b"already installed")
            with mock.patch.object(install, "XRAY", existing), \
                 mock.patch.object(install.Path, "exists",
                                   lambda path: str(path) == str(existing)):
                with self.assertRaises(install.InstallError):
                    install.install_entry()



    def test_route_validation_rejects_direct_precedence(self):
        cfg = entry.merge_template(original(), NODE)
        entry.assert_cascade_template(cfg)
        bypass = json.loads(json.dumps(cfg))
        bypass["routing"]["rules"].insert(1, {
            "type": "field", "domain": ["geosite:ru"],
            "outboundTag": "direct"
        })
        with self.assertRaises(entry.EntryError):
            entry.assert_cascade_template(bypass)

    def test_mark_complete_requires_actual_saved_route_and_probe(self):
        with tempfile.TemporaryDirectory() as d:
            state = Path(d) / "state.json"
            state.write_text(json.dumps({"schema": 1, "role": "entry",
                                         "status": "configured"}))
            cfg = entry.merge_template(original(), NODE)
            with mock.patch.object(entry, "STATE_FILE", state), \
                 mock.patch.object(entry, "Panel") as fake:
                fake.return_value.get_template.return_value = cfg
                fake.return_value.test_outbound.return_value = {"success": True}
                entry.mark_complete()
                self.assertEqual(json.loads(state.read_text())["status"], "installed")
                fake.return_value.test_outbound.assert_called_once()
                fake.return_value.get_template.return_value = original()
                with self.assertRaises(entry.EntryError):
                    entry.mark_complete()



    def test_early_sni_failure_can_retry_with_saved_link(self):
        with tempfile.TemporaryDirectory() as d:
            linkfile = Path(d) / "next-hop.txt"
            linkfile.write_text(hops.link(NODE))
            linkfile.chmod(0o600)
            statefile = Path(d) / "state.json"
            # Fake clean VPS: only the preserved private VLESS link exists.
            with mock.patch.object(entry, "PEER_FILE", linkfile), \
                 mock.patch.object(entry, "STATE_FILE", statefile), \
                 mock.patch.object(install.Path, "exists",
                                   lambda p: str(p) == str(linkfile)), \
                 mock.patch.object(entry, "check_exit_connectivity"), \
                 mock.patch.object(install, "confirm", side_effect=[True, False]) as confirms, \
                 mock.patch.object(install.getpass, "getpass") as hidden:
                install.install_entry()
                self.assertEqual(confirms.call_count, 2)
                hidden.assert_not_called()
                self.assertTrue(linkfile.is_file())
                self.assertEqual(hops.parse_link(linkfile.read_text())["address"], NODE["address"])

    def test_duplicate_sni_prompts_again_instead_of_exiting(self):
        script = (Path(__file__).resolve().parents[2] / "scripts" / "3x-ui.sh"
                  ).read_text(encoding="utf-8")
        chunk = script[script.index('for mask_choice in xhttp mtproto; do'):
                       script.index('  step "Пакеты"')]
        self.assertIn("while true; do", chunk)
        self.assertIn('warn "Сайт $mask_value уже занят REALITY', chunk)
        self.assertIn("continue", chunk)
        self.assertNotIn('|| die "Для XHTTP нужен отдельный SNI', chunk)


if __name__ == "__main__":
    unittest.main()
