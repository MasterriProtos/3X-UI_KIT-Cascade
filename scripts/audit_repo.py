#!/usr/bin/env python3
"""Conservative tracked-file secret check; no values are ever printed.

Does not scan Git history, remote branches, forks or server runtime files.
"""
from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

# Keep these patterns on separate lines and do not embed actual credentials.
PATTERNS = {
    "private-key-header": re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"),
    "github-token": re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{30,}\b"),
    "gitlab-token": re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"),
    "aws-access-key-id": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "telegram-bot-token": re.compile(r"\b\d{8,12}:[A-Za-z0-9_-]{35}\b"),
    "hardcoded-api-token": re.compile(
        r"\b(?:XUI_API_TOKEN|api[_-]?token|api[_-]?key|access[_-]?token|"
        r"aws_secret_access_key)\s*[:=]\s*['\"]?([A-Za-z0-9_+/-]{24,})",
        flags=re.IGNORECASE,
    ),
}

PRIVATE_SUFFIXES = {
    ".pem", ".key", ".p12", ".pfx", ".p8", ".sqlite", ".sqlite3",
    ".db", ".pcap", ".pcapng", ".har",
}
PRIVATE_NAMES = {"state.json", "link.txt", "kit-backup.env", "install-result.env"}

def main() -> int:
    try:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"Repository scan unavailable: {type(exc).__name__}", file=sys.stderr)
        return 2

    problems: list[tuple[str, str]] = []
    for name in tracked:
        if not name:
            continue
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            continue
        if (path.suffix.lower() in PRIVATE_SUFFIXES or path.name in PRIVATE_NAMES
                or path.name.startswith(".env")):
            problems.append((name, "private file type"))
            continue
        try:
            payload = path.read_text(encoding="utf-8")
        except (UnicodeError, OSError):
            # Treat unexpected binary files conservatively.
            problems.append((name, "non-text tracked file (review required)"))
            continue
        for index, line in enumerate(payload.splitlines(), 1):
            for kind, pattern in PATTERNS.items():
                if pattern.search(line):
                    problems.append((f"{name}:{index}", kind))
    if problems:
        for name, kind in problems:
            print(f"{name}: {kind}", file=sys.stderr)
        print(f"Security check failed: {len(problems)} finding(s)", file=sys.stderr)
        return 1
    print(f"Security check passed: {len(tracked) - 1} tracked path(s) inspected")
    return 0

if __name__ == "__main__":
    sys.exit(main())
