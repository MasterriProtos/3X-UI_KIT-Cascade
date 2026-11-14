#!/usr/bin/env bash
# First-install bootstrap for KIT-Cascade. Requires an interactive root shell.
# Clone remains on disk for maintenance; existing installations are never overwritten.
set -Eeuo pipefail
umask 077

readonly REPOSITORY='https://github.com/MasterriProtos/3X-UI_KIT-Cascade.git'
readonly BRANCH='multi-hop-v2'
readonly CHECKOUT='/opt/kit-cascade'

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
KIT-Cascade: установщик чистой ноды

  bash bootstrap.sh
  bash bootstrap.sh --role exit
  bash bootstrap.sh --role relay
  bash bootstrap.sh --role entry
  bash bootstrap.sh --help

Без --role мастер предложит выбрать роль. Поддерживается только чистая
Ubuntu 24.04; требуется интерактивный root-терминал.
Репозиторий клонируется в /opt/kit-cascade.
Скрипт НЕ обновляет существующий KIT, Xray или ноду Cascade.
HELP
}

role=''
if [[ $# -eq 1 && ( "$1" == '--help' || "$1" == '-h' ) ]]; then
  usage
  exit 0
elif [[ $# -eq 2 && "$1" == '--role' ]]; then
  role="$2"
  case "$role" in exit|relay|entry) ;; *) fail "Допустимые роли: exit, relay, entry";; esac
elif [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

[[ "$(id -u)" -eq 0 ]] || fail "Нужны права root: sudo bash bootstrap.sh"
[[ -t 0 && -t 1 ]] || fail "Нужен интерактивный SSH-терминал. Не используйте curl | bash."
[[ -r /etc/os-release ]] || fail "Не найден /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] ||
  fail "Поддерживается только Ubuntu 24.04"
command -v apt-get >/dev/null || fail "Не найден apt-get"
command -v systemctl >/dev/null || fail "Нужен systemd"

# Fail BEFORE apt operations; do not alter an existing checkout or server state.
[[ ! -e "$CHECKOUT" && ! -L "$CHECKOUT" ]] ||
  fail "$CHECKOUT уже существует. Для установленной ноды используйте команды из README."

printf '\nKIT-Cascade: установка базовых зависимостей...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends git python3 ca-certificates curl iproute2

printf '\nЗагружаю KIT-Cascade (%s)...\n' "$BRANCH"
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --single-branch \
  --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"

[[ -f "$CHECKOUT/cascade_v2/install.py" && -f "$CHECKOUT/scripts/3x-ui.sh" ]] ||
  fail "Загружен неполный репозиторий; установка остановлена"

printf '\nЗапускаю интерактивный мастер.\n'
if [[ -n "$role" ]]; then
  exec python3 "$CHECKOUT/cascade_v2/install.py" install --role "$role"
else
  exec python3 "$CHECKOUT/cascade_v2/install.py" install
fi
