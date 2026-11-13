#!/usr/bin/env bash
# Expose the existing Cascade MTProto sidecar on TCP/8445 without SNI routing.
# Safe for an installed ENTRY: no database, firewall, SSH, Xray or EXIT writes.
set -Eeuo pipefail

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запустите от root"
conf=/etc/nginx/kit-stream.conf
backup=/etc/nginx/kit-stream.conf.pre-mtproto-8445
state=/etc/kit-cascade/entry/state.json

[[ -f $state && ! -L $state ]] || fail "Это не установленный Cascade ENTRY"
python3 - "$state" <<'PY' || fail "Состояние ENTRY не подтверждено"
import json, sys
from pathlib import Path
s = json.loads(Path(sys.argv[1]).read_text())
assert s.get("role") == "entry" and s.get("status") == "installed"
PY
[[ -f $conf && ! -L $conf ]] || fail "Нужен обычный файл nginx kit-stream.conf"
systemctl is-active -q nginx || fail "nginx не активен"
systemctl is-active -q x-ui || fail "x-ui не активен"
ss -lnt '( sport = :10445 )' | grep -qE '127\.0\.0\.1:10445\b' || fail "mtg не слушает 127.0.0.1:10445"
nginx -t >/dev/null || fail "Существующая конфигурация nginx не проходит nginx -t"

if grep -Fq '# KIT CASCADE MTProto direct 8445' "$conf"; then
  ss -lnt '( sport = :8445 )' | grep -q ':8445' || fail "Порт есть в конфигурации, но nginx его не слушает"
  echo "Уже настроено: MTProto слушает TCP/8445; ничего не изменено."
  exit 0
fi
[[ ! -e $backup ]] || fail "Файл резервной копии уже существует: $backup; проверьте вручную"
# Prevent collateral damage to a different daemon that owns the public port.
if ss -H -lnt '( sport = :8445 )' | grep -q .; then
  fail "TCP/8445 уже занят; не меняю nginx"
fi
python3 - "$conf" <<'PY' || fail "nginx не соответствует ожидаемому KIT stream config"
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
assert s.count("stream {") == 1
assert "127.0.0.1:10445;" in s
assert "ssl_preread on;" in s
assert s.count("        listen 443;") == 1
assert s.count("    server {\n        listen 443;") == 1
PY
cp -p -- "$conf" "$backup"

rollback() {
  cp -p -- "$backup" "$conf"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
}
trap 'rollback' ERR

python3 - "$conf" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = "    server {\n        listen 443;"
block = """    # KIT CASCADE MTProto direct 8445
    server {
        listen 8445;
        listen [::]:8445;
        proxy_pass 127.0.0.1:10445;
        proxy_protocol on;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }
"""
if s.count(needle) != 1:
    raise SystemExit("Unexpected nginx structure; original kept in backup")
p.write_text(s.replace(needle, block + needle, 1))
PY
nginx -t
systemctl reload nginx
sleep 1
ss -H -lnt '( sport = :8445 )' | grep -q ':8445' || fail "nginx не открыл TCP/8445"
trap - ERR
echo "Готово: nginx -> MTProto TCP/8445 -> 127.0.0.1:10445"
echo "Резервная копия: $backup"
echo "Откройте TCP/8445 в firewall VPS-провайдера, если требуется."
echo "В Telegram: адрес публичного ENTRY, порт 8445, прежний secret."
