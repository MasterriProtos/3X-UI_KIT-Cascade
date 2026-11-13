#!/usr/bin/env python3
"""3X-UI KIT Cascade: experimental sidecar for Xray entry -> IPv6 VLESS exit.
Does not modify Linux routes, firewalls or original KIT install.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid

STATE = Path("/etc/kit-cascade")
TAG = "kit-to-exit"

class Error(Exception):
    pass

def j(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"

def read(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise Error(f"Cannot read JSON {path}: {exc}") from exc

def save(path, data):
    dest = Path(path)
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cascade-", dir=dest.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def cmd(args):
    try:
        return subprocess.run(args, text=True, capture_output=True, check=True, timeout=50).stdout
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise Error(f"Failed {args[0]}: {str(exc)[-400:]}") from exc

def xray():
    for p in ("/usr/local/bin/xray", "/usr/bin/xray"):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    raise Error("Official Xray-core is required on B")

def check_ipv6(ip):
    try:
        addr = ipaddress.IPv6Address(ip)
    except ipaddress.AddressValueError as exc:
        raise Error("Expected numeric IPv6 of B") from exc
    if not addr.is_global:
        raise Error("IPv6 of B must be a globally routable public address")
    return str(addr)

def check_sni(sni):
    if not 3 <= len(sni) <= 253 or "." not in sni or not all(
        re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
        for part in sni.split(".")
    ):
        raise Error("SNI must be a hostname without https://")
    return sni

def peer(ip, port, client_id, public, short_id, sni):
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise Error("Invalid port")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}){1,16}", short_id):
        raise Error("Invalid short ID")
    if not public or not isinstance(public, str):
        raise Error("Missing publicKey")
    return {"address": check_ipv6(ip), "port": port, "id": str(uuid.UUID(client_id)),
            "publicKey": public, "shortId": short_id, "serverName": check_sni(sni)}

def config_exit(p, private):
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "cascade-from-entry", "listen": p["address"], "port": p["port"],
            "protocol": "vless",
            "settings": {"clients": [{"id": p["id"], "flow": "xtls-rprx-vision"}],
                         "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "reality",
                "realitySettings": {"show": False, "dest": p["serverName"] + ":443",
                    "serverNames": [p["serverName"]], "privateKey": private,
                    "shortIds": [p["shortId"]]}}
        }],
        "outbounds": [{"tag": "internet", "protocol": "freedom", "settings": {}},
                      {"tag": "block", "protocol": "blackhole", "settings": {}}]
    }

def outbound_entry(p):
    p = peer(p["address"], p["port"], p["id"], p["publicKey"], p["shortId"], p["serverName"])
    return {"tag": TAG, "protocol": "vless",
            "settings": {"address": p["address"], "port": p["port"],
                         "id": p["id"], "encryption": "none", "flow": "xtls-rprx-vision"},
            "streamSettings": {"network": "tcp", "security": "reality",
                "realitySettings": {"fingerprint": "chrome",
                    "serverName": p["serverName"], "publicKey": p["publicKey"],
                    "shortId": p["shortId"], "spiderX": "/"}}}

def merge_entry(old, p):
    if not isinstance(old, dict) or not isinstance(old.get("outbounds"), list):
        raise Error("Panel template must contain outbounds list")
    config = copy.deepcopy(old)
    first = outbound_entry(p)
    rest = [x for x in config["outbounds"] if x.get("tag") != TAG]
    config["outbounds"] = [first] + rest
    ins = config.setdefault("inbounds", [])
    if not isinstance(ins, list):
        raise Error("Invalid inbounds list")
    if not any(x.get("tag") == "cascade-local-http" for x in ins):
        if any(x.get("port") == 18080 for x in ins):
            raise Error("Port 18080 already used by a different inbound")
        ins.append({"tag": "cascade-local-http", "listen": "127.0.0.1",
                    "port": 18080, "protocol": "http", "settings": {"timeout": 30}})
    routing = config.setdefault("routing", {})
    rules = routing.get("rules", [])
    if not isinstance(rules, list):
        raise Error("Invalid routing rules")
    api = [r for r in rules if isinstance(r, dict) and r.get("outboundTag") == "api"
           and "api" in r.get("inboundTag", [])]
    if not api and any(x.get("tag") == "api" for x in rest):
        api = [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]
    force = {"type": "field", "network": "tcp,udp", "outboundTag": TAG}
    routing["rules"] = api + [force] + [r for r in rules if r not in api and r != force]
    return config

class Panel:
    """Authenticated local-only 3X-UI API; never connects to remote host."""
    def __init__(self):
        token = os.getenv("XUI_API_TOKEN", "")
        port = os.getenv("XUI_PANEL_PORT", "")
        base = os.getenv("XUI_WEB_BASE_PATH", "").strip("/")
        if not token or not port.isdecimal() or not base:
            raise Error("Missing XUI_* env from /etc/x-ui/install-result.env")
        self.token = token
        self.urls = [f"https://127.0.0.1:{port}/{base}/panel/api",
                     f"http://127.0.0.1:{port}/{base}/panel/api"]
        self.selected = None

    def call(self, resource, form=None):
        body = b"" if form is None else urllib.parse.urlencode(form).encode()
        errors = []
        for url in ([self.selected] if self.selected else self.urls):
            request = urllib.request.Request(url + "/" + resource, data=body,
                method="POST", headers={"Authorization": "Bearer " + self.token,
                                       "Content-Type": "application/x-www-form-urlencoded"})
            try:
                context = ssl._create_unverified_context() if url.startswith("https:") else None
                with urllib.request.urlopen(request, context=context, timeout=12) as response:
                    result = json.load(response)
                if result.get("success") is not True:
                    raise Error("Panel rejected " + resource + ": " + str(result.get("msg")))
                self.selected = url
                return result.get("obj")
            except (OSError, ValueError) as exc:
                errors.append(str(exc))
        raise Error("Local panel API unavailable: " + "; ".join(errors))

    def get(self):
        value = self.call("xray/")
        if isinstance(value, str):
            value = json.loads(value)
        if not isinstance(value, dict) or "xraySetting" not in value:
            raise Error("Unexpected API response for xray/")
        settings = value["xraySetting"]
        return json.loads(settings) if isinstance(settings, str) else settings

    def put(self, cfg):
        self.call("xray/update", {"xraySetting": json.dumps(cfg, separators=(",", ":"))})

def exit_init(a):
    destination = Path(a.directory)
    if (destination / "exit-config.json").exists() or (destination / "peer.json").exists():
        raise Error("Refusing to overwrite existing credentials")
    lines = cmd([xray(), "x25519"])
    m = dict(re.findall(r"(?im)^([A-Za-z ]+):[ \t]*(\S+)$", lines))
    private = m.get("PrivateKey") or m.get("Private key")
    public = m.get("Password") or m.get("PublicKey") or m.get("Public key")
    if not private or not public:
        raise Error("Could not parse xray x25519 key pair")
    p = peer(a.ipv6, a.port, str(uuid.uuid4()), public, secrets.token_hex(8), a.sni)
    save(destination / "exit-config.json", j(config_exit(p, private)))
    save(destination / "peer.json", j(p))
    print("Created exit config and peer.json; keep private key on B, never commit secrets")

def exit_apply(a):
    src, dst = Path(a.config), Path(a.destination)
    cfg = read(src)
    if cfg.get("inbounds", [{}])[0].get("tag") != "cascade-from-entry":
        raise Error("Refusing to install non-cascade configuration")
    cmd([xray(), "run", "-test", "-config", str(src)])
    if not a.yes:
        print("Configuration validated. Dry run; add --yes to install.")
        return
    backup = None
    if dst.exists():
        backup = dst.with_name(dst.name + ".bak-" +
            datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
        save(backup, dst.read_text(encoding="utf-8"))
    save(dst, j(cfg))
    try:
        cmd([xray(), "run", "-test", "-config", str(dst)])
        if a.restart:
            cmd(["systemctl", "restart", "xray"])
            cmd(["systemctl", "is-active", "--quiet", "xray"])
    except Error:
        if backup:
            save(dst, backup.read_text(encoding="utf-8"))
            if a.restart:
                try:
                    cmd(["systemctl", "restart", "xray"])
                except Error:
                    pass
        raise
    print("Exit config installed; backup:", backup, "restarted:", a.restart)

def entry_plan(a):
    old = read(a.template) if a.template else Panel().get()
    merged = merge_entry(old, read(a.peer))
    if a.output:
        save(a.output, j(merged))
        print("Preview saved:", a.output)
    else:
        print("Dry run: first outbound", merged["outbounds"][0]["tag"],
              "; mandatory TCP/UDP routing via B; no system firewall changes.")

def entry_apply(a):
    if not a.yes:
        print("Dry run. Entry changes require --yes.")
        return
    panel = Panel()
    old = panel.get()
    changed = merge_entry(old, read(a.peer))
    backup = STATE / "backups" / ("xray-" + secrets.token_hex(8) + ".json")
    save(backup, j(old))
    print("Backed up panel Xray template:", backup)
    try:
        panel.put(changed)
        if panel.get()["outbounds"][0].get("tag") != TAG:
            raise Error("Panel did not persist outbound")
    except Exception:
        panel.put(old)
        raise
    print("Panel updated. Test proxy and client connections before continuing.")

def entry_restore(a):
    if not a.yes:
        raise Error("Restoration requires --yes")
    panel = Panel()
    current = panel.get()
    backup = STATE / "backups" / ("before-restore-" + secrets.token_hex(8) + ".json")
    save(backup, j(current))
    panel.put(read(a.backup))
    print("Restored; previous state saved to", backup)

def firewall_plan(a):
    p = read(a.peer)
    ip, port = check_ipv6(p["address"]), p["port"]
    draft = f"""# NOT APPLIED. Review SSH, DHCPv6, RA, UFW, FORWARD and recovery console.
table inet kit_cascade_egress {{
 chain output {{
  type filter hook output priority -50; policy drop;
  oifname "lo" accept
  ct direction reply ct state established,related accept
  ip6 daddr {ip} tcp dport {port} accept
  ip6 daddr {{ fe80::/10, ff02::/16 }} icmpv6 type {{
    nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit,
    nd-router-advert
  }} accept
  counter drop
 }}
}}
"""
    if a.output:
        save(a.output, draft)
        print("Firewall DRAFT saved, NOT applied:", a.output)
    else:
        print(draft)

def probe(a):
    proxy = "http://127.0.0.1:18080"
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    with opener.open("https://api.ipify.org", timeout=15) as response:
        print("IP through local Xray proxy:", response.read(100).decode().strip())

def main(argv=None):
    parser = argparse.ArgumentParser(description="Experimental 3X-UI KIT Cascade")
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("exit-init")
    p.add_argument("--ipv6", required=True); p.add_argument("--sni", required=True)
    p.add_argument("--port", type=int, default=24443)
    p.add_argument("--directory", default=str(STATE / "exit"))
    p.set_defaults(func=exit_init)
    p = sub.add_parser("exit-apply")
    p.add_argument("--config", default=str(STATE / "exit/exit-config.json"))
    p.add_argument("--destination", default="/usr/local/etc/xray/config.json")
    p.add_argument("--yes", action="store_true"); p.add_argument("--restart", action="store_true")
    p.set_defaults(func=exit_apply)
    p = sub.add_parser("entry-plan")
    p.add_argument("--peer", default=str(STATE / "peer.json"))
    p.add_argument("--template"); p.add_argument("--output")
    p.set_defaults(func=entry_plan)
    p = sub.add_parser("entry-apply")
    p.add_argument("--peer", default=str(STATE / "peer.json"))
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=entry_apply)
    p = sub.add_parser("entry-restore")
    p.add_argument("--backup", required=True); p.add_argument("--yes", action="store_true")
    p.set_defaults(func=entry_restore)
    p = sub.add_parser("firewall-plan")
    p.add_argument("--peer", default=str(STATE / "peer.json")); p.add_argument("--output")
    p.set_defaults(func=firewall_plan)
    sub.add_parser("probe").set_defaults(func=probe)
    args = parser.parse_args(argv)
    try:
        if args.action in ("exit-init", "exit-apply", "entry-apply", "entry-restore") and os.geteuid() != 0:
            raise Error("Write operations require sudo")
        args.func(args)
    except (Error, OSError, KeyError, TypeError, ValueError) as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
