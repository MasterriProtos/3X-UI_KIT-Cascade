#!/usr/bin/env python3
"""Read-only MTProto mobile ingress diagnostic. Never print client addresses or secrets.

Requires root, tcpdump, and a 4G/5G Telegram attempt during the capture window.
No packet files are written. Does not modify firewall, nginx, Xray, or MTProto.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import time

STATE = Path("/etc/kit-cascade/entry/state.json")
NGINX = Path("/etc/nginx/kit-stream.conf")
DEFAULT_PORT = 8445
LINE = re.compile(r"\b(?:IP|IP6)\s+(.+?)\s+>\s+(.+?):\s+Flags\s+\[([^]]*)\](.*)")
LENGTH = re.compile(r"\blength\s+(\d+)\b")


def endpoint_port(endpoint: str) -> int | None:
    """tcpdump prints IPv4/IPv6 TCP ports as the last dot-separated token."""
    match = re.search(r"\.(\d+)$", endpoint.strip())
    return int(match.group(1)) if match else None


def parse_packet(line: str, port: int) -> tuple[str, str, int] | None:
    """Return direction, TCP flags, payload length; discard all addresses."""
    match = LINE.search(line)
    if not match:
        return None
    source, dest, flags, rest = match.groups()
    src_port, dst_port = endpoint_port(source), endpoint_port(dest)
    if dst_port == port:
        direction = "incoming"
    elif src_port == port:
        direction = "outgoing"
    else:
        return None
    size = LENGTH.search(rest)
    return direction, flags, int(size.group(1)) if size else 0


def check_configuration(port: int) -> list[str]:
    findings = []
    try:
        state = json.loads(STATE.read_text(encoding="utf-8"))
        if state.get("role") != "entry" or state.get("status") != "installed":
            findings.append("ENTRY не отмечен как полностью установленный")
    except (OSError, ValueError, TypeError):
        findings.append("Не удалось подтвердить состояние установленного ENTRY")
    try:
        cfg = NGINX.read_text(encoding="utf-8")
        if "# KIT CASCADE MTProto direct 8445" not in cfg:
            findings.append("В nginx отсутствует маркер выделенного MTProto-порта")
        if not re.search(r"(?m)^\s*listen\s+" + str(port) + r"\s*;", cfg):
            findings.append("В nginx не найден TCP listener на выбранном порту")
        if not re.search(r"proxy_pass\s+127\.0\.0\.1:10445\s*;", cfg):
            findings.append("В nginx не найден upstream к локальному mtg:10445")
        if not re.search(r"(?m)^\s*proxy_protocol\s+on\s*;", cfg):
            findings.append("В nginx не найден PROXY protocol; проверьте настройки mtg")
    except OSError:
        findings.append("Не удалось прочитать конфигурацию nginx")
    for name, listen_port in (("публичный MTProto", port), ("локальный mtg", 10445)):
        try:
            p = subprocess.run(["ss", "-H", "-ltn", f"( sport = :{listen_port} )"],
                               capture_output=True, text=True, timeout=5, check=True)
            if not p.stdout.strip():
                findings.append(f"Нет TCP listener: {name}, порт {listen_port}")
        except (OSError, subprocess.SubprocessError):
            findings.append(f"Не удалось проверить listener: {name}")
    return findings


def observe(seconds: int, port: int) -> dict[str, int]:
    counters = {"incoming": 0, "outgoing": 0, "syn_in": 0,
                "synack_out": 0, "incoming_payload": 0, "outgoing_payload": 0}
    command = ["tcpdump", "-i", "any", "-n", "-l", "-tt",
               f"tcp port {port}"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    deadline = time.monotonic() + seconds
    try:
        assert process.stdout is not None
        while time.monotonic() < deadline:
            timeout = min(0.25, max(0.0, deadline - time.monotonic()))
            readable, _, _ = select.select([process.stdout], [], [], timeout)
            if not readable:
                if process.poll() is not None:
                    raise RuntimeError("tcpdump завершился до окончания наблюдения")
                continue
            line = process.stdout.readline()
            if not line:
                if process.poll() is not None:
                    raise RuntimeError("tcpdump не смог захватить пакеты (проверьте права)")
                continue
            parsed = parse_packet(line, port)
            if parsed is None:
                continue
            direction, flags, length = parsed
            counters[direction] += 1
            if direction == "incoming" and "S" in flags and "." not in flags:
                counters["syn_in"] += 1
            if direction == "outgoing" and "S" in flags and "." in flags:
                counters["synack_out"] += 1
            if length > 0:
                counters[f"{direction}_payload"] += 1
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if process.stdout:
            process.stdout.close()
    return counters


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MTProto: только мобильная 4G/5G диагностика")
    parser.add_argument("--seconds", type=int, default=45,
                        help="Длительность наблюдения 10–180 секунд (по умолчанию 45)")
    args = parser.parse_args(argv)
    if not 10 <= args.seconds <= 180:
        parser.error("--seconds должен быть от 10 до 180")
    if hasattr(__import__("os"), "geteuid") and __import__("os").geteuid() != 0:
        print("Запустите от root", file=sys.stderr)
        return 2
    if shutil.which("tcpdump") is None:
        print("Требуется tcpdump: apt-get install tcpdump", file=sys.stderr)
        return 2
    findings = check_configuration(DEFAULT_PORT)
    if findings:
        print("ПРЕДУПРЕЖДЕНИЯ (ничего не изменено):")
        for f in findings:
            print(" -", f)
    print(f"Наблюдаю TCP/{DEFAULT_PORT} {args.seconds} с. Отключите Wi-Fi на телефоне,")
    print("включите мобильные данные и повторите подключение Telegram через MTProto.")
    print("IP-адреса, MTProto-секреты и содержимое пакетов не выводятся и не сохраняются.")
    try:
        c = observe(args.seconds, DEFAULT_PORT)
    except (OSError, RuntimeError) as exc:
        print(f"Ошибка захвата: {type(exc).__name__}", file=sys.stderr)
        return 2
    print("Входящих TCP-пакетов:", c["incoming"])
    print("Входящих SYN:", c["syn_in"])
    print("Исходящих SYN-ACK:", c["synack_out"])
    print("Входящих пакетов с данными:", c["incoming_payload"])
    print("Исходящих пакетов с данными:", c["outgoing_payload"])
    if c["syn_in"] == 0:
        print("ВЫВОД: новая TCP-попытка на этот порт не зафиксирована. Проверьте порт ссылки,")
        print("сетевой путь от мобильного оператора и правила облачного firewall.")
    elif c["synack_out"] == 0:
        print("ВЫВОД: SYN поступает, но ответ SYN-ACK не замечен. Проверьте")
        print("listener, локальный firewall и сетевой маршрут ответа.")
    elif c["incoming_payload"] == 0:
        print("ВЫВОД: TCP-рукопожатие наблюдалось, но данные клиента не видны.")
    else:
        print("ВЫВОД: клиентские TCP-данные достигли ENTRY. Дальше проверяйте")
        print("nginx → mtg → Xray и MTProto-рукопожатие; это НЕ подтверждает авторизацию.")
    print("Счётчики могут включать посторонние попытки и повторы пакетов.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
