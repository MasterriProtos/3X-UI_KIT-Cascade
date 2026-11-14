#!/usr/bin/env python3
"""Safely add a dedicated nginx stream TCP/8445 route for KIT Cascade MTProto.

This CLI never restarts nginx; the wrapper manages atomic-ish backup and rollback.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

MARKER = "# KIT CASCADE MTProto direct 8445"

class ConfigError(ValueError):
    pass

def render(text: str) -> str:
    if MARKER in text:
        return text

    # Only the KIT stream file is supported; do not alter arbitrary nginx files.
    roots = list(re.finditer(r"(?m)^[ \t]*stream[ \t]*\{[ \t]*(?:#.*)?$", text))
    if len(roots) != 1:
        raise ConfigError(f"Ожидается один блок stream, найдено {len(roots)}")

    after = text[roots[0].start():]
    checks = {
        "listen 443": r"(?m)^\s*listen\s+443\s*;",
        "ssl_preread on": r"(?m)^\s*ssl_preread\s+on\s*;",
        "proxy_pass $kit_upstream": r"(?m)^\s*proxy_pass\s+\$kit_upstream\s*;",
        "маршрут в 127.0.0.1:10445": r"127\.0\.0\.1:10445\s*;",
    }
    missing = [label for label, pattern in checks.items() if not re.search(pattern, after)]
    if missing:
        raise ConfigError("В KIT stream не найдены: " + ", ".join(missing))

    if re.search(r"(?m)^\s*listen\s+(?:\[::\]:)?8445\s*;", text):
        raise ConfigError("listen 8445 уже существует, но маркер KIT отсутствует")

    # Find the outer stream closing brace. Formatting and extra server blocks,
    # including a previous localhost:24445 experiment, are allowed.
    level = 0
    close = None
    pos = 0
    for line in text.splitlines(keepends=True):
        if pos < roots[0].start():
            pos += len(line)
            continue
        code = line.split("#", 1)[0]
        # KIT-generated nginx has plain brace-delimited stream/server/map blocks.
        level += code.count("{") - code.count("}")
        if level == 0:
            if code.strip() != "}":
                raise ConfigError("Неожиданное завершение блока stream")
            close = pos
            break
        if level < 0:
            raise ConfigError("Непарные скобки в блоке stream")
        pos += len(line)
    if close is None:
        raise ConfigError("Не найден конец блока stream")

    block = (
        "    " + MARKER + "\n"
        "    server {\n"
        "        listen 8445;\n"
        "        listen [::]:8445;\n"
        "        proxy_pass 127.0.0.1:10445;\n"
        "        proxy_protocol on;\n"
        "        proxy_connect_timeout 10s;\n"
        "        proxy_timeout 1h;\n"
        "    }\n"
    )
    return text[:close] + block + text[close:]

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("check", "apply"))
    ap.add_argument("path", type=Path)
    args = ap.parse_args()
    try:
        before = args.path.read_text()
        after = render(before)
        if args.mode == "apply" and after != before:
            args.path.write_text(after)
        print("nginx stream: OK, отдельный MTProto TCP/8445 "
              + ("применён" if args.mode == "apply" else "можно добавить"))
        return 0
    except (OSError, ConfigError) as exc:
        print(f"ОШИБКА проверки nginx: {exc}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
