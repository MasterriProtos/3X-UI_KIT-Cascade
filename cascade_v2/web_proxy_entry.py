#!/usr/bin/env python3
"""Staging-only Telegram WEB entry helper. Does not enable services or edit nginx."""
from __future__ import annotations
import argparse
import ipaddress
import json
from pathlib import Path
import re
import sys

STREAM = Path("/etc/nginx/kit-stream.conf")
STATE = Path("/etc/kit-cascade/entry/state.json")


class WebConfigError(ValueError):
    pass


def validate_hostname(host: str) -> str:
    if not isinstance(host, str) or host != host.lower() or host.endswith(".") or len(host) > 253 or "." not in host:
        raise WebConfigError("Нужен FQDN в нижнем регистре без завершающей точки")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise WebConfigError("Нужен домен, а не IP")
    if not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", p) for p in host.split(".")):
        raise WebConfigError("Недопустимый DNS hostname; используйте ASCII/IDNA A-label")
    return host


def validate_port(port: int) -> int:
    if not 1025 <= port <= 65535 or port in (443, 8445, 10445, 10446, 10443, 47999):
        raise WebConfigError("Внутренний TLS-порт некорректен или зарезервирован KIT")
    return port


def render_stream(content: str, hostname: str, tls_port: int) -> str:
    """Add exactly one WEB SNI map entry; never alter 443/8445 or the default route."""
    host = validate_hostname(hostname)
    port = validate_port(tls_port)
    marker = f"# KIT WEB STAGED {host}"
    if marker in content:
        raise WebConfigError("WEB route already present; refusing duplicate")
    if content.count("map $ssl_preread_server_name $kit_upstream {") != 1:
        raise WebConfigError("KIT nginx SNI map not recognized (exact one required)")
    if not re.search(r"(?m)^\s*listen\s+443\s*;", content) or not re.search(
            r"(?m)^\s*proxy_pass\s+\$kit_upstream\s*;", content):
        raise WebConfigError("KIT stream 443 listener or upstream mapping missing")
    if not re.search(r"(?m)^\s*listen\s+(?:\[::\]:)?8445\s*;", content):
        raise WebConfigError("Existing MTProto 8445 listener missing; do not infer layout")
    found = re.search(r"(?m)^(?P<indent>\s*)map \$ssl_preread_server_name \$kit_upstream \{\s*\n(?P<body>(?:[^{}]*\n)*?)(?P=indent)\}", content)
    if not found:
        raise WebConfigError("Нестандартная SNI map: требуется ручная проверка")
    body = found.group("body")
    existing = re.findall(r"(?m)^\s*([^\s#;{}]+)\s+([^;{}]+);", body)
    if not any(k == "default" for k, _ in existing):
        raise WebConfigError("В SNI map нет default")
    if any(k.lower() == host for k, _ in existing):
        raise WebConfigError("WEB hostname уже используется другой маршрутизацией")
    if any(v.strip() == f"127.0.0.1:{port}" for _, v in existing):
        raise WebConfigError("Локальный порт уже используется SNI map")
    addition = f"{found.group('indent')}    {marker}\n{found.group('indent')}    {host} 127.0.0.1:{port};\n"
    match = re.search(r"(?m)^\s*default\s+[^;]+;\s*$", body)
    if not match:
        raise WebConfigError("Неоднозначная default-строка")
    newbody = body[:match.start()] + addition + body[match.start():]
    return content[:found.start("body")] + newbody + content[found.end("body"):]


def describe(host: str, port: int, src: Path, state: Path) -> dict:
    issues = []
    try:
        render_stream(src.read_text(encoding="utf-8"), host, port)
    except (OSError, WebConfigError) as exc:
        issues.append(f"nginx: {exc}")
    try:
        info = json.loads(state.read_text(encoding="utf-8"))
        if info.get("role") != "entry" or info.get("status") != "installed":
            issues.append("entry/state.json: ENTRY не отмечен как установленный")
    except (OSError, ValueError, TypeError):
        issues.append("entry/state.json: невозможно подтвердить состояние ENTRY")
    return {"host": host, "tls_loopback": f"127.0.0.1:{port}",
            "blocking_issues": issues, "enabled": False,
            "required_manual_gates": [
                "DNS A/AAAA -> ENTRY and trusted TLS certificate",
                "WEB relay and compatible inner MTProxy backend on loopback",
                "Proof WEB backend Telegram egress uses Xray -> to-next-hop -> EXIT",
                "Official Android WEB client successful mobile handshake",
                "nginx -t with candidate in isolated test environment"]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="KIT WEB: preflight/stage only, never activates")
    ap.add_argument("command", choices=("preflight", "stage"))
    ap.add_argument("--host", required=True)
    ap.add_argument("--tls-port", type=int, default=18443)
    ap.add_argument("--stream", type=Path, default=STREAM)
    ap.add_argument("--state", type=Path, default=STATE)
    ap.add_argument("--output", type=Path)
    args = ap.parse_args(argv)
    try:
        host = validate_hostname(args.host)
        port = validate_port(args.tls_port)
        report = describe(host, port, args.stream, args.state)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report["blocking_issues"]:
            return 2
        if args.command == "stage":
            if args.output is None:
                ap.error("--output обязателен для stage")
            target = args.output.resolve()
            if target == args.stream.resolve() or target == Path("/etc/nginx") or Path("/etc/nginx") in target.parents:
                raise WebConfigError("Нельзя сохранять stage-файл в /etc/nginx или поверх действующего конфига")
            if args.output.exists():
                raise WebConfigError("Файл вывода уже существует — не перезаписываю")
            candidate = render_stream(args.stream.read_text(encoding="utf-8"), host, port)
            args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with args.output.open("x", encoding="utf-8") as f:
                f.write(candidate)
            args.output.chmod(0o600)
            print("Подготовлен КАНДИДАТ nginx; НЕ активирован:", args.output)
        return 0
    except (OSError, WebConfigError) as exc:
        print(f"ОШИБКА: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
