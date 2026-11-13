#!/usr/bin/env python3
"""KIT Cascade v2 ENTRY: local 3X-UI API routing bridge for clean installs.

Never changes Linux routing, firewall, SSH or the remotely installed EXIT.
Route setup runs inside the original KIT installer, after Xray core install
but BEFORE creating any client inbounds.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import re
import sqlite3
import shutil
import subprocess
import shlex
import socket
import ssl
import sys
import tempfile
import urllib.parse
import urllib.request

import hops

STATE_DIR = Path("/etc/kit-cascade/entry")
PEER_FILE = STATE_DIR / "next-hop.txt"
BACKUP = STATE_DIR / "xray-template-before.json"
STATE_FILE = STATE_DIR / "state.json"
DB_FILE = Path("/etc/x-ui/x-ui.db")
ENV_FILE = Path("/etc/x-ui/install-result.env")
OUTBOUND_TAG = "to-next-hop"


class EntryError(RuntimeError):
    pass


def secure_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    fd, tmp = tempfile.mkstemp(prefix=".kit-cascade-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_link(path=PEER_FILE):
    f = Path(path)
    if not f.is_file():
        raise EntryError("Нет файла VLESS-ссылки следующего узла: " + str(f))
    if f.stat().st_mode & 0o077:
        raise EntryError("Файл VLESS-ссылки доступен другим пользователям; нужны права 0600")
    return hops.parse_link(f.read_text(encoding="utf-8").strip())


def check_exit_connectivity(peer, timeout=8):
    endpoint = (peer["address"], peer["port"], 0, 0)
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(endpoint)
    except OSError as exc:
        raise EntryError(
            "TCP-соединение с EXIT по IPv6 недоступно; проверьте TCP-порт "
            f'{peer["port"]} в сетевом файрволе EXIT: {exc}'
        ) from exc


def panel_env(path=ENV_FILE):
    # Read only the three scalar values produced by the official installer.
    # Never source a shell file or execute its contents.
    values = {}
    if not Path(path).is_file():
        raise EntryError("Отсутствует /etc/x-ui/install-result.env")
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        match = re.fullmatch(r"(XUI_API_TOKEN|XUI_PANEL_PORT|XUI_WEB_BASE_PATH)=(.*)", line)
        if not match:
            continue
        try:
            tokens = shlex.split(match.group(2), posix=True)
        except ValueError as exc:
            raise EntryError("Неверный формат переменной панели") from exc
        if len(tokens) != 1:
            raise EntryError("Неверная переменная панели: " + match.group(1))
        values[match.group(1)] = tokens[0]
    token = values.get("XUI_API_TOKEN")
    port = values.get("XUI_PANEL_PORT", "")
    base = values.get("XUI_WEB_BASE_PATH", "").strip("/")
    if not token or not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise EntryError("Не найдены данные API панели 3X-UI")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", base):
        raise EntryError("Неверный webBasePath панели")
    return token, int(port), base


class Panel:
    """3X-UI v3.9.0 local API, authenticated with saved bearer token."""

    def __init__(self, env_file=ENV_FILE):
        token, port, base = panel_env(env_file)
        self.token = token
        self.urls = [
            f"https://127.0.0.1:{port}/{base}/panel/api/",
            f"http://127.0.0.1:{port}/{base}/panel/api/",
        ]
        self.selected = None

    def call(self, endpoint, params=None):
        if not re.fullmatch(r"[A-Za-z0-9_/-]{1,80}", endpoint):
            raise EntryError("Недопустимый API endpoint")
        body = urllib.parse.urlencode(params or {}).encode("utf-8")
        errors = []
        urls = [self.selected] if self.selected else self.urls
        for base in urls:
            request = urllib.request.Request(
                base + endpoint, data=body, method="POST",
                headers={
                    "Authorization": "Bearer " + self.token,
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
            try:
                ctx = ssl._create_unverified_context() if base.startswith("https:") else None
                with urllib.request.urlopen(request, timeout=45, context=ctx) as response:
                    reply = json.load(response)
                if not isinstance(reply, dict) or reply.get("success") is not True:
                    raise EntryError(
                        "3X-UI отклонила " + endpoint + ": "
                        + str(reply.get("msg") if isinstance(reply, dict) else "invalid reply")
                    )
                self.selected = base
                return reply.get("obj")
            except (OSError, ValueError) as exc:
                errors.append(type(exc).__name__ + ": " + str(exc)[:180])
        raise EntryError("Локальный API 3X-UI недоступен: " + "; ".join(errors))

    def get_template(self):
        obj = self.call("xray/")
        if not isinstance(obj, dict) or "xraySetting" not in obj:
            raise EntryError("Неожиданный ответ API: xraySetting отсутствует")
        setting = obj["xraySetting"]
        if isinstance(setting, str):
            try:
                setting = json.loads(setting)
            except ValueError as exc:
                raise EntryError("Неверный JSON конфигурации 3X-UI") from exc
        if not isinstance(setting, dict):
            raise EntryError("3X-UI вернула не объект Xray")
        return setting

    def put_template(self, template):
        self.call("xray/update", {
            "xraySetting": json.dumps(template, separators=(",", ":"), ensure_ascii=False)
        })

    def test_outbound(self, outbound):
        probe = self.call("xray/testOutbound", {
            "outbound": json.dumps(outbound, separators=(",", ":")),
            "mode": "real",
        })
        if isinstance(probe, str):
            probe = json.loads(probe)
        if not isinstance(probe, dict) or probe.get("success") is not True:
            raise EntryError(
                "REALITY до EXIT не прошёл HTTP-проверку панели: "
                + str(probe.get("error") if isinstance(probe, dict) else probe)
            )
        return probe


def outbound_to_exit(peer):
    # 3X-UI KIT ships an older Xray core than standalone EXIT.
    # Current Xray also understands these legacy TCP/REALITY aliases.
    value = hops.outbound(peer)
    value["tag"] = OUTBOUND_TAG
    value["streamSettings"]["network"] = "tcp"
    reality = value["streamSettings"]["realitySettings"]
    reality["publicKey"] = reality.pop("password")
    return value


def is_api_rule(rule):
    if not isinstance(rule, dict) or rule.get("outboundTag") != "api":
        return False
    tags = rule.get("inboundTag", [])
    if isinstance(tags, str):
        tags = [tags]
    return isinstance(tags, list) and "api" in tags


def merge_template(original, peer):
    """Every client TCP/UDP flow goes via EXIT; api remains local.

    The panel dynamically generates its own management and SOCKS inbounds,
    so this only modifies the persistent *template*, not database inbounds.
    """
    if not isinstance(original, dict):
        raise EntryError("Ожидался Xray-template object")
    if not isinstance(original.get("outbounds"), list):
        raise EntryError("Xray-template должен содержать outbounds[]")
    if not all(isinstance(x, dict) and isinstance(x.get("tag"), str)
               for x in original["outbounds"]):
        raise EntryError("Некорректные outbounds[]")
    cfg = copy.deepcopy(original)
    candidate = outbound_to_exit(peer)
    rest = [out for out in cfg["outbounds"] if out.get("tag") != OUTBOUND_TAG]
    # Preserve original internal API outbound and other panel definitions.
    cfg["outbounds"] = [candidate] + rest
    routing = cfg.setdefault("routing", {})
    if not isinstance(routing, dict):
        raise EntryError("Некорректный routing")
    original_rules = routing.get("rules", [])
    if not isinstance(original_rules, list):
        raise EntryError("Некорректный routing.rules")
    if not all(isinstance(rule, dict) for rule in original_rules):
        raise EntryError("Некорректный элемент routing.rules")
    api_rules = [rule for rule in original_rules if is_api_rule(rule)]
    if not api_rules and any(x.get("tag") == "api" for x in rest):
        api_rules = [{
            "type": "field", "inboundTag": ["api"], "outboundTag": "api"
        }]
    forced = {
        "type": "field", "network": "tcp,udp", "outboundTag": OUTBOUND_TAG
    }
    # Keep other existing rules for panel UI, but they must never take
    # precedence over the forced route, including geoip direct/bypass.
    routing["rules"] = api_rules + [forced] + [
        rule for rule in original_rules if not is_api_rule(rule)
        and rule != forced
    ]
    routing["domainStrategy"] = "AsIs"
    return cfg


def assert_cascade_template(cfg):
    """Fail if another Xray routing rule could bypass EXIT before catch-all."""
    if not isinstance(cfg, dict):
        raise EntryError("Не объект Xray template")
    obs = cfg.get("outbounds")
    if (not isinstance(obs, list) or not obs or
            obs[0].get("tag") != OUTBOUND_TAG or
            obs[0].get("protocol") != "vless"):
        raise EntryError("Первый outbound не является VLESS каскадом")
    routing = cfg.get("routing")
    rules = routing.get("rules") if isinstance(routing, dict) else None
    if not isinstance(rules, list):
        raise EntryError("Нет правил маршрутизации Xray")
    index = 0
    while index < len(rules) and is_api_rule(rules[index]):
        index += 1
    expected = {
        "type": "field", "network": "tcp,udp", "outboundTag": OUTBOUND_TAG
    }
    if index >= len(rules) or rules[index] != expected:
        raise EntryError(
            "После служебного API нет обязательного правила TCP/UDP -> EXIT"
        )
    if any(is_api_rule(rule) for rule in rules[index + 1:]):
        raise EntryError("API-правила расположены после каскадного маршрута")




def apply(link_file):
    if os.geteuid() != 0:
        raise EntryError("Нужен root")
    peer = load_link(link_file)
    check_exit_connectivity(peer)
    panel = Panel()
    original = panel.get_template()
    changed = merge_template(original, peer)
    if not BACKUP.exists():
        secure_write(BACKUP, hops.format_plan(original))
    # Never silently overwrite first backup on repeated/partial installer run.
    try:
        panel.test_outbound(changed["outbounds"][0])
        panel.put_template(changed)
        confirmed = panel.get_template()
        assert_cascade_template(confirmed)
    except Exception:
        # Do NOT restore direct as clients may already exist on reruns.
        raise
    secure_write(STATE_FILE, hops.format_plan({
        "schema": 1, "role": "entry", "mode": "cascade",
        "next": f'[{peer["address"]}]:{peer["port"]}',
        "outboundTag": OUTBOUND_TAG, "status": "configured",
    }))
    print("CASCADE: Xray template направляет TCP/UDP через EXIT, API сохранён локально.")
    print("CASCADE: REALITY outbound прошёл реальную HTTP-проверку.")


def mark_complete():
    if not STATE_FILE.is_file():
        raise EntryError("Конфигурация ENTRY ещё не создана")
    state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    panel = Panel()
    template = panel.get_template()
    assert_cascade_template(template)
    panel.test_outbound(template["outbounds"][0])
    state["status"] = "installed"
    secure_write(STATE_FILE, hops.format_plan(state))


def status():
    if not STATE_FILE.is_file():
        print("ENTRY: не настроен")
        return
    state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    print("ENTRY:", state["status"], "→ EXIT", state.get("next", "(отключён)"))
    if state["status"] == "restored-disabled":
        print("x-ui намеренно остановлена после отката, доступ клиентов закрыт.")
        return
    panel = Panel()
    cfg = panel.get_template()
    print("Маршрут Xray:", cfg["outbounds"][0].get("tag"))
    assert_cascade_template(cfg)
    print("Учтите: системный Linux egress пока не заблокирован.")


def restore():
    """Fail-closed: stop and disable panel, then update its *offline* SQLite DB.

    Never call an API on a stopped service. The restored template must not be
    used until the administrator explicitly decides how to handle client inbounds.
    """
    if not BACKUP.is_file():
        raise EntryError("Нет сохранённого Xray template для отката")
    database = DB_FILE
    if not database.is_file():
        raise EntryError("Не найдена стандартная SQLite база x-ui.db; откат запрещён")
    print("Откат остановит панель и отключит её автозапуск.")
    print("База будет сохранена, но клиентские подключения останутся выключенными.")
    while True:
        try:
            answer = input("Остановить x-ui и восстановить прежние маршруты? [y/N]: ").strip().lower()
        except EOFError as exc:
            raise EntryError("Терминал отключился во время подтверждения") from exc
        if answer in ("n", ""):
            print("Отменено без изменений.")
            return
        if answer == "y":
            break
        print("Введите y (да) или n (нет). Enter — нет.")
    subprocess.run(["systemctl", "stop", "x-ui"], check=True)
    subprocess.run(["systemctl", "disable", "x-ui"], check=True)
    old = json.loads(BACKUP.read_text(encoding="utf-8"))
    backup_db = STATE_DIR / "x-ui-before-restore.db"
    # SQLite online backup API copies a consistent database snapshot, even if
    # the source is WAL-mode. No raw copying of live DB/WAL sidecars.
    with sqlite3.connect(str(database)) as src, sqlite3.connect(str(backup_db)) as dst:
        src.backup(dst)
    os.chmod(backup_db, 0o600)
    with sqlite3.connect(str(database)) as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            'SELECT value FROM settings WHERE key = ?', ("xrayTemplateConfig",)
        ).fetchone()
        if row is None:
            conn.rollback()
            raise EntryError("В SQLite нет сохранённого xrayTemplateConfig; x-ui остановлена")
        conn.execute(
            'UPDATE settings SET value = ? WHERE key = ?',
            (hops.format_plan(old), "xrayTemplateConfig"),
        )
        conn.commit()
    state = {"schema": 1, "role": "entry", "status": "restored-disabled"}
    secure_write(STATE_FILE, hops.format_plan(state))
    print("Исходный Xray template восстановлен офлайн.")
    print("x-ui остаётся ОСТАНОВЛЕННОЙ и отключена из автозапуска.")
    print("Снимок БД до отката:", backup_db)


def main(argv=None):
    parser = argparse.ArgumentParser(description="KIT-Cascade ENTRY integration")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("apply")
    p.add_argument("--link-file", default=str(PEER_FILE))
    sub.add_parser("finish")
    sub.add_parser("status")
    sub.add_parser("restore")
    a = parser.parse_args(argv)
    try:
        if a.command in {"apply", "finish", "restore"} and os.geteuid() != 0:
            raise EntryError("Нужен root")
        if a.command == "apply":
            apply(a.link_file)
        elif a.command == "finish":
            mark_complete()
        elif a.command == "status":
            status()
        elif a.command == "restore":
            restore()
    except (EntryError, hops.ChainError, OSError, KeyError, TypeError, ValueError) as exc:
        print("CASCADE ERROR:", exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
