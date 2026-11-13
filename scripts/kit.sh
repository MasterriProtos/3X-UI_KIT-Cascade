#!/usr/bin/env bash
# kit – управление сервером 3X-UI KIT: пользователи, обновление, резервная копия.
# https://github.com/itsnotkubrick/3X-UI_KIT
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя
#   kit update [--auto | --manual] | kit backup | kit check | kit fix | kit version

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

KIT_VERSION="1.2.1"
KIT_RAW="https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main"
if [[ -f /etc/kit-cascade/entry/state.json ]]; then
  # Keep helper downloads within this fork; don't silently revert to upstream.
  KIT_RAW="https://raw.githubusercontent.com/MasterriProtos/3X-UI_KIT-Cascade/multi-hop-v2"
  if [[ ${1:-} == update ]]; then
    echo "KIT-Cascade alpha: обновление через 'kit update' отключено: upstream не знает о каскадных маршрутах." >&2
    echo "Сначала обновите форк multi-hop-v2 и проверьте совместимость Xray/3X-UI." >&2
    exit 2
  fi
fi
# Файлы новой версии берём из её тега, а не из меняющейся ветки main.
kit_ref_raw() { echo "https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/v$1"; }

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
KIT_LATEST=/etc/kit/latest-version

# Проверенные версии: kit panel update ставит именно их, kit check предупреждает о других.
# Суммы архива панели и x-ui.sh сверяет tools/release.sh с официальными (перед каждым выпуском).
XUI_PIN="v3.9.0"
XRAY_PIN="v26.6.27"
declare -A XUI_TARBALL_SHA256=(
  [amd64]=d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390
  [arm64]=9a2e43c976a2e71618a30d8f38b52476b25ed363c6989599e2f625cc52f51a81
)
XUI_SH_SHA256=d28959cb5da86c8ddaf2199e5c32dd1ea5dc0a87fcc53f900dd39b133070898a

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { spin_stop; printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { spin_stop; printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

# --- Оформление вывода: ожидание и советы ---------------------------------------------------------
# Анимация ожидания: пока скрипт занят долгой работой без вывода (опрос соседей по подсети, установка пакетов),
# крутится индикатор и идут секунды, чтобы не казалось, что всё зависло. Без терминала (лог, pipe) – одна строка.
SPIN_PID=""
spin_start() { # текст
  spin_stop
  if [[ ! -t 2 ]]; then printf '%s…\n' "$1" >&2; return 0; fi
  local msg=$1 start=$SECONDS parent=$$
  (
    local -a fr=('|' '/' '-' '\\') i=0
    case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) ;; esac
    while kill -0 "$parent" 2>/dev/null; do
      printf '\r      %s %s  %s с ' "${fr[i % ${#fr[@]}]}" "$msg" "$((SECONDS - start))" >&2
      i=$((i + 1)); sleep 0.1
    done
  ) &
  SPIN_PID=$!
}
spin_stop() {
  [[ -n $SPIN_PID ]] || return 0
  kill "$SPIN_PID" 2>/dev/null || true
  wait "$SPIN_PID" 2>/dev/null || true
  SPIN_PID=""
  [[ -t 2 ]] && printf '\r\033[K' >&2
  return 0
}
# Блок «Что дальше»: советы и рекомендации отделены от хода работы рамкой и нумерацией. Пункты – обычные фразы,
# без команд: пользователя ведём в меню kit.
tips() { # заголовок, затем пункты
  local title=$1 n=0 item row first
  shift
  printf '\n%s┌─%s %s%s%s\n' "$D" "$N" "$B" "$title" "$N"
  for item in "$@"; do
    n=$((n + 1)); first=yes
    while IFS= read -r row; do
      if [[ $first == yes ]]; then printf '%s│%s %s%d.%s %s\n' "$D" "$N" "$B" "$n" "$N" "$row"; first=no
      else printf '%s│%s    %s\n' "$D" "$N" "$row"; fi
    done < <(if command -v python3 >/dev/null 2>&1; then python3 -c 'import sys,textwrap; t=sys.argv[1].replace(" → ","\u00a0→\u00a0"); print("\n".join(textwrap.wrap(t, 74, break_on_hyphens=False, break_long_words=False)).replace("\u00a0"," "))' "$item"; else printf '%s\n' "$item"; fi)
  done
  printf '%s└─%s\n' "$D" "$N"
}

# A-записи домена. Сначала публичный DNS (DoH): локальный резолвер сервера может помнить «записи нет» с тех пор, как её не было,
# и kit тогда спорит с тем, что вы видите у регистратора. Нет ответа от публичного DNS – берём системный.
dns_a() { # домен → IPv4 по одному в строке
  local r
  r=$(curl -fsS -m 6 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=A" 2>/dev/null \
      | grep -oE '"data":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' | cut -d'"' -f4 | sort -u || true)
  [[ -n $r ]] || r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)
  printf '%s' "$r"
}

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка – сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"

API=""; API_OK=no
for scheme in https http; do
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  if curl -fsk -m 5 -o /dev/null -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") "$API/server/getNewUUID" 2>/dev/null; then API_OK=yes; break; fi
done
if [[ $API_OK == no && -x /usr/local/x-ui/x-ui ]]; then
  # Токен из файла не подошёл (после обновления с 1.0, смены токена, переустановки панели). Токены хранятся хэшами, прочитать
  # нельзя, но команда панели выпускает отдельный токен «cli-fallback», не трогая остальные: берём его и сохраняем в файл.
  new_token=$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | sed -n 's/^apiToken: *//p' | tail -1 | tr -d '[:space:]' || true)
  if [[ $new_token =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
    for scheme in https http; do
      API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
      if curl -fsk -m 5 -o /dev/null -H @<(printf 'Authorization: Bearer %s\n' "$new_token") "$API/server/getNewUUID" 2>/dev/null; then API_OK=yes; break; fi
    done
    if [[ $API_OK == yes ]]; then
      XUI_API_TOKEN=$new_token
      env_tmp=$(mktemp); { grep -av '^XUI_API_TOKEN=' "$XUI_ENV" || true; printf 'XUI_API_TOKEN=%q\n' "$new_token"; } >"$env_tmp"
      install -m 600 "$env_tmp" "$XUI_ENV"; rm -f "$env_tmp"
      warn "Токен API панели в $XUI_ENV не подошёл – выпустил новый и сохранил (старый остаётся в панели, его можно отозвать: Настройки – API-токены)."
    fi
  fi
  unset new_token env_tmp
fi
if [[ $API_OK == no ]]; then
  # Токен не подошёл ни по https, ни по http. Схему выбираем по тому, говорит ли порт панели по TLS:
  # иначе запрос по http к TLS-порту даёт невнятное «Unsupported HTTP version in response».
  if [[ $(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$XUI_PANEL_PORT/" 2>/dev/null || true) =~ ^[1-5] ]]; then scheme=https; else scheme=http; fi
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
fi

api() { # METHOD path [json]
  local out code
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -w $'\n%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") "$API/$2" || true)
  else
    out=$(curl -sSk -m 20 -w $'\n%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") -H 'Content-Type: application/json' -X "$1" --data-binary @<(printf '%s' "${3:-{\}}") "$API/$2" || true)
  fi
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ $(jq -r '.success' <<<"$out" 2>/dev/null) != true ]]; then
    if [[ -z $out || $out != "{"* ]]; then
      die "Панель не приняла запрос (HTTP ${code:-нет ответа}). Частая причина: токен API в $XUI_ENV устарел или не подходит к этой панели. Проверьте: kit → Проверка сервера → Быстрая проверка"
    fi
    die "Панель ответила ошибкой: $(jq -r '.msg // .' <<<"$out" 2>/dev/null | head -c 300)"
  fi
  jq -c '.obj' <<<"$out"
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму – запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  for id in $(awg_ids); do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or ((.email | startswith($e + "-awg")) and (.email[($e | length) + 4:] | test("^[0-9]*$")))) | .email'; }
# Имя из одних точек («.», «..») не годится: оно уходит в путь запроса к панели (clients/update/имя).
valid_name() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ && $1 =~ [^.] ]] || die "Имя: латиница, цифры, _ . - (до 32 символов, не только точки)."; }
rand_id() { openssl rand -base64 48 | tr -dc 'a-z0-9' | head -c 16; }

# Числа из командной строки: «08» не должно читаться как восьмеричное, а 30 цифр – переполнять счёт.
gb_bytes() { [[ ${1-} =~ ^[0-9]{1,6}$ ]] || die "--gb: целое число гигабайт (до 999999), например --gb 50"; echo $((10#$1 * 1073741824)); }
days_ms() { [[ ${1-} =~ ^[0-9]{1,5}$ ]] || die "--days: целое число дней (до 99999), например --days 30"; ((10#$1 == 0)) && { echo 0; return; }; echo $((($(date +%s) + 10#$1 * 86400) * 1000)); }
# Флаги вида --gb=50 превращаем в «--gb 50»; у флага без значения – понятная ошибка.
eq_args() { # печатает аргументы по одному
  local a
  for a in "$@"; do if [[ $a == --*=* ]]; then printf '%s\n%s\n' "${a%%=*}" "${a#*=}"; else printf '%s\n' "$a"; fi; done
}
need_val() { [[ -n ${2-} ]] || die "У параметра $1 нет значения."; }

human() { # байты → «1.2 ГБ»
  awk -v b="$1" 'BEGIN { split("Б КБ МБ ГБ ТБ", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

sub_url() { echo "${SUB_BASE}$1"; }

# Отдельные ссылки на протоколы – прямо из подписки 3X-UI внутри сервера (мимо kit-sub, который
# прячет от VPN-приложений vpn:// и tg://). collect_links subId фильтр – печатает подходящие строки.
collect_links() {
  local sid=$1 filter=$2 raw out="" suffix scheme
  for suffix in "" -awg; do
    raw=""
    # Внутренняя подписка отвечает по http (всё на 443) или по https (свой порт с сертификатом).
    for scheme in http https; do
      raw=$(curl -fsSk -m 10 -A "v2rayN/7" -H "Host: ${LINK_HOST:-$HOST}" "$scheme://127.0.0.1:$SUB_INTERNAL$SUB_PATH$sid$suffix" 2>/dev/null) && [[ -n $raw ]] && break
      raw=""
    done
    grep -q '://' <<<"$raw" || raw=$(base64 -d <<<"$raw" 2>/dev/null || true)
    out+=$(grep -E "$filter" <<<"$raw" || true)$'\n'
  done
  # Порт попадает в выражение sed – только если это число.
  local inner=${MTPROTO_INNER:-10445}
  [[ ${SINGLE:-no} == yes && $inner =~ ^[0-9]{1,5}$ ]] && out=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=$inner/\1\2port=443/" <<<"$out")
  # После kit net site панель может взять в ссылку прежнее (льготное) имя сайта – ставим нынешнее.
  [[ ! -f ${SNI_GRACE_SUB:-} ]] || out=$(grace_links <<<"$out")
  grep . <<<"$out" || true
}

direct_links() { # subId фильтр
  local out
  out=$(collect_links "$1" "$2")
  echo
  if [[ -n $out ]]; then echo "$out"; else echo "Отдельных ссылок нет."; fi
}

# Панель «через SSH-туннель»: подписка слушает только 127.0.0.1, с телефона по ней не зайти.
local_only_sub() { [[ ${SUB_BASE:-} == http://127.0.0.1* || ${SUB_BASE:-} == http://localhost* ]]; }

# Ссылки «открыть в приложении»: нажатие добавляет подписку сразу с названием.
# Проверено на устройстве: Karing, Happ. Остальные собраны по документации приложений.
app_links() { # адрес подписки
  local url=$1 enc
  enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")
  echo "Открыть в приложении (отправьте ссылку себе или близкому в мессенджер и нажмите):"
  echo "  Karing:       karing://install-config?url=$enc&name=3X-UI%20KIT"
  echo "  Happ:         happ://add/$url"
  echo "  Hiddify:      hiddify://import/$url#3X-UI%20KIT"
  echo "  Clash Verge:  clash://install-config?url=$enc&name=3X-UI%20KIT"
  echo "  FlClash:      flclash://install-config?url=$enc"
  echo "  Mihomo Party: mihomo://install-config?url=$enc&name=3X-UI%20KIT"
  echo "  v2rayNG:      v2rayng://install-sub?url=$enc&name=3X-UI%20KIT"
}

show_link() { # имя subId
  local url
  url=$(sub_url "$2")
  echo
  if local_only_sub; then
    echo "В режиме «панель через SSH-туннель» подписка открывается только на самом сервере,"
    echo "поэтому подключайтесь ссылками на протоколы ниже."
    echo
    links_block "$1" "$2"
    return 0
  fi
  echo "Подписка ${B}$1${N} – все протоколы одной ссылкой. Вставьте в Happ, Hiddify, Karing,"
  echo "v2rayN, Clash Verge или FlClash:"
  echo
  echo "$url"
  echo
  command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$url"
  app_links "$url"
  echo
  [[ ${3:-} == all ]] || echo "${D}Отдельные ссылки на каждый протокол: kit → Пользователи → Показать ссылки${N}"
}

cmd_add() {
  local name=${1:-} gb=0 days=0 devices=0
  valid_name "$name"; shift
  mapfile -t _args < <(eq_args "$@"); set -- ${_args[@]+"${_args[@]}"}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) need_val "$@"; gb=$2; shift 2 ;;
      --days) need_val "$@"; days=$2; shift 2 ;;
      --devices) need_val "$@"; devices=$2; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [[ $devices =~ ^[0-9]{1,4}$ ]] || die "--devices: целое число"
  devices=$((10#$devices))
  [[ -z $(client "$name") ]] || die "Пользователь $name уже есть. Ссылка: kit → Пользователи → Показать ссылки"
  local ids sid body
  ids=$(non_awg_ids)
  [[ $ids != "[]" ]] || die "На сервере нет подключений."
  gb_bytes "$gb" >/dev/null; days_ms "$days" >/dev/null
  gb=$((10#$gb)); days=$((10#$days))
  sid=$(rand_id)
  body=$(jq -nc --arg e "$name" --arg s "$sid" --argjson t "$(gb_bytes "$gb")" --argjson x "$(days_ms "$days")" \
    --argjson ip "$devices" --argjson ids "$ids" '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x,
    limitIp: $ip, enable: true, flow: "xtls-rprx-vision", comment: "kit"}, inboundIds: $ids}')
  api POST clients/add "$body" >/dev/null
  awg_attach "$name" "$sid" "$(gb_bytes "$gb")" "$(days_ms "$days")" "$devices"
  say "Пользователь $name добавлен во все протоколы ($(api GET inbounds/list | jq length))$( ((gb)) && echo ", лимит $gb ГБ")$( ((days)) && echo ", на $days дн")."
  show_link "$name" "$sid"
}

# Все ссылки на подключения одним экраном: подписка, отдельные протоколы, AmneziaWG и Telegram.
# Без имени – первый пользователь (после установки это тот, кого создал установщик).
cmd_links() { # [имя]
  [[ $# -le 1 ]] || die "kit links [имя]"
  local name=${1:-} n
  if [[ -z $name ]]; then
    name=$(clients | jq -r 'map(select(.subId != null and (.email | test("-awg[0-9]*$") | not)))[0].email // empty')
    [[ -n $name ]] || die "Пользователей нет. Добавьте: kit → Пользователи → Добавить"
    n=$(clients | jq -r '[.[] | select(.subId != null and (.email | test("-awg[0-9]*$") | not))] | length')
    ((n > 1)) && echo "${D}Показан пользователь $name. Ссылки других: kit → Пользователи → Показать ссылки${N}"
  fi
  cmd_link "$name" --all
}

cmd_link() {
  local name=${1:-} flag=${2:-} c sid out
  valid_name "$name"
  c=$(client "$name"); [[ -n $c ]] || die "Нет пользователя $name"
  sid=$(jq -r '.subId' <<<"$c")
  case $flag in
    --amnezia)
      out=$(collect_links "$sid" '^vpn://')
      [[ -n $out ]] || die "Ссылок AmneziaVPN нет: AmneziaWG на этом сервере не установлен."
      echo
      echo "AmneziaVPN: в приложении «Добавить подключение», вставьте ссылку целиком."
      echo "Первая – классический AmneziaWG, вторая (если есть) – версия 3.1."
      echo
      echo "$out" ;;
    --telegram)
      out=$(collect_links "$sid" '^tg://')
      [[ -n $out ]] || die "Ссылки для Telegram нет: MTProto на этом сервере не установлен."
      echo
      echo "Telegram: откройте ссылку на телефоне или наведите камеру на QR-код, Telegram предложит добавить прокси."
      echo
      echo "$out"
      echo
      [[ ${SINGLE:-no} == yes ]] && { echo "${D}Порт 443 – верный (в панели ссылка такая же). ${MTPROTO_INNER:-10445} – внутренний порт сервера, снаружи он закрыт:"; echo "если увидите его в старой ссылке, берите ссылку отсюда.${N}"; echo; }
      command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$(head -1 <<<"$out")"
      return 0 ;;
    "" | --all)
      show_link "$name" "$sid" "${flag#--}"
      # В режиме «только на сервере» показ уже содержит все ссылки.
      if [[ $flag == --all ]] && ! local_only_sub; then echo; links_block "$name" "$sid"; fi ;;
    *) die "kit user link имя [--all | --amnezia | --telegram]" ;;
  esac
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="–"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую – от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  mapfile -t _args < <(eq_args "$@"); set -- ${_args[@]+"${_args[@]}"}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) need_val "$@"; gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) need_val "$@"; days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) need_val "$@"; [[ $2 =~ ^[0-9]{1,4}$ ]] || die "--devices: целое число"; dev=$((10#$2)); f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  cmd_enforce --quiet
  say "Лимиты $name обновлены (0 – без ограничений)."
}

# Общий лимит трафика. У пользователя несколько записей в панели (основная и «двойник» AmneziaWG),
# и панель считает трафик каждой записи отдельно. Раз в 5 минут складываем трафик всех записей и,
# если сумма дошла до лимита основной записи, отключаем их все. Когда счётчики сброшены, лимит
# поднят или трафик ушёл ниже лимита, включаем обратно только те записи, которые отключили сами
# (в комментарии записи «kit:limit»), чтобы не перебить ваше ручное «kit user off».
cmd_enforce() {
  local dry=no quiet=no a list plan line e act used lim rec body
  for a in "$@"; do
    case $a in
      --dry-run) dry=yes ;;
      --quiet) quiet=yes ;;
      *) die "kit user enforce [--dry-run]" ;;
    esac
  done
  list=$(clients)
  plan=$(jq -c --argjson now "$(($(date +%s) * 1000))" '
    map(select((.subId // "") != ""))
    | group_by(.subId | sub("-awg[0-9]*$"; ""))
    | .[]
    | (sort_by(.email | length)) as $g
    | ($g[0].totalGB // 0) as $lim
    | ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add) as $used
    | $g[]
    | if $lim > 0 and $used >= $lim and .enable == true then {email, act: "off", used: $used, lim: $lim}
      elif ($lim == 0 or $used < $lim) and .enable == false and .comment == "kit:limit"
           and ((.expiryTime // 0) == 0 or .expiryTime > $now) then {email, act: "on", used: $used, lim: $lim}
      else empty end' <<<"$list")
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    e=$(jq -r '.email' <<<"$line"); act=$(jq -r '.act' <<<"$line")
    used=$(jq -r '.used' <<<"$line"); lim=$(jq -r '.lim' <<<"$line")
    if [[ $dry == yes ]]; then
      echo "$e: $([[ $act == off ]] && echo отключить || echo включить) (трафик $(human "$used") из $(human "$lim"))"
      continue
    fi
    rec=$(jq -c --arg e "$e" 'map(select(.email == $e))[0]' <<<"$list")
    if [[ $act == off ]]; then
      body=$(jq -c '{email, subId, totalGB, expiryTime, limitIp, enable, comment} | .enable = false | .comment = "kit:limit"' <<<"$rec")
    else
      body=$(jq -c '{email, subId, totalGB, expiryTime, limitIp, enable, comment} | .enable = true | .comment = "kit"' <<<"$rec")
    fi
    api POST "clients/update/$e" "$body" >/dev/null
    if [[ $quiet == no || $act == off ]]; then
      if [[ $act == off ]]; then echo "$e: отключён, общий лимит исчерпан ($(human "$used") из $(human "$lim"))"
      elif ((lim == 0)); then echo "$e: включён обратно, лимит снят"
      else echo "$e: включён обратно, трафик ниже лимита ($(human "$used") из $(human "$lim"))"; fi
    fi
  done <<<"$plan"
  return 0
}

# Проверка общего лимита раз в 5 минут (systemd-таймер).
limit_timer_on() {
  cat >/etc/systemd/system/kit-limit.service <<'UNIT'
[Unit]
Description=3X-UI KIT: общий лимит трафика пользователей (сумма по всем записям)
After=x-ui.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kit user enforce --quiet
TimeoutStartSec=120
UNIT
  cat >/etc/systemd/system/kit-limit.timer <<'UNIT'
[Unit]
Description=3X-UI KIT: проверка общего лимита трафика раз в 5 минут

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now kit-limit.timer >/dev/null 2>&1
}
limit_timer_enabled() { systemctl is-enabled -q kit-limit.timer 2>/dev/null; }

# xtls-rprx-vision для REALITY. Панель сама ставит flow только там, где он допустим (REALITY по TCP), на XHTTP, WS и др. его нет.
# Клиент без Vision не подключится к серверу, где у пользователя Vision включён, поэтому у существующих пользователей
# включаем только по команде: ссылки в подписке обновятся сами, а вручную сохранённые ссылки на REALITY придётся заменить.
cmd_vision() { # имя|--all [off]
  local target=${1:-} flow="xtls-rprx-vision" e rec body n=0
  [[ -n $target ]] || die "kit user vision имя|--all [off]"
  [[ ${2:-} == off ]] && flow=""
  if [[ $target == --all ]]; then
    mapfile -t _emails < <(clients | jq -r '.[] | select(.email | test("-awg[0-9]*$") | not) | .email')
  else
    valid_name "$target"; [[ -n $(client "$target") ]] || die "Нет пользователя $target"
    _emails=("$target")
  fi
  for e in "${_emails[@]}"; do
    rec=$(client "$e")
    body=$(jq -c --arg f "$flow" '{email, subId, totalGB, expiryTime, limitIp, enable, comment} + {flow: $f}' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
    n=$((n + 1))
  done
  if [[ -n $flow ]]; then say "Vision включён у $n польз.: ссылка REALITY в подписке теперь с flow=xtls-rprx-vision (приложения подхватят при обновлении подписки)."
  else say "Vision выключен у $n польз."; fi
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v | .comment = \"kit\"" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен – подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}

# ---------- версия и обновление ----------

# Открытый ключ, которым автор подписывает релизы (ssh-keygen -Y sign). Закрытая часть
# есть только у автора, поэтому подменить обновление, взломав один GitHub, не выйдет.
# Обычная смена ключа идёт релизом, подписанным старым. В 1.2.1 так не вышло: прежний ключ утерян, поэтому
# серверы на 1.2 и ниже переходят вручную (команда в README, kit.sh берётся с тега по HTTPS).
KIT_SIGNERS=(
  # SHA256:bNjI10eGVGjdFeDJnAHvUFi73rlrXVy6vKFf8lmNyxU (itsnotkubrick, 2026-10-14; прежний ключ SHA256:VDuGgJ8d… утерян, снят)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEWDFGq2Wno/ADRS2E6UKsgFbUSLvaiPIfRBvSEGJr81 3X-UI KIT releases"
)
KIT_SIG_NS="3x-ui-kit-release"
KIT_SIG_ID="releases@3x-ui-kit"
KIT_MANUAL=/etc/kit/manual-update
KIT_UPDATE_LOG=/var/log/kit-update.log

xray_version() {
  local b
  for b in /usr/local/x-ui/bin/xray-linux-*; do [[ -x $b ]] && "$b" version 2>/dev/null | awk 'NR==1 {print "v" $2}'; return; done
}
remote_version() { curl -fsS -m "${1:-5}" "$KIT_RAW/VERSION" 2>/dev/null | tr -d '[:space:]'; }
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1) == "$1" ]]; }  # $1 новее $2?
auto_enabled() { systemctl is-enabled -q kit-update.timer 2>/dev/null; }

# Раз в сутки узнаём последнюю версию (не дольше 3 секунд) и подсказываем обновиться.
update_hint() {
  local latest=""
  if [[ ! -f $KIT_LATEST ]] || (($(date +%s) - $(stat -c %Y "$KIT_LATEST") > 86400)); then
    latest=$(remote_version 3) || true
    [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] && echo "$latest" >"$KIT_LATEST" || touch "$KIT_LATEST"
  fi
  latest=$(cat "$KIT_LATEST" 2>/dev/null || true)
  if [[ -n $latest ]] && newer "$latest" "$KIT_VERSION"; then
    echo
    if auto_enabled; then
      echo "${Y}↑ Вышла версия $latest${N} (у вас $KIT_VERSION). Встанет сама этой ночью или сейчас: ${B}kit → Обновить kit и подписку${N}"
    else
      echo "${Y}↑ Доступна версия $latest${N} (у вас $KIT_VERSION). Обновить: ${B}kit → Обновить kit и подписку${N}"
    fi
  fi
}

cmd_version() {
  echo "3X-UI KIT $KIT_VERSION"
  echo "${D}панель 3X-UI $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo '?'), ядро Xray $(xray_version)${N}"
  if auto_enabled; then echo "${D}автообновление: включено (только подписанные релизы), журнал $KIT_UPDATE_LOG${N}"
  else echo "${D}автообновление: выключено, включить: kit → Автообновление${N}"; fi
  update_hint
}

# Что нового в версии $1 – из CHANGELOG.md, без разметки.
changelog_of() {
  curl -fsS -m 5 "$KIT_RAW/CHANGELOG.md" 2>/dev/null | awk -v v="## v$1" '
    index($0, v) == 1 { on = 1; t = substr($0, length(v) + 1); sub(/^[: ]+/, "", t); if (t != "") print t; next } on && /^## / { exit } on' | sed -E 's/ ?Спасибо .*$//; s/\[([^]]*)\]\([^)]*\)/\1/g; s/\*\*//g; s/`//g' | grep -v '^[[:space:]]*$' | head -40 || true
}

# Скачивает релиз $1 в каталог $2 и проверяет: подпись SHA256SUMS нашим ключом, версию
# внутри подписанного файла и SHA256 каждого файла. Любое несовпадение – отказ.
fetch_release() { # версия каталог
  local v=$1 d=$2 raw f sum k
  ((${#KIT_SIGNERS[@]})) || { warn "В этой сборке kit нет ключа подписи – проверить обновление нечем."; return 1; }
  command -v ssh-keygen >/dev/null || { warn "Нет ssh-keygen (пакет openssh-client) – подпись не проверить."; return 1; }
  raw=$(kit_ref_raw "$v")
  curl -fsSL --retry 3 -o "$d/SHA256SUMS" "$raw/SHA256SUMS" && curl -fsSL --retry 3 -o "$d/SHA256SUMS.sig" "$raw/SHA256SUMS.sig" \
    || { warn "Не удалось скачать подпись релиза $v."; return 1; }
  : >"$d/allowed_signers"
  for k in "${KIT_SIGNERS[@]}"; do printf '%s namespaces="%s" %s\n' "$KIT_SIG_ID" "$KIT_SIG_NS" "$k" >>"$d/allowed_signers"; done
  if ! ssh-keygen -Y verify -f "$d/allowed_signers" -I "$KIT_SIG_ID" -n "$KIT_SIG_NS" -s "$d/SHA256SUMS.sig" <"$d/SHA256SUMS" >/dev/null 2>&1; then
    warn "Подпись релиза $v не сошлась с ключом автора – это не наш релиз. Ничего не ставлю."
    return 1
  fi
  # Версия записана внутри подписанного файла: старый подписанный релиз под видом нового не пройдёт.
  grep -qx "# 3X-UI KIT $v" "$d/SHA256SUMS" || { warn "Подписанный релиз не той версии – ничего не ставлю."; return 1; }
  for f in scripts/kit.sh scripts/kit-sub.py; do
    sum=$(awk -v f="$f" '$2 == f {print $1}' "$d/SHA256SUMS")
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { warn "В подписанном списке нет $f."; return 1; }
    curl -fsSL --retry 3 -o "$d/${f##*/}" "$raw/$f" || { warn "Не удалось скачать $f."; return 1; }
    [[ $(sha256sum "$d/${f##*/}" | awk '{print $1}') == "$sum" ]] || { warn "$f не совпал с подписанным SHA256 – ничего не ставлю."; return 1; }
  done
}

# Юнит kit-sub: без root (DynamicUser), конфиг и сертификат – через LoadCredential.
# Сертификат Let's Encrypt на IP продлевается раз в несколько дней, поэтому при отдельном
# порте kit-sub перезапускается раз в сутки и берёт свежий.
kit_sub_unit() { # путь-к-сертификату путь-к-ключу (пусто – за nginx)
  cat <<UNIT
[Unit]
Description=kit-sub: подписка с учётом приложения (3X-UI KIT)
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_sub.py
Restart=on-failure
RestartSec=5
DynamicUser=yes
LoadCredential=config.json:/etc/kit-sub/config.json
${1:+LoadCredential=cert.pem:$1}
${2:+LoadCredential=key.pem:$2}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT
}

# Хвост журнала kit-sub для сообщения об откате: без адресов и пути подписки (ссылки и строка «слушает …»).
# Пустой журнал или все строки отфильтрованы – не ошибка: под set -e и pipefail откат иначе оборвался бы.
sub_journal() {
  { journalctl -u kit-sub -n 5 --no-pager -o cat 2>/dev/null || true; } | { grep -v -e 'https\?://' -e 'слушает' || true; } \
    | tail -n 2 | tr '\n' ' ' | cut -c1-200
}

# Подписка отвечает? Берём настоящего пользователя и спрашиваем kit-sub изнутри сервера.
# Код ответа последней попытки остаётся в SUB_LAST_CODE (000 – соединения не было). С аргументом alive
# проверяем только, что служба жива и слушает порт (когда подписка не отвечала ещё до обновления).
SUB_LAST_CODE=""
sub_ok() {
  local cfg=/etc/kit-sub/config.json port path scheme=http sid i code
  port=$(jq -r '.port' "$cfg"); path=$(jq -r '.path' "$cfg")
  [[ -n $(jq -r '.cert // empty' "$cfg") ]] && scheme=https
  sid=$(clients 2>/dev/null | jq -r '[.[] | .subId // empty | select(. != "")][0] // empty' 2>/dev/null || true)
  [[ ${1:-} == alive ]] && sid=""
  SUB_LAST_CODE=""
  for i in $(seq 1 10); do
    if [[ -n $sid ]]; then
      code=$(curl -sSk -m 5 -o /dev/null -w '%{http_code}' -A "Happ/1.0" "$scheme://127.0.0.1:$port$path$sid" 2>/dev/null || true)
      SUB_LAST_CODE=${code:-000}
      [[ $SUB_LAST_CODE =~ ^[23][0-9][0-9]$ ]] && return 0
    else
      # Пользователей нет – достаточно, что служба жива и слушает порт.
      systemctl is-active -q kit-sub && ss -Hltn "sport = :$port" | grep -q . && return 0
    fi
    sleep 1
  done
  return 1
}

# Сервер ещё не получил исправления 1.1 (например, kit обновили вручную из 1.0)?
needs_migration() {
  [[ -f /etc/cron.d/kit-xui-menu ]] && return 0
  [[ -f /etc/systemd/system/kit-sub.service ]] && ! grep -q '^DynamicUser=yes' /etc/systemd/system/kit-sub.service && return 0
  [[ ! -f $KIT_MANUAL ]] && ! auto_enabled && return 0
  limit_timer_enabled || return 0
  mt_needs && return 0
  [[ -f /etc/kit-sub/config.json ]] && ! jq -e 'has("extra_paths")' /etc/kit-sub/config.json >/dev/null 2>&1 && return 0
  return 1
}

# Автообновление: раз в сутки ночью со случайной задержкой, чтобы тысячи серверов не шли
# на GitHub в одну минуту. Ставит только подписанные релизы и только kit и kit-sub.
auto_on() {
  cat >/etc/systemd/system/kit-update.service <<UNIT
[Unit]
Description=3X-UI KIT: автообновление kit и kit-sub (только подписанные релизы)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kit update --unattended
StandardOutput=append:$KIT_UPDATE_LOG
StandardError=append:$KIT_UPDATE_LOG
UNIT
  cat >/etc/systemd/system/kit-update.timer <<'UNIT'
[Unit]
Description=3X-UI KIT: проверка обновлений раз в сутки

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  rm -f "$KIT_MANUAL"
  systemctl daemon-reload
  systemctl enable --now kit-update.timer >/dev/null 2>&1
}

auto_off() {
  systemctl disable --now kit-update.timer >/dev/null 2>&1 || true
  install -d -m 700 /etc/kit
  touch "$KIT_MANUAL"
}

cmd_update() {
  local force="" unattended=no latest tmp panel=no
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=yes ;;
      --panel) panel=yes ;;
      --auto) auto_on; say "Автообновление включено: раз в сутки ночью, только подписанные релизы. Журнал: $KIT_UPDATE_LOG"; return ;;
      --manual) auto_off; say "Автообновление выключено. Обновлять вручную: kit → Обновить kit и подписку. Включить снова: kit → Автообновление"; return ;;
      --unattended) unattended=yes ;;
      *) die "Неизвестный параметр: $1 (kit update [--panel | --force | --auto | --manual])" ;;
    esac
    shift
  done
  [[ $panel == no ]] || { panel_update ${force:+--force}; return; }
  # Ночной запуск и ручной не должны встретиться.
  exec 9>/run/kit-update.lock
  flock -n 9 || die "Обновление уже идёт."
  [[ $unattended == yes ]] && echo "--- $(date '+%F %T') kit $KIT_VERSION: проверяю обновления"
  # Ночной запуск убирает прежние имена сайта, у которых закончился льготный срок (kit net site).
  (grace_cleanup) || true

  latest=$(remote_version) || true
  [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Не удалось узнать последнюю версию: GitHub недоступен с сервера. Попробуйте позже."
  echo "$latest" >"$KIT_LATEST"
  # Откатить на старую версию нельзя даже с подписью: только вперёд или та же.
  newer "$KIT_VERSION" "$latest" && die "На GitHub версия $latest старше вашей $KIT_VERSION – ничего не делаю."
  if ! newer "$latest" "$KIT_VERSION" && [[ $force != yes ]] && ! needs_migration; then
    say "У вас последняя версия: $KIT_VERSION."
    [[ $unattended == yes ]] || echo "${D}Переустановить файлы kit той же версии: kit → Обновить kit и подписку${N}"
    return
  fi
  if [[ $latest == "$KIT_VERSION" ]]; then say "Применяю исправления версии $latest"; else say "3X-UI KIT $KIT_VERSION → $latest"; fi
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  spin_start "Скачиваю релиз и проверяю подпись"
  fetch_release "$latest" "$tmp" || { spin_stop; die "Сервер не тронут."; }
  spin_stop
  bash -n "$tmp/kit.sh" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmp/kit-sub.py" \
    || die "Файлы релиза не прошли проверку синтаксиса – сервер не тронут."

  # Подписка kit-sub: ставим новую, проверяем, что отвечает, иначе возвращаем старую.
  if [[ -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    # Отвечала ли подписка ДО замены: если нет (например, у встроенной подписки панели включён TLS), откат ничего не даст.
    local old_ok=yes sub_fail=no
    sub_ok || old_ok=no
    cp /usr/local/lib/kit-sub/kit_sub.py "$tmp/kit_sub.old"
    cp /etc/systemd/system/kit-sub.service "$tmp/kit-sub.service.old"
    install -m 644 "$tmp/kit-sub.py" /usr/local/lib/kit-sub/kit_sub.py
    # С 1.1 kit-sub работает без root: переписываем юнит под DynamicUser и LoadCredential.
    local c k
    c=$(jq -r '.cert // empty' /etc/kit-sub/config.json); k=$(jq -r '.key // empty' /etc/kit-sub/config.json)
    local sysv
    sysv=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')
    if [[ $sysv =~ ^[0-9]+$ ]] && ((sysv < 247)); then
      # LoadCredential появился в systemd 247: на более старой юнит без root не запустится, оставляем прежний.
      warn "systemd $sysv старше 247: юнит kit-sub не меняю (подписка работает как раньше). Лучше перейти на Ubuntu 22.04+ или Debian 11+."
    else
      kit_sub_unit "$c" "$k" >/etc/systemd/system/kit-sub.service
      [[ -n $c ]] && echo '19 4 * * * root systemctl restart kit-sub >/dev/null 2>&1' >/etc/cron.d/kit-sub-cert
    fi
    systemctl daemon-reload
    if [[ $old_ok == no ]]; then
      warn "Подписка не отвечала и до обновления (код ${SUB_LAST_CODE:-нет ответа}). Что с сервером: kit → Проверка сервера, там же «Исправить безопасное»"
      if systemctl restart kit-sub && sleep 2 && sub_ok alive; then
        say "Подписка kit-sub обновлена и запущена (отвечать она начнёт после исправления: kit → Проверка сервера → Исправить безопасное)"
      else
        sub_fail=yes
      fi
    elif systemctl restart kit-sub && sleep 2 && sub_ok; then
      say "Подписка kit-sub обновлена и отвечает"
    else
      sub_fail=yes
    fi
    if [[ $sub_fail == yes ]]; then
      local why="код ${SUB_LAST_CODE:-нет ответа}"
      why+="; журнал: $(sub_journal)"
      warn "Причина: $why"
      install -m 644 "$tmp/kit_sub.old" /usr/local/lib/kit-sub/kit_sub.py
      install -m 644 "$tmp/kit-sub.service.old" /etc/systemd/system/kit-sub.service
      grep -q '^LoadCredential=cert.pem' "$tmp/kit-sub.service.old" || rm -f /etc/cron.d/kit-sub-cert
      systemctl daemon-reload
      systemctl restart kit-sub || true
      die "Новая подписка не ответила – вернул прежнюю, kit остался версии $KIT_VERSION. Лог: journalctl -u kit-sub -n 30"
    fi
  fi

  # Исправления для установок 1.0.
  local all uri
  all=$(api POST setting/all)
  uri=${SUB_BASE:-}
  if [[ $uri == https://* && $(jq -r '.subURI // ""' <<<"$all") != "$uri" ]]; then
    api POST setting/update "$(jq -c --arg u "$uri" '.subURI = $u' <<<"$all")" >/dev/null
    say "Ссылка подписки в панели: $uri…"
  fi
  # 1.0 ставил cron, который каждый день правил файлы x-ui, – убираем.
  rm -f /etc/cron.d/kit-xui-menu
  # Автообновление включено по умолчанию, пока его не выключили командой kit update --manual.
  [[ -f $KIT_MANUAL ]] || auto_enabled || { auto_on; say "Включил автообновление: kit → Автообновление, чтобы выключить"; }

  # Общий лимит трафика: проверка раз в 5 минут (с 1.2).
  limit_timer_enabled || { limit_timer_on; say "Включил проверку общего лимита трафика (раз в 5 минут)"; }

  # Через rename: bash дочитывает текущий kit по ходу работы, его файл трогать нельзя.
  install -m 755 "$tmp/kit.sh" /usr/local/bin/kit.new && mv -f /usr/local/bin/kit.new /usr/local/bin/kit
  # Новые пути подписки (Clash и JSON) подключает уже новая версия kit.
  /usr/local/bin/kit __subextra >/dev/null 2>&1 || warn "Дополнительные пути подписки не подключились: kit update --force"
  echo
  echo "${G}✓ Готово: 3X-UI KIT $latest.${N} Пользователи, ссылки и подписки не менялись."
  [[ $unattended == yes ]] && return
  local news
  news=$(changelog_of "$latest")
  if [[ -n $news ]]; then echo; echo "${B}Что нового в $latest${N}"; echo "$news"; fi
}

# ---------- проверка и починка ----------

# kit check только читает и показывает, что с сервером. kit fix чинит безопасное: перезапускает
# упавшие службы, возвращает права на файлы, включает автообновление, перечитывает сертификат.
CHECK_BAD=0; CHECK_WARN=0; CHECK_FIX=(); CHECK_QUIET=no; CHECK_DEEP=no
c_ok()   { [[ $CHECK_QUIET == yes ]] || printf '%s\n' "${G}✅${N} $*"; }
c_info() { [[ $CHECK_QUIET == yes ]] || printf '%s\n' "${D}ℹ  $*${N}"; }
c_warn() { printf '%s\n' "${Y}⚠${N}  $*"; CHECK_WARN=$((CHECK_WARN + 1)); }
c_bad()  { printf '%s\n' "${R}❌${N} ${*:2}"; CHECK_BAD=$((CHECK_BAD + 1)); [[ -z $1 ]] || CHECK_FIX+=("$1"); } # код-починки сообщение

# Сайт маскировки отвечает по TLS 1.3 и HTTP/2 (как требует REALITY)? Проверка с самого сервера.
sni_alive() { echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null | grep -q 'ALPN protocol: h2'; }

# Порт подключения открыт? TCP и UDP смотрим отдельно: на 443/tcp сидит nginx, на 443/udp – Hysteria2.
inbound_listens() { # порт tcp|udp|both
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  case $2 in
    tcp) ss -Hltn "sport = :$1" 2>/dev/null | grep -q . ;;
    udp) ss -Hlun "sport = :$1" 2>/dev/null | grep -q . ;;
    *) inbound_listens "$1" tcp && inbound_listens "$1" udp ;;
  esac
}

inbounds_down() { # [список-json] → «имя<TAB>порт<TAB>сеть» включённых подключений, чей порт никто не слушает
  local list=${1:-} name port proto net
  [[ -n $list ]] || list=$(api GET inbounds/list)
  while IFS=$'\t' read -r name port proto; do
    [[ -n $name ]] || continue
    net=$(port_net "$proto")
    inbound_listens "$port" "$net" || printf '%s\t%s\t%s\n' "$name" "$port" "${net/both/tcp+udp}"
  done < <(jq -r '.[] | select(.enable == true) | [.remark, .port, .protocol] | @tsv' <<<"$list")
}

xray_restart_core() { # только ядро, панель не трогаем; если API не ответил – вся служба
  if ! (api POST server/restartXrayService >/dev/null) 2>/dev/null; then
    systemctl restart x-ui; panel_healthy || true
  fi
  sleep 3
}

# Панель 3.9.0 меняет подключение на ходу через API ядра: старое удаляет, а новое с маскировкой Hysteria2
# ядро 26.6.27 не принимает (форматы настроек у панели и ядра разошлись), и порт закрывается. Сама панель
# ядро не перезапускает: config.json уже верный. Поэтому после правки сверяем порты и при нужде перезапускаем ядро.
xray_heal() { # «было-не-слушало» (вывод inbounds_down до правки)
  local before=${1:-} down new
  sleep 1
  down=$(inbounds_down 2>/dev/null) || return 0
  new=$(grep -vxF -f <(printf '%s\n' "$before") <<<"$down" || true)
  [[ -n $new ]] || return 0
  say "Ядро Xray не применило изменение на ходу ($(cut -f1 <<<"$new" | paste -sd, - | sed 's/,/, /g')) – перезапускаю ядро, подключения прервутся на пару секунд."
  xray_restart_core
  down=$(inbounds_down 2>/dev/null) || return 0
  new=$(grep -vxF -f <(printf '%s\n' "$before") <<<"$down" || true)
  [[ -z $new ]] || warn "После перезапуска ядра не слушают: $(cut -f1,2 <<<"$new" | tr '\t' ':' | paste -sd' ' -). Журнал: tail -n 30 /var/log/x-ui/3xui.log"
}

# Ядро Xray запущено и каждое включённое подключение слушает свой порт (при --deep – построчно).
check_xray() {
  local pid list name port proto net total=0 bad=0
  systemctl is-active -q x-ui || return 0 # про службу сказано выше
  pid=$(systemctl show -p MainPID --value x-ui 2>/dev/null || true)
  if [[ $pid =~ ^[1-9][0-9]*$ ]] && pgrep -P "$pid" '^xray-linux-' >/dev/null 2>&1; then c_ok "ядро Xray запущено"
  else c_bad xray "ядро Xray не запущено (причина в журнале: tail -n 30 /var/log/x-ui/3xui.log)"; fi
  list=$(api GET inbounds/list 2>/dev/null) || return 0
  while IFS=$'\t' read -r name port proto; do
    [[ -n $name ]] || continue
    net=$(port_net "$proto"); net=${net/both/tcp+udp}; total=$((total + 1))
    if inbound_listens "$port" "${net/tcp+udp/both}"; then [[ $CHECK_DEEP != yes ]] || c_ok "$name: порт $port/$net слушает"
    else bad=1; c_bad xray "$name: порт $port/$net не слушает (подключение включено, но порт никто не открыл)"; fi
  done < <(jq -r '.[] | select(.enable == true) | [.remark, .port, .protocol] | @tsv' <<<"$list")
  ((bad)) || [[ $CHECK_DEEP == yes ]] || c_ok "все включённые подключения слушают свои порты ($total)"
}

# Подключения за nginx (слушают localhost): карта имён nginx должна совпадать с сайтами в подключениях
# (serverNames у REALITY и XHTTP, fakeTlsDomain у MTProto), а 443/tcp – кто-то слушать.
route_rows() { # «имя<TAB>порт» подключений за nginx
  api GET inbounds/list 2>/dev/null | jq -r '.[] | select(.listen == "127.0.0.1")
    | (.streamSettings | if type == "string" then fromjson else . end) as $st | (.settings | if type == "string" then fromjson else . end) as $se
    | (if .remark == "REALITY" or .remark == "XHTTP" then $st.realitySettings.serverNames[0] elif .protocol == "mtproto" then $se.fakeTlsDomain else null end) as $n
    | select($n != null) | [$n, .port] | @tsv' 2>/dev/null
}

check_routes() {
  local conf=/etc/nginx/kit-stream.conf rows name port bad=0 seen=" " q
  rows=$(route_rows) || return 0
  [[ -n $rows ]] || return 0 # режим с отдельными портами
  if [[ ! -f $conf ]]; then
    c_bad "" "подключения ждут nginx, а его конфига нет (kit-stream.conf): запустите установщик ещё раз: bash 3x-ui.sh"; return 0
  fi
  while IFS=$'\t' read -r name port; do
    [[ $name =~ $SNI_RE && $port =~ ^[0-9]+$ ]] || continue
    # Два подключения с одним именем в карте идут одной строкой (первого из них).
    if [[ $seen == *" $name "* ]]; then q=""; else q="127.0.0.1:$port;"; fi
    seen+="$name "
    if ! awk -v n="$name" -v p="$q" '$1 == n && (p == "" || $2 == p) {f = 1} END {exit !f}' "$conf"; then
      bad=1; c_bad route "карта nginx не знает сайт $name (порт $port): клиенты уйдут на заглушку"
    fi
  done <<<"$rows"
  # Старый процесс nginx работает и со сломанным конфигом, но первая же перезагрузка (или reload) его уронит.
  if ! nginx -t >/dev/null 2>&1; then
    bad=1; c_bad route "конфиг nginx не проходит проверку (nginx -t): сейчас работает прежний, но после перезагрузки nginx не поднимется"
  fi
  if ! inbound_listens 443 tcp; then bad=1; c_bad svc:nginx "порт 443/tcp никто не слушает: подключения за nginx недоступны"; fi
  ((bad)) || c_ok "карта nginx совпадает с сайтами подключений"
}

check_services() {
  local pid u
  if systemctl is-active -q x-ui; then c_ok "служба x-ui работает"; else c_bad svc:x-ui "служба x-ui не работает (journalctl -u x-ui -n 50)"; fi
  if [[ ${SINGLE:-no} == yes ]]; then
    if systemctl is-active -q nginx; then c_ok "nginx работает"; else c_bad svc:nginx "nginx не работает (journalctl -u nginx -n 50)"; fi
  fi
  if [[ -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    if systemctl is-active -q kit-sub; then
      c_ok "служба kit-sub работает"
      pid=$(systemctl show -p MainPID --value kit-sub 2>/dev/null || true)
      u=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)
      if [[ -n $u && $u != root ]]; then c_ok "kit-sub работает не от root (пользователь $u)"; else c_bad "" "kit-sub работает от root – это небезопасно, обновите kit: kit → Обновить kit и подписку"; fi
    else
      c_bad svc:kit-sub "служба kit-sub не работает (journalctl -u kit-sub -n 50)"
    fi
  fi
  if auto_enabled; then c_ok "автообновление включено"
  elif [[ -f $KIT_MANUAL ]]; then c_info "автообновление выключено вами (включить: kit → Автообновление)"
  else c_bad timer "автообновление не включено"; fi
  local novis
  novis=$(api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.remark == "REALITY") | (.settings | if type == "string" then fromjson else . end).clients[]? | select((.flow // "") == "")] | length' 2>/dev/null || echo 0)
  if [[ ${novis:-0} =~ ^[0-9]+$ ]] && ((novis > 0)); then c_info "у $novis польз. в REALITY не включён xtls-rprx-vision (включить: kit → Протоколы, порты и маскировка → Поток vision у REALITY)"; fi
  if limit_timer_enabled; then c_ok "проверка общего лимита трафика включена"
  else c_bad limit "проверка общего лимита трафика не включена (лимит у AmneziaWG считался бы отдельно)"; fi
}

check_versions() {
  local xv pv; xv=$(xray_version || true); pv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)
  c_info "kit $KIT_VERSION, панель 3X-UI ${pv:-?}, ядро Xray ${xv:-?}"
  if [[ -n $xv ]] && newer "$xv" "$XRAY_PIN"; then
    c_warn "ядро Xray $xv новее проверенного (${XRAY_PIN#v}): клиенты на Mihomo и sing-box могут не подключаться к REALITY (kit → Проверка сервера → Исправить безопасное вернёт проверенное)"
    CHECK_FIX+=(core)
  fi
  if [[ -n $pv ]] && newer "v${pv#v}" "$XUI_PIN"; then
    c_warn "панель 3X-UI $pv новее проверенной (${XUI_PIN#v}): часть команд kit может работать иначе"
  elif [[ -n $pv && v${pv#v} != "$XUI_PIN" ]]; then
    c_info "панель 3X-UI $pv, проверена ${XUI_PIN#v}: обновить: kit → Обновить панель 3X-UI"
  fi
  if [[ -s $KIT_LATEST ]] && newer "$(cat "$KIT_LATEST")" "$KIT_VERSION"; then
    c_info "вышла версия $(cat "$KIT_LATEST"): kit → Обновить kit и подписку"
  fi
}

check_cert() {
  local cert end left
  cert=$(awk '$1 == "ssl_certificate" {sub(/;$/, "", $2); print $2; exit}' /etc/nginx/conf.d/kit.conf 2>/dev/null || true)
  [[ -n $cert ]] || cert=$(jq -r '.cert // empty' /etc/kit-sub/config.json 2>/dev/null || true)
  [[ -n $cert ]] || { c_info "сертификат не настроен (режим без TLS)"; return 0; }
  [[ -f $cert ]] || { c_bad cert "файл сертификата $cert из настроек не найден"; return 0; }
  if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
    c_bad cert "сертификат $cert просрочен"
  else
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    left=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
    if openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1; then c_ok "сертификат действителен ещё ~$left дн."
    else c_warn "сертификат истекает меньше чем через сутки: проверьте продление (acme.sh --cron)"; fi
  fi
}

check_exposure() {
  local bind f m bad=0
  # Панель наружу не торчит: за nginx или в режиме «только SSH-туннель».
  if [[ ${SINGLE:-no} == yes || ! -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    bind=$(ss -ltnH "sport = :$XUI_PANEL_PORT" 2>/dev/null | awk '{print $4}' || true)
    if [[ -z $bind ]]; then c_bad "" "панель не слушает порт $XUI_PANEL_PORT"
    elif grep -qv '^127\.0\.0\.1:' <<<"$bind"; then c_bad "" "панель слушает наружу ($(tr '\n' ' ' <<<"$bind")): в настройках 3X-UI укажите адрес 127.0.0.1"
    else c_ok "панель слушает только localhost"; fi
  fi
  if [[ ${SINGLE:-no} == yes ]]; then
    if ss -ltnH 'sport = :443' 2>/dev/null | grep -q .; then c_ok "порт 443/tcp слушается (nginx)"; else c_bad svc:nginx "порт 443/tcp никто не слушает"; fi
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
      if ufw status | grep -Eq '^443/tcp +ALLOW'; then c_ok "ufw пропускает 443/tcp"; else c_bad "" "ufw не пропускает 443/tcp: ufw allow 443/tcp"; fi
    fi
  fi
  for f in /etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json /root/3x-ui.txt /root/cert/*/privkey.pem; do
    [[ -f $f ]] || continue
    m=$(stat -c %a "$f")
    [[ $m == 600 ]] || { c_bad perms "права на $f: $m (нужно 600)"; bad=1; }
  done
  ((bad)) || c_ok "файлы с паролями и ключами доступны только root"
}

# Ответ подписки похож на подписку: для Clash есть proxies, для остальных – ссылки (текстом или в base64).
sub_body_ok() { # файл приложение
  case $2 in
    clash*) grep -q '^proxies:' "$1" ;;
    *) grep -q '://' "$1" || base64 -d "$1" 2>/dev/null | grep -q '://' ;;
  esac
}

check_subscription() {
  local cfg=/etc/kit-sub/config.json port path scheme=http sid ua code size body up sub_cert
  [[ -f $cfg ]] || { c_info "подписка не установлена (режим без сертификата: используйте отдельные ссылки из /root/3x-ui.txt)"; return 0; }
  port=$(jq -r '.port' "$cfg"); path=$(jq -r '.path' "$cfg")
  # Частая поломка: команда «x-ui cert» или меню панели включает TLS у встроенной подписки 3X-UI,
  # а kit-sub ходит к ней по http – подписка перестаёт отвечать.
  up=$(jq -r '.upstream // empty' "$cfg")
  sub_cert=$(api POST setting/all '{}' 2>/dev/null | jq -r '.subCertFile // empty' 2>/dev/null || true)
  if [[ $up == http://* && -n $sub_cert ]]; then
    c_bad subtls "у встроенной подписки 3X-UI включён TLS (сертификат $sub_cert), а kit-sub ходит к ней по http – подписка не отвечает"
  fi
  body=$(mktemp)
  [[ -n $(jq -r '.cert // empty' "$cfg") ]] && scheme=https
  sid=$(clients 2>/dev/null | jq -r '[.[] | .subId // empty | select(. != "")][0] // empty' 2>/dev/null || true)
  [[ -n $sid ]] || { c_info "пользователей нет, подписку проверить нечем"; return 0; }
  for ua in "Happ/1.0" "HiddifyNext/2.0" "v2rayN/7.0" "clash-verge/v2"; do
    : >"$body"
    code=$(curl -sgk -m 10 -A "$ua" -o "$body" -w '%{http_code}' "$scheme://127.0.0.1:$port$path$sid" 2>/dev/null || true)
    size=$(wc -c <"$body" | tr -d ' ')
    if [[ $code == 200 && ${size:-0} -gt 0 ]] && sub_body_ok "$body" "$ua"; then c_ok "подписка отвечает для $ua ($size байт)"
    elif [[ $code == 200 ]]; then c_bad svc:kit-sub "подписка для $ua: ответ 200, но в нём нет ссылок на подключения"
    else c_bad svc:kit-sub "подписка для $ua: HTTP ${code:-нет ответа}"; fi
  done
  rm -f "$body"
  if [[ ${SINGLE:-no} == yes ]]; then
    body=$(mktemp)
    code=$(curl -sk -m 10 -A "Happ/1.0" -o "$body" -w '%{http_code}' "https://127.0.0.1$path$sid" 2>/dev/null || true)
    if [[ $code == 200 ]] && sub_body_ok "$body" "Happ/1.0"; then c_ok "подписка отвечает и через nginx (443)"; else c_bad svc:nginx "подписка через nginx: HTTP ${code:-нет ответа} или ответ без ссылок (ищите причину выше)"; fi
    rm -f "$body"
  fi
}

check_masking() {
  local list line sni target host ips
  list=$(api GET inbounds/list 2>/dev/null) || { c_bad "" "не удалось получить подключения из панели (панель не отвечает?)"; return 0; }
  while IFS=$'\t' read -r name sni target; do
    [[ -n $sni ]] || continue
    if [[ $target == 127.0.0.1:* ]]; then
      ips=$(dns_a "$sni"); host=${HOST:-}
      if [[ -n $ips ]] && grep -qx "$host" <<<"$ips"; then c_ok "$name: свой домен $sni указывает на этот сервер"
      else c_bad "" "$name: свой домен $sni не указывает на этот сервер (A-запись: ${ips:-нет}, нужен $host)"; fi
    elif sni_alive "$sni"; then
      c_ok "$name: сайт маскировки $sni отвечает по TLS 1.3 и HTTP/2"
    else
      c_bad "" "$name: сайт маскировки $sni не отвечает по TLS 1.3 и HTTP/2 – смените его в панели 3X-UI"
    fi
  done < <(jq -r '.[] | select(.protocol == "vless") | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | select($s.security == "reality") | [.remark, ($s.realitySettings.serverNames[0] // ""), ($s.realitySettings.target // "")] | @tsv' <<<"$list" 2>/dev/null || true)
  c_info "Проверка идёт с самого сервера: доступность из вашей сети она не покажет."
}

check_system() {
  local used
  if command -v timedatectl >/dev/null; then
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then c_ok "время синхронизировано"
    else c_warn "время не синхронизировано: при сильном сдвиге TLS и REALITY не работают (kit → Проверка сервера → Исправить безопасное включит синхронизацию)"; CHECK_FIX+=(ntp); fi
  fi
  used=$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
  if ((${used:-0} >= 95)); then c_warn "диск заполнен на ${used}%"; else c_ok "место на диске: занято ${used:-?}%"; fi
}

# Маскировка: известный сайт на чужом IP и запасные порты, которые на посторонний запрос отвечают пустой страницей.
check_stealth() {
  local id kind remark sni names list
  while IFS=$'\t' read -r id kind remark sni; do
    [[ $kind == reality && -n $sni && $sni =~ $SNI_BRAND_RE ]] || continue
    same_net "$sni" || c_warn "$remark: $sni – известный сайт на чужом IP не годится для маскировки. Лучше сосед по подсети: kit → Протоколы, порты и маскировка → Сменить сайт маскировки"
  done < <(sni_targets 2>/dev/null || true)
  list=$(api GET inbounds/list 2>/dev/null) || return 0
  if jq -e 'any(.[]; .protocol == "hysteria" and .enable == true)' <<<"$list" >/dev/null && [[ -z $(hy_masq_state) ]]; then
    c_warn "Hysteria2 на посторонний HTTP/3-запрос отвечает не как сайт. Включить: kit → Протоколы, порты и маскировка → Hysteria2: ответ чужим запросам"
  fi
  if [[ -z $(jq -r '.subJsonDns // ""' <<<"$(api POST setting/all '{}' 2>/dev/null)" 2>/dev/null) ]]; then
    c_warn "DNS в подписке Xray JSON обычный (UDP 8.8.8.8). Включить DoH через прокси: kit → Протоколы, порты и маскировка → DNS в подписках (против утечек)"
  fi
  names=$(jq -r '[.[] | select(.enable == true and .listen != "127.0.0.1" and (.remark == "VLESS-WS" or .remark == "Trojan-gRPC" or .remark == "VMess-WS")) | .remark] | join(", ")' <<<"$list")
  [[ -z $names ]] || c_warn "$names открыты на своих портах и на посторонний запрос отвечают пустой страницей. Не нужны? kit → Протоколы, порты и маскировка → Выключить или включить протокол (режим «всё на 443» прячет их за сайтом)"
}

run_checks() {
  CHECK_BAD=0; CHECK_WARN=0; CHECK_FIX=()
  check_services; check_xray; check_routes; check_grace; check_mtproto; check_versions; check_cert; check_exposure; check_subscription; check_masking; check_stealth; check_system
}

# kit check --deep: подключения проверяются так, как это делает клиент, – с самого сервера.
# Порты (каждое включённое подключение должно слушать) – в check_xray, построчно. Сами подключения: настоящий клиент Xray
# ходит через REALITY (TCP и XHTTP) и Hysteria2 на публичный адрес сервера и открывает страницу через него.

# Отпечаток сертификата Hysteria2 из самого подключения: в ссылке его может не быть (сертификат Let's Encrypt или свой).
deep_hy_pin() {
  local f
  f=$(api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.protocol == "hysteria")][0] | (.streamSettings | if type == "string" then fromjson else . end).tlsSettings.certificates[0].certificateFile // empty' 2>/dev/null || true)
  [[ -r $f ]] && openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
  return 0
}

deep_client_config() { # ссылка порт-socks [отпечаток] → конфиг клиента Xray (печатает JSON); не 0 – проверять нечем
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote
u = urlparse(sys.argv[1]); q = {k: v[0] for k, v in parse_qs(u.query).items()}
if u.scheme == "hysteria2":
    tls = {"serverName": q.get("sni", ""), "alpn": ["h3"], "fingerprint": q.get("fp", "chrome")}
    pin = q.get("pinSHA256") or (sys.argv[3] if len(sys.argv) > 3 else "")
    if not pin:
        sys.exit(1)
    tls["pinnedPeerCertSha256"] = pin
    print(json.dumps({"log": {"loglevel": "none"},
        "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [{"protocol": "hysteria", "settings": {"version": 2, "address": u.hostname, "port": u.port},
            "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls,
                               "hysteriaSettings": {"version": 2, "auth": u.username}}}]}))
    sys.exit(0)
if u.scheme != "vless" or q.get("security") != "reality":
    sys.exit(1)
net = q.get("type", "tcp")
st = {"network": net, "security": "reality", "realitySettings": {
    "serverName": q.get("sni", ""), "fingerprint": q.get("fp", "chrome"), "publicKey": q.get("pbk", ""),
    "shortId": q.get("sid", ""), "spiderX": unquote(q.get("spx", "/"))}}
if net == "xhttp":
    st["xhttpSettings"] = {"path": unquote(q.get("path", "/")), "mode": q.get("mode", "auto")}
user = {"id": u.username, "encryption": "none"}
if q.get("flow"):
    user["flow"] = q["flow"]
print(json.dumps({"log": {"loglevel": "none"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
    "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [user]}]}, "streamSettings": st}]}))
PY
}

# Подключения клиентом, только итог (для проверки до и после обновления панели): 0 – всё подключается.
deep_probe() {
  CHECK_BAD=0; CHECK_WARN=0; CHECK_QUIET=yes
  deep_clients >/dev/null 2>&1 || true
  CHECK_QUIET=no
  ((CHECK_BAD == 0))
}

deep_clients() {
  local xray sid link name cfg port=18080 pid ok tmp hypin
  hypin=$(deep_hy_pin)
  xray=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
  [[ -x $xray ]] || { c_warn "не нашёл Xray панели – подключения не проверил"; return 0; }
  command -v python3 >/dev/null || { c_warn "нет python3 – подключения не проверил"; return 0; }
  sid=$(clients 2>/dev/null | jq -r '[.[] | select(.enable == true and .subId != "") | .subId][0] // empty')
  [[ -n $sid ]] || { c_info "нет включённых пользователей – проверять подключения нечем (kit → Пользователи → Добавить)"; return 0; }
  tmp=$(mktemp -d)
  while IFS= read -r link; do
    name=${link#*@}; name=${name%%\?*}; name=${name##*:}
    if [[ $link == hysteria2://* ]]; then name="Hysteria2 (порт $name/udp)"; elif [[ $link == *type=xhttp* ]]; then name="XHTTP (порт $name)"; else name="REALITY (порт $name)"; fi
    port=$((port + 1)); cfg=$tmp/$port.json
    deep_client_config "$link" "$port" "$hypin" >"$cfg" 2>/dev/null || continue
    "$xray" run -c "$cfg" >/dev/null 2>&1 & pid=$!
    sleep 2; ok=no
    # Ядро панели после смены настроек перезапускается несколько секунд: даём до трёх попыток.
    for _ in 1 2 3; do
      curl -fsS -m 15 --socks5-hostname "127.0.0.1:$port" -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && { ok=yes; break; }
      sleep 3
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    if [[ $ok == yes ]]; then c_ok "$name: клиент подключился к серверу и открыл страницу"
    else c_bad "" "$name: клиент не смог подключиться и открыть страницу (проверьте kit → Протоколы, порты и маскировка → Сменить сайт маскировки, журнал: journalctl -u x-ui -n 30)"; fi
  done < <(collect_links "$sid" '^(vless://.*security=reality|hysteria2://)')
  rm -rf "$tmp"
  c_info "Проверка идёт с самого сервера: доступность из вашей сети она не покажет. Остальные протоколы проверены только по открытому порту."
}

# После успешной kit check --deep: сервер исправен, но проверка шла с него самого. Чем отличить сеть от клиента.
# Страницу по https отдаёт: «всё на 443» – nginx (сайт-заглушка), отдельные порты – kit-sub на порту подписки
# (на корень отвечает «404 Not Found», тоже ответ сервера). Без сертификата веб-страницы нет – проверяем SSH.
deep_hint() {
  local addr=${LINK_HOST:-$HOST} url="" page="страница сайта" port
  if [[ ${SINGLE:-no} == yes ]]; then
    url="https://$addr/"
  else
    port=$(jq -r 'select((.cert // "") != "") | .port // empty' /etc/kit-sub/config.json 2>/dev/null || true)
    [[ $port =~ ^[0-9]{1,5}$ ]] && { url="https://$addr:$port/"; page="страница «404 Not Found» (это ответ сервера, так и задумано)"; }
  fi
  echo
  echo "Сервер в порядке, но эта проверка идёт с самого сервера и доступность из вашей сети не показывает."
  if [[ -n $url ]]; then
    echo "Проверьте с устройства, где не подключается: откройте в браузере ${B}$url${N} (предупреждение о сертификате можно пропустить)."
    echo "  Открылась $page – сервер доступен, смотрите клиент: точное время на телефоне, Hysteria2 вместо TCP-протокола, другое приложение."
    echo "  Не открылась – трафик из этой сети до сервера не доходит: попробуйте другую сеть или другой адрес сервера."
  else
    echo "Проверьте из той сети, где не подключается: ${B}ssh root@$addr${N}."
    echo "  Подключилось – сервер доступен, смотрите клиент: точное время на телефоне, Hysteria2 вместо TCP-протокола, другое приложение."
    echo "  Не подключилось – трафик из этой сети до сервера не доходит: попробуйте другую сеть или другой адрес сервера."
  fi
}

cmd_check() {
  local deep=no
  [[ ${1:-} != --fix ]] || { shift; cmd_fix "$@"; return; }
  [[ ${1:-} != --deep ]] || deep=yes
  [[ -z ${1:-} || $deep == yes ]] || die "Команда: kit check [--deep | --fix]"
  echo "${B}kit check${N} – проверка сервера (ничего не меняет)"
  echo
  CHECK_DEEP=$deep
  # Прежние имена сайта с истёкшим льготным сроком (после kit net site) – единственное, что kit check убирает сам.
  (grace_cleanup) || true
  run_checks
  if [[ $deep == yes ]]; then echo; echo "${B}Подключения${N}"; deep_clients; fi
  echo
  if ((CHECK_BAD == 0)); then
    echo "${G}${B}Всё в порядке.${N}$( ((CHECK_WARN)) && echo " Предупреждений: $CHECK_WARN." || true)"
    [[ $deep == no ]] || deep_hint
  else
    echo "${R}${B}Проблем: $CHECK_BAD.${N} Безопасные исправления: ${B}kit → Проверка сервера → Исправить безопасное${N}."
    return 1
  fi
}

fix_action() { # код
  case $1 in
    svc:x-ui) say "Перезапускаю x-ui"; systemctl restart x-ui; sleep 3 ;;
    svc:nginx)
      if nginx -t >/dev/null 2>&1; then say "Перезапускаю nginx"; systemctl restart nginx
      else warn "Конфиг nginx не проходит проверку (nginx -t) – не трогаю, чтобы не сломать сервер."; fi ;;
    svc:kit-sub) say "Перезапускаю kit-sub"; systemctl restart kit-sub; sleep 2 ;;
    xray) say "Перезапускаю ядро Xray"; xray_restart_core ;;
    subtls)
      say "Убираю сертификат у встроенной подписки 3X-UI (TLS снимает nginx, kit-sub ходит по http)"
      local all upd
      all=$(api POST setting/all '{}')
      upd=$(jq -c '.subCertFile = "" | .subKeyFile = ""' <<<"$all")
      api POST setting/update "$upd" >/dev/null
      systemctl restart x-ui; sleep 4 ;;
    timer) say "Включаю автообновление"; auto_on ;;
    limit) say "Включаю проверку общего лимита трафика"; limit_timer_on ;;
    core) say "Возвращаю проверенное ядро Xray ${XRAY_PIN#v}"; pin_core || true ;;
    perms)
      say "Возвращаю права 600 на файлы с паролями и ключами"
      local f
      for f in /etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json /root/3x-ui.txt /root/cert/*/privkey.pem; do
        if [[ -f $f ]]; then chmod 600 "$f"; fi
      done ;;
    cert)
      if nginx -t >/dev/null 2>&1; then say "Перечитываю сертификат в nginx"; systemctl reload nginx
      else warn "Конфиг nginx не проходит проверку – сертификат не перечитываю."; fi
      warn "Если сертификат всё ещё просрочен, запустите продление: ~/.acme.sh/acme.sh --cron" ;;
    ntp) fix_ntp ;;
    route) fix_route ;;
    mtproto) say "Чиню ссылку и секреты MTProto"; (mt_sync) || warn "Панель не приняла правку MTProto: ссылку берите из kit → Пользователи → Показать ссылки → Telegram" ;;
  esac
}

# Имена в карте nginx – по подключениям (строки ищем по внутреннему порту), с проверкой и откатом.
fix_route() {
  local conf=/etc/nginx/kit-stream.conf name port cbak g
  [[ -f $conf ]] || { warn "Нет $conf – запустите установщик ещё раз."; return 0; }
  # Строки льготных имён (прежний сайт после kit net site) ведут на тот же порт – их не переименовываем.
  g=" $(grace_rows | awk -F'\t' '{printf "%s ", $1}')"
  cbak=$(mktemp); cp -p "$conf" "$cbak"
  grep -q '^[[:space:]]*map_hash_bucket_size' "$conf" || { awk '{print} /^stream \{/ && !d {print "    map_hash_bucket_size 512;"; d=1}' "$conf" >"$conf.n" && cat "$conf.n" >"$conf"; rm -f "$conf.n"; }
  while IFS=$'\t' read -r name port; do
    [[ $name =~ $SNI_RE && $port =~ ^[0-9]+$ ]] || continue
    awk -v n="$name" -v p="127.0.0.1:$port;" -v g="$g" '$2 == p && $1 != "default" && !index(g, " " $1 " ") {printf "        %s %s\n", n, p; next} {print}' "$conf" >"$conf.n" && cat "$conf.n" >"$conf"; rm -f "$conf.n"
  done < <(route_rows)
  say "Сверяю карту nginx с сайтами подключений"
  if nginx -t >/dev/null 2>&1 && systemctl reload nginx; then rm -f "$cbak"
  else cat "$cbak" >"$conf"; rm -f "$cbak"; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; warn "nginx не принял новую карту – вернул прежнюю."; fi
}

# На минимальном Debian 13 нет клиента NTP, и «timedatectl set-ntp» отвечает «NTP not supported».
# Ставим systemd-timesyncd, но только если нет другого.
fix_ntp() {
  say "Включаю синхронизацию времени"
  timedatectl set-ntp true 2>/dev/null && return 0
  if other_ntp_installed; then
    warn "Время синхронизирует другой NTP-клиент (chrony или ntp) – проверьте, что его служба запущена."
    return 0
  fi
  say "Ставлю systemd-timesyncd"
  # timedatectl после установки ещё не видит новую службу, поэтому включаем её напрямую.
  if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq systemd-timesyncd >/dev/null 2>&1 \
      && systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
    return 0
  fi
  warn "Не удалось включить синхронизацию времени. Поставьте клиент вручную: apt install systemd-timesyncd"
}

other_ntp_installed() {
  local p
  for p in chrony ntp ntpsec openntpd; do
    [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == "install ok installed" ]] && return 0
  done
  return 1
}

# Что чинить сейчас: если найдена причина (TLS у подписки), перезапуски kit-sub и nginx – лишь
# следствия: сначала лечим причину, потом проверяем заново.
fix_plan() {
  local c
  while IFS= read -r c; do
    if [[ $c == svc:kit-sub || $c == svc:nginx ]] && printf '%s\n' "${CHECK_FIX[@]}" | grep -qx subtls; then continue; fi
    echo "$c"
  done < <(printf '%s\n' "${CHECK_FIX[@]}" | sort -u)
}

cmd_fix() {
  local dry=no c pass plan
  case ${1:-} in --dry-run) dry=yes ;; "") ;; *) die "kit fix [--dry-run]" ;; esac
  echo "${B}kit fix${N} – безопасные исправления (службы, права, автообновление, сертификат, время)"
  echo
  CHECK_QUIET=yes; run_checks; CHECK_QUIET=no
  if ((${#CHECK_FIX[@]} == 0)); then
    if ((CHECK_BAD == 0)); then echo "${G}Чинить нечего: всё в порядке.${N}"; return 0; fi
    echo; echo "${Y}Автоматически эти проблемы не исправить, они описаны выше. Подробности: kit → Проверка сервера → Быстрая проверка${N}"; return 1
  fi
  if [[ $dry == yes ]]; then
    while IFS= read -r c; do echo "  будет сделано: $c"; done < <(fix_plan)
    return 0
  fi
  for pass in 1 2; do
    plan=$(fix_plan)
    [[ -n $plan ]] || break
    while IFS= read -r c; do fix_action "$c"; done <<<"$plan"
    CHECK_QUIET=yes; run_checks; CHECK_QUIET=no
    ((${#CHECK_FIX[@]})) || break
  done
  echo; echo "${B}Повторная проверка${N}"; echo
  run_checks
  echo
  if ((CHECK_BAD == 0)); then echo "${G}${B}Готово: всё в порядке.${N}"; else echo "${R}Осталось проблем: $CHECK_BAD.${N} Часть из них нужно решать вручную (см. выше)."; return 1; fi
}

# ---------- резервная копия ----------

# Что входит в копию: база панели (пользователи,
# ключи, подключения), настройки kit и kit-sub, nginx, сайт-заглушка, свои сертификаты.
# Сертификаты Let's Encrypt (на IP и на свой домен) не берём: на новом сервере он выпускается заново.
BACKUP_PATHS=(/etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json /etc/kit-sub/rules.yaml
  /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf /var/www/kit /root/cert/self /root/cert/custom /root/3x-ui.txt)

# Вернуть проверенное ядро Xray (панель 3.9 иногда отвечает ошибкой GitHub API, хотя ядро заменено, поэтому смотрим на версию).
pin_core() {
  local cur="" i
  (api POST "server/installXray/$XRAY_PIN" '{}' >/dev/null) 2>/dev/null || true
  for i in $(seq 1 30); do
    cur=$(xray_version || true)
    [[ $cur == "$XRAY_PIN" ]] && return 0
    sleep 2
  done
  warn "Не удалось вернуть ядро Xray $XRAY_PIN (сейчас ${cur:-?})."
  return 1
}

panel_healthy() { # ждём ответа панели до 60 секунд
  local i
  for i in $(seq 1 30); do
    curl -fsk -m 5 -o /dev/null -H @<(printf 'Authorization: Bearer %s\n' "$XUI_API_TOKEN") "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

# Обновление панели до проверенной версии. Делает только безопасную часть официального обновления:
# проверенный архив, замена файлов панели, миграция базы. Не трогает ядро Xray, сертификаты и настройки
# (официальный update.sh при отсутствии сертификата сам выпускает его и включает TLS, меняет ядро и ставит fail2ban).
panel_update() {
  local force=no a arch cur target=${XUI_PIN#v} tmp ts bak got want os_id keep_core
  for a in "$@"; do
    case $a in
      --force) force=yes ;;
      *) die "kit panel update [--force]" ;;
    esac
  done
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "Обновление панели умеет только amd64 и arm64." ;; esac
  cur=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)
  [[ -n $cur ]] || die "Не удалось узнать версию панели."
  cur=${cur#v}
  if [[ $cur == "$target" && $force == no ]]; then
    say "Панель уже $target: это проверенная версия."
    return 0
  fi
  if newer "v$cur" "$XUI_PIN" && [[ $force == no ]]; then
    die "У вас панель $cur новее проверенной $target. Откат не поддерживается; если что-то не работает, пришлите вывод kit → Проверка сервера → Быстрая проверка."
  fi
  say "Обновляю панель 3X-UI $cur → $target (настройки, пользователи и ядро Xray сохраняются)"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу
  trap "rm -rf -- '$tmp'" EXIT

  # 1. Архив и скрипт меню – только с совпавшей зашитой суммой.
  spin_start "Скачиваю панель 3X-UI"
  curl -fL --retry 3 -m 600 -o "$tmp/x-ui.tar.gz" "https://github.com/MHSanaei/3x-ui/releases/download/$XUI_PIN/x-ui-linux-$arch.tar.gz" 2>/dev/null \
    || die "Не удалось скачать панель с GitHub. Сервер не тронут."
  spin_stop
  got=$(sha256sum "$tmp/x-ui.tar.gz" | awk '{print $1}'); want=${XUI_TARBALL_SHA256[$arch]}
  [[ $got == "$want" ]] || die "Архив панели не совпал с проверенным (SHA256) – не ставлю. Сервер не тронут."
  curl -fsSL --retry 3 -m 60 -o "$tmp/x-ui.sh" "https://raw.githubusercontent.com/MHSanaei/3x-ui/$XUI_PIN/x-ui.sh" \
    || die "Не удалось скачать x-ui.sh. Сервер не тронут."
  [[ $(sha256sum "$tmp/x-ui.sh" | awk '{print $1}') == "$XUI_SH_SHA256" ]] || die "Скрипт меню x-ui не совпал с проверенным (SHA256) – не ставлю. Сервер не тронут."
  tar tzf "$tmp/x-ui.tar.gz" | grep -qE '^/|(^|/)\.\.(/|$)' && die "В архиве панели странные пути – не ставлю."
  tar xzf "$tmp/x-ui.tar.gz" -C "$tmp"
  [[ -s $tmp/x-ui/x-ui ]] || die "В архиве панели нет x-ui. Сервер не тронут."

  # Подключения клиентом до обновления: если они работали, после обновления должны работать так же, иначе вернём прежнюю панель.
  local pre=no
  deep_probe && pre=ok
  # 2. Копия на случай отката (база снимается средствами SQLite).
  ts=$(date +%Y%m%d-%H%M); bak=/root/x-ui-before-update-$ts
  install -d -m 700 "$bak/etc-x-ui"
  cp -a /usr/local/x-ui "$bak/usr-local-x-ui"
  cp -a /etc/x-ui/. "$bak/etc-x-ui/"
  cp -a /etc/systemd/system/x-ui.service "$bak/x-ui.service" 2>/dev/null || true
  cp -a /usr/bin/x-ui "$bak/x-ui.sh" 2>/dev/null || true
  python3 - /etc/x-ui/x-ui.db "$bak/x-ui.db" <<'PY' || die "Не удалось сохранить копию базы. Сервер не тронут."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PY
  say "Копия прежней панели: $bak"

  # 3. Замена файлов. Ядро Xray (проверенное) оставляем: берём его из прежней установки.
  keep_core=$tmp/xray.keep
  cp -a "/usr/local/x-ui/bin/xray-linux-$arch" "$keep_core"
  systemctl stop x-ui
  pkill -f 'mtg-linux-[^ ]* run ' >/dev/null 2>&1 || true
  install -m 755 "$tmp/x-ui/x-ui" /usr/local/x-ui/x-ui.new && mv -f /usr/local/x-ui/x-ui.new /usr/local/x-ui/x-ui
  for f in "$tmp"/x-ui/bin/*; do
    case ${f##*/} in xray-linux-*) continue ;; esac
    cp -af "$f" /usr/local/x-ui/bin/
  done
  install -m 755 "$keep_core" "/usr/local/x-ui/bin/xray-linux-$arch"
  chmod +x "/usr/local/x-ui/bin/mtg-linux-$arch" 2>/dev/null || true
  rm -rf /usr/local/x-ui/bin/tuic-server /usr/local/x-ui/bin/tuic   # TUIC теперь встроен в панель
  install -m 755 "$tmp/x-ui.sh" /usr/local/x-ui/x-ui.sh
  install -m 755 "$tmp/x-ui.sh" /usr/bin/x-ui.new && mv -f /usr/bin/x-ui.new /usr/bin/x-ui
  os_id=$(. /etc/os-release && echo "${ID:-}")
  case $os_id in
    ubuntu | debian) [[ -f $tmp/x-ui/x-ui.service.debian ]] && install -m 644 "$tmp/x-ui/x-ui.service.debian" /etc/systemd/system/x-ui.service ;;
    *) warn "Файл службы не менял (система $os_id): оставил прежний." ;;
  esac
  chown -R root:root /usr/local/x-ui
  [[ -f /usr/local/x-ui/bin/config.json ]] && chmod 640 /usr/local/x-ui/bin/config.json
  systemctl daemon-reload
  /usr/local/x-ui/x-ui migrate >/dev/null 2>&1 || true
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl start x-ui

  # 4. Проверка и откат при провале.
  if panel_healthy && [[ $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1) == "$target" ]] && { [[ $pre != ok ]] || { sleep 5; deep_probe; }; }; then
    systemctl is-active -q x-ui || true
    say "Панель обновлена до $target, ядро Xray ${XRAY_PIN#v} осталось."
    [[ $pre == ok ]] && say "Подключения клиентом после обновления работают (REALITY, XHTTP, Hysteria2)."
    echo "Копию прежней панели можно удалить, когда убедитесь, что всё работает: rm -rf $bak"
    echo "Проверить сервер: ${B}kit → Проверка сервера → Быстрая проверка${N}"
    return 0
  fi
  warn "Панель после обновления не отвечает или подключения клиентом не работают – возвращаю прежнюю."
  systemctl stop x-ui || true
  rm -rf /usr/local/x-ui && cp -a "$bak/usr-local-x-ui" /usr/local/x-ui
  cp -a "$bak/etc-x-ui/." /etc/x-ui/
  [[ -f $bak/x-ui.service ]] && cp -a "$bak/x-ui.service" /etc/systemd/system/x-ui.service
  [[ -f $bak/x-ui.sh ]] && install -m 755 "$bak/x-ui.sh" /usr/bin/x-ui
  systemctl daemon-reload; systemctl start x-ui || true
  die "Обновление не удалось, прежняя панель восстановлена ($cur). Копия: $bak. Лог: journalctl -u x-ui -n 50"
}

cmd_backup() {
  local out tmp p ssl=none c
  out=/root/kit-backup-$(date +%Y%m%d-%H%M).tar.gz
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  install -d -m 700 "$tmp/etc/x-ui"
  # Снимок базы средствами SQLite: панель продолжает работать, копия целая.
  python3 - /etc/x-ui/x-ui.db "$tmp/etc/x-ui/x-ui.db" <<'PY' || die "Не удалось скопировать базу панели."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
  # Льготные имена сайта (после kit net site) в копию не берём: на новом сервере карта nginx собирается без них.
  local -a gargs=()
  mapfile -t gargs < <(grace_rows | awk -F'\t' '{print $2 ":" $1}')
  if ((${#gargs[@]})); then
    python3 - "$tmp/etc/x-ui/x-ui.db" "${gargs[@]}" <<'PY' || warn "Не удалось убрать из копии прежние имена сайта. Лучше так: kit → Протоколы, порты и маскировка → Убрать прежние имена сайта, затем kit → Резервная копия ещё раз."
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for a in sys.argv[2:]:
    i, n = a.split(":", 1)
    row = db.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (int(i),)).fetchone()
    try:
        s = json.loads(row[0])
        names = s["realitySettings"]["serverNames"]
    except Exception:
        continue
    if isinstance(names, list) and n in names[1:]:
        s["realitySettings"]["serverNames"] = names[:1] + [x for x in names[1:] if x != n]
        db.execute("UPDATE inbounds SET stream_settings = ? WHERE id = ?", (json.dumps(s, ensure_ascii=False, indent=2), int(i)))
db.commit(); db.close()
PY
  fi
  # cp --parents с абсолютным путём падает («No such file»), если команду запустили не из «/» (например, из /root): копируем из корня.
  for p in "${BACKUP_PATHS[@]}"; do if [[ -e $p ]]; then (cd / && cp -a --parents "${p#/}" "$tmp"); fi; done
  # Какой сертификат был у панели и подписки – новый сервер должен получить такой же.
  c=$(jq -r '.cert // empty' /etc/kit-sub/config.json 2>/dev/null || true)
  [[ -z $c && -f /etc/nginx/conf.d/kit.conf ]] && c=$(awk '$1 == "ssl_certificate" {sub(/;$/, "", $2); print $2; exit}' /etc/nginx/conf.d/kit.conf)
  case $c in
    /root/cert/ip/*) ssl=ip ;;
    /root/cert/custom/*) ssl=custom ;;
  esac
  {
    printf 'BACKUP_KIT_VERSION=%q\n' "$KIT_VERSION"
    printf 'BACKUP_HOST=%q\n' "$HOST"
    printf 'BACKUP_SSL=%q\n' "$ssl"
    printf 'BACKUP_DATE=%q\n' "$(date +%F)"
  } >"$tmp/kit-backup.env"
  (umask 077; tar -czf "$out" -C "$tmp" .)
  chmod 600 "$out"
  say "Резервная копия: ${B}$out${N} ($(du -h "$out" | cut -f1))"
  echo
  echo "В ней ключи и пароли от сервера, храните её как пароль. Скачать к себе (на компьютере):"
  echo "  ${B}scp root@$HOST:$out .${N}"
  echo
}

# ---------- сайт маскировки: kit sni ----------

SNI_POOL=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com www.microsoft.com www.cloudflare.com)

# --- поиск сайта-прикрытия среди соседей по подсети (общий код kit и установщика) ---

SNI_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# Бесплатные и динамические имена (sslip.io, work.gd и т. п.) часто используют чужие прокси-серверы: под них маскироваться не стоит.
SNI_DYN_RE='(^|\.)(sslip\.io|nip\.io|xip\.io|traefik\.me|work\.gd|duckdns\.org|ddns\.net|hopto\.org|zapto\.org|myftp\.biz|dynu\.net|freeddns\.org|no-ip\.(org|biz|info)|nom\.za|tk|ml|ga|cf|gq)$'
# Известные сайты на чужом IP не подходят: сайт для маскировки должен быть «своим» для подсети сервера.
SNI_BRAND_RE='(^|\.)(google|googleapis|gstatic|youtube|microsoft|windows|apple|icloud|amazon|amazonaws|samsung|yahoo|cloudflare|facebook|instagram|netflix|github|telegram)\.[a-z.]+$'

# Имена с «сомнительными» словами не берём: брать такой сайт для маскировки неприятно и небезопасно для вас.
SNI_BAD_RE='(probiv|porn|xxx|sex|adult|casino|bet|vpn|proxy|torrent|crack|hack|warez|drug|weapon|leak|escort|gambl|poker)'

# У сайта настоящий сертификат: цепочка проходит проверку, имя совпадает.
sni_trusted() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -verify_hostname "$1" -verify_return_error 2>/dev/null | grep -q 'Verification: OK'
}

# На «/» отвечает страница (2xx) или переход на этот же сайт; не за Cloudflare, не переход на чужой сайт.
sni_quality() {
  local out code loc
  out=$(curl -sS -m 10 -o /dev/null -D- "https://$1/" 2>/dev/null | tr -d '\r') || return 1
  code=$(awk 'NR == 1 {print $2}' <<<"$out")
  grep -qiE '^(server: cloudflare|cf-ray:)' <<<"$out" && return 1
  case $code in
    2??) return 0 ;;
    3??) loc=$(awk 'tolower($1) == "location:" {print $2; exit}' <<<"$out"); [[ $loc == /* || $loc =~ ^https?://(www\.)?${1#www.}(/|:|$) ]] ;;
    *) return 1 ;;
  esac
}

host_ip() { # IPv4 сервера
  local h=${HOST:-}
  if [[ $h =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$h"; else getent ahostsv4 "$h" 2>/dev/null | awk 'NR == 1 {print $1}'; fi
}

# Тот же блок /23 (две соседние /24), что и у сервера.
same_net() { # имя
  local me ip a b c x y z
  me=$(host_ip); [[ -n $me ]] || return 1
  IFS=. read -r a b c _ <<<"$me"
  while read -r ip; do
    [[ -n $ip ]] || continue
    IFS=. read -r x y z _ <<<"$ip"
    [[ $x == "$a" && $y == "$b" && $((z >> 1)) == $((c >> 1)) ]] && return 0
  done < <(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  return 1
}

# Имена из сертификатов соседних адресов /24: заходим на 443 без имени и читаем subjectAltName.
nearby_scan() { # основа "a.b.c"
  local me; me=$(host_ip)
  seq 1 254 | xargs -P 8 -I{} bash -c '
      ip=$1; [ "$ip" = "$2" ] && exit 0
      echo | timeout 4 openssl s_client -connect "$ip:443" -tls1_3 -alpn h2 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | tr "," "\n" | sed -n "s/^ *DNS://p"' _ "$1.{}" "$me" 2>/dev/null | sort -u | grep -E "$SNI_RE" | head -40 || true
}

# Подходящие сайты: сначала в /24 сервера, если пусто – во втором /24 того же /23. До 8 имён.
nearby_sites() {
  local me a b c base n names found=0
  set +e; trap - ERR   # выполняется в подпроцессе: сбой одной проверки не должен обрывать поиск
  me=$(host_ip)
  [[ $me =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
  IFS=. read -r a b c _ <<<"$me"
  for base in "$a.$b.$c" "$a.$b.$((c ^ 1))"; do
    names=$(nearby_scan "$base")
    for n in $names; do
      [[ $n == "$me" || $n =~ $SNI_DYN_RE || $n =~ $SNI_BRAND_RE || $n =~ $SNI_BAD_RE ]] && continue
      if same_net "$n" && sni_alive "$n" && sni_trusted "$n" && sni_quality "$n"; then echo "$n"; found=$((found + 1)); ((found >= 8)) && return 0; fi
    done
    ((found > 0)) && return 0
  done
  return 0
}

# Подключения, у которых есть сайт маскировки: id, вид (reality, mtproto, self – свой домен), название, сайт.
sni_targets() {
  api GET inbounds/list | jq -r '.[] | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | (.settings | if type == "string" then fromjson else . end) as $c
    | if .protocol == "vless" and $s.security == "reality" then
        [.id, (if (($s.realitySettings.target // "") | startswith("127.0.0.1:")) then "self" else "reality" end), .remark, ($s.realitySettings.serverNames[0] // "")]
      elif .protocol == "mtproto" then [.id, "mtproto", .remark, ($c.fakeTlsDomain // "")]
      else empty end | @tsv'
}

sni_body() { # id вид новый-сайт [льготные имена, JSON-массив] → тело для inbounds/update
  api GET inbounds/list | jq -c --argjson id "$1" --arg k "$2" --arg n "$3" --argjson g "${4:-[]}" '.[] | select(.id == $id)
    | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | (.settings | if type == "string" then fromjson else . end) as $c
    | (if $k == "reality" then ($s | .realitySettings.serverNames = ([$n] + ($g - [$n])) | .realitySettings.target = ($n + ":443")) else $s end) as $s2
    | (if $k == "mtproto" then ($c | .fakeTlsDomain = $n) else $c end) as $c2
    | {id, remark, enable, listen, port, protocol, expiryTime, total, settings: ($c2 | tojson), streamSettings: ($s2 | tojson),
       sniffing: (.sniffing | if type == "string" then . else tojson end)}'
}

# --- льготный срок для прежнего сайта (REALITY, XHTTP, REALITY-2) ---
# После kit net site у приложений ещё старая подписка с прежним именем сайта. Прежнее имя SNI_GRACE_DAYS дней остаётся
# в serverNames подключения и в карте nginx (на тот же внутренний порт), потом kit убирает его сам. MTProto – без льгот.
# Состояние – SNI_GRACE (только root). Панель берёт имя для ссылки случайно из serverNames, поэтому kit-sub получает
# карту «прежнее имя → нынешнее» (SNI_GRACE_SUB, только имена сайтов) и в подписку отдаёт нынешнее.
SNI_GRACE=/etc/kit/sni-grace.json
SNI_GRACE_SUB=/etc/kit-sub/sni-grace.json
SNI_GRACE_DAYS=7
SNI_GRACE_MAX=3

grace_rows() { # → «имя<TAB>id<TAB>до» из файла состояния, только строки, прошедшие проверку
  local name id until
  [[ -f $SNI_GRACE ]] || return 0
  while IFS=$'\t' read -r name id until; do
    [[ ${#name} -le 253 && $name =~ $SNI_RE && $id =~ ^[0-9]{1,9}$ && $until =~ ^[0-9]{1,12}$ ]] && printf '%s\t%s\t%s\n' "$name" "$id" "$until"
  done < <(jq -r '.[]? | select(type == "object") | [(.name // "" | tostring), (.inbound_id // "" | tostring), (.until // "" | tostring)] | @tsv' "$SNI_GRACE" 2>/dev/null || true)
  return 0
}

# Строки на входе → без истёкших, чужих подключений и исключённых имён, без дублей, не больше SNI_GRACE_MAX на подключение (новые важнее).
grace_merge() { # сейчас «id id…» «имя имя…»
  awk -F'\t' -v now="$1" -v ids=" $2 " -v skip=" $3 " 'NF == 3 && $3 + 0 > now + 0 && index(ids, " " $2 " ") && !index(skip, " " $1 " ") {
      k = $1 "\t" $2; if (!(k in u) || $3 + 0 > u[k] + 0) u[k] = $3 }
    END {for (k in u) print k "\t" u[k]}' | sort -t$'\t' -k2,2n -k3,3nr | awk -F'\t' -v max="$SNI_GRACE_MAX" '++c[$2] <= max'
}

grace_json() { # id < строки → JSON-массив льготных имён подключения
  awk -F'\t' -v id="$1" '$2 == id {print $1}' | jq -R . | jq -sc .
}

grace_gone() { # «было» «стало» «имя имя…» → имена из «было», которых нет в «стало» и в списке (для карты nginx)
  awk -F'\t' -v skip=" $3 " 'NR == FNR {if (NF == 3) k[$1] = 1; next} NF == 3 && !($1 in k) && !index(skip, " " $1 " ") && !s[$1]++ {print $1}' \
    <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

map_drop() { # файл имя… – убирает из карты nginx строки с этими именами
  local f=$1 t
  shift
  (($#)) || return 0
  t=$(mktemp)
  awk -v d=" $* " '$2 ~ /^127\.0\.0\.1:[0-9]+;$/ && index(d, " " $1 " ") {next} {print}' "$f" >"$t" && cat "$t" >"$f"
  rm -f "$t"
}

# Запись атомарно (tmp + mv): состояние – 600, карта для kit-sub (имена сайтов, не секрет) – 644. Пустой список – файлы убираются.
grace_save() { # < строки
  local rows tmp map
  rows=$(awk -F'\t' 'NF == 3')
  if [[ -z $rows ]]; then rm -f "$SNI_GRACE" "$SNI_GRACE_SUB"; return 0; fi
  install -d -m 700 "${SNI_GRACE%/*}"
  tmp=$(mktemp "${SNI_GRACE%/*}/.sni-grace.XXXXXX")
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], inbound_id: (.[1] | tonumber), until: (.[2] | tonumber)})' <<<"$rows" >"$tmp" \
    && chmod 600 "$tmp" && mv -f "$tmp" "$SNI_GRACE" || { rm -f "$tmp"; return 1; }
  [[ -d ${SNI_GRACE_SUB%/*} ]] || return 0
  map=$(api GET inbounds/list | jq -c --argjson r "$(grace_to_json <<<"$rows")" '
    [.[] | {id, p: ((.streamSettings | if type == "string" then (try fromjson catch {}) else . end).realitySettings.serverNames[0]? // "")}] as $ps
    | reduce $r[] as $e ({}; (($ps | map(select(.id == $e.inbound_id))[0].p) // "") as $p
        | if ($p | test("\\A[A-Za-z0-9.-]{1,253}\\z")) and $p != $e.name and (has($e.name) | not) then .[$e.name] = $p else . end)') || return 1
  tmp=$(mktemp "${SNI_GRACE_SUB%/*}/.sni-grace.XXXXXX")
  printf '%s\n' "$map" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$SNI_GRACE_SUB" || { rm -f "$tmp"; return 1; }
}
grace_to_json() { jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], inbound_id: (.[1] | tonumber)})'; }

# Ссылки на входе: у REALITY льготное имя сайта → нынешнее (панель выбирает имя для ссылки случайно).
grace_links() {
  local o n m=" "
  while IFS=$'\t' read -r o n; do
    [[ $o =~ $SNI_RE && $n =~ $SNI_RE ]] && m+="$o=$n "
  done < <(jq -r 'to_entries[]? | [.key, .value] | @tsv' "$SNI_GRACE_SUB" 2>/dev/null || true)
  awk -v m="$m" 'BEGIN {c = split(m, a, " "); for (i = 1; i <= c; i++) {split(a[i], p, "="); g[p[1]] = p[2]}}
    /^vless:\/\// && /security=reality/ && match($0, /[?&]sni=[^&#]*/) {
      s = substr($0, RSTART + 5, RLENGTH - 5); if (s in g) $0 = substr($0, 1, RSTART + 4) g[s] substr($0, RSTART + RLENGTH) }
    {print}'
}

# Убирает льготные имена с истёкшим сроком (all – все сразу): из подключений, затем из карты nginx (nginx -t, откат при ошибке).
grace_cleanup() { # [all]
  [[ -f $SNI_GRACE ]] || return 0
  local now rows keep id kind remark sni ids="" prim="" d conf=/etc/nginx/kit-stream.conf cbak gone_names
  local -a pids=() pnames=() ngx=()
  now=$(date +%s); [[ ${1:-} != all ]] || now=999999999999
  rows=$(grace_rows)
  while IFS=$'\t' read -r id kind remark sni; do
    [[ $kind == reality && $id =~ ^[0-9]+$ ]] && ids+="$id "
    [[ -z $sni ]] || prim+="$sni "
  done < <(sni_targets)
  keep=$(grace_merge "$now" "$ids" "$prim" <<<"$rows")
  # Что уходит: по подключениям (для serverNames) и именами (для карты nginx).
  for id in $ids; do
    d=$(awk -F'\t' 'NR == FNR {k[$1 "\t" $2] = 1; next} NF == 3 && !(($1 "\t" $2) in k) {print}' <(printf '%s\n' "$keep") <(printf '%s\n' "$rows") | grace_json "$id")
    [[ $d != '[]' ]] || continue
    pids+=("$id"); pnames+=("$d")
  done
  while IFS= read -r d; do [[ -z $d ]] || ngx+=("$d"); done < <(grace_gone "$rows" "$keep" "$prim")
  if ((${#pids[@]} == 0 && ${#ngx[@]} == 0)); then
    [[ ${1:-} != all ]] || { grace_save <<<"$keep"; say "Прежних имён сайта нет – убирать нечего."; }
    return 0
  fi
  grace_unpatch() { # вернуть имена в подключения, уже изменённые до сбоя
    local j
    for ((j = 0; j < $1; j++)); do
      inbound_patch "${pids[$j]}" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.serverNames |= (. + ($d - .)))' --argjson d "${pnames[$j]}" \
        || warn "Не удалось вернуть прежнее имя в подключение ${pids[$j]}."
    done
  }
  local i
  for ((i = 0; i < ${#pids[@]}; i++)); do
    if ! inbound_patch "${pids[$i]}" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.serverNames |= (.[0:1] + (.[1:] - $d)))' --argjson d "${pnames[$i]}"; then
      grace_unpatch "$i"; warn "Панель не приняла правку – прежние имена сайта пока остаются."; return 1
    fi
  done
  if [[ ${SINGLE:-no} == yes && -f $conf ]] && ((${#ngx[@]})); then
    cbak=$(mktemp); cp -p "$conf" "$cbak"
    map_drop "$conf" "${ngx[@]}"
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx; then
      cat "$cbak" >"$conf"; rm -f "$cbak"; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
      grace_unpatch "${#pids[@]}"
      warn "nginx не принял карту без прежних имён – всё оставил как было."; return 1
    fi
    rm -f "$cbak"
  fi
  grace_save <<<"$keep" || warn "Не удалось записать $SNI_GRACE."
  gone_names=$(awk -F'\t' 'NR == FNR {k[$1] = 1; next} NF == 3 && !($1 in k) && !s[$1]++ {printf "%s%s", (n++ ? ", " : ""), $1}' <(printf '%s\n' "$keep") <(printf '%s\n' "$rows"))
  [[ -z $gone_names ]] || say "Убрал прежние имена сайта маскировки: $gone_names"
}

check_grace() {
  local name id until
  while IFS=$'\t' read -r name id until; do
    c_info "прежнее имя сайта $name ещё работает до $(date -d "@$until" '+%d.%m %H:%M' 2>/dev/null || echo "$until") (после kit → Протоколы, порты и маскировка → Сменить сайт маскировки, потом уберу сам; сейчас: kit → Протоколы, порты и маскировка → Убрать прежние имена сайта)"
  done < <(grace_rows | sort -t$'\t' -k1,1 -u)
}

sni_show() {
  local id kind remark sni mark
  say "Сайты маскировки (сервер: ${HOST:-?})"
  while IFS=$'\t' read -r id kind remark sni; do
    [[ -n $sni ]] || continue
    if [[ $kind == self ]]; then mark="свой домен"
    elif same_net "$sni"; then mark="из подсети сервера"
    else mark="чужая подсеть"; fi
    printf '  %-10s %-28s %s\n' "$remark" "$sni" "$mark"
  done < <(sni_targets)
  echo
  echo "Сменить сайт (подберётся сам или укажите свой): ${B}kit → Протоколы, порты и маскировка → Сменить сайт маскировки${N}"
}

sni_rotate() { # [--nearby] [--dry-run] [сайт]
  local nearby=no dry=no site="" a
  while (($#)); do
    case $1 in
      --nearby) nearby=yes ;;
      --dry-run) dry=yes ;;
      -*) die "Неизвестный параметр $1. Команда: kit sni rotate [--nearby] [--dry-run] [сайт]" ;;
      *) site=${1,,}; [[ $site =~ $SNI_RE ]] || die "Нужно имя сайта, например dl.google.com (без https://)." ;;
    esac
    shift
  done
  local -a ids=() kinds=() remarks=() olds=() news=() pool=()
  local id kind remark sni until
  # Занятые имена и чьи они: сайты всех подключений (и свой домен REALITY), льготные имена, строки карты nginx.
  # Новое имя не должно совпасть ни с одним: дубль ключа nginx не примет, а общий ключ увёл бы чужое подключение.
  local -A owner=() graceid=()
  while IFS=$'\t' read -r id kind remark sni; do
    [[ -n $sni ]] || continue
    [[ $kind == self ]] && owner[$sni]=${owner[$sni]:-"$remark (свой домен)"}
    [[ $kind == self ]] && continue
    owner[$sni]=${owner[$sni]:-$remark}
    ids+=("$id"); kinds+=("$kind"); remarks+=("$remark"); olds+=("$sni")
  done < <(sni_targets)
  ((${#ids[@]})) || die "Нет подключений, у которых можно сменить сайт маскировки (при своём домене маскировка уже под ваш сайт)."
  while IFS=$'\t' read -r sni id until; do
    ((until > $(date +%s))) || continue
    [[ -n ${owner[$sni]:-} ]] || { owner[$sni]="прежнее имя сайта (льготный срок)"; graceid[$sni]=$id; }
  done < <(grace_rows)
  if [[ ${SINGLE:-no} == yes && -f /etc/nginx/kit-stream.conf ]]; then
    while read -r sni; do
      [[ $sni =~ $SNI_RE ]] && owner[$sni]=${owner[$sni]:-"другое подключение (карта nginx)"}
    done < <(awk '$2 ~ /^127\.0\.0\.1:[0-9]+;$/ && $1 != "default" {print $1}' /etc/nginx/kit-stream.conf)
  fi
  sni_taken() { # имя индекс-подключения → 0, если имя занято (своё льготное имя подключения – свободно)
    local a
    for a in "${news[@]}"; do [[ $a == "$1" ]] && return 0; done
    [[ -n ${owner[$1]:-} ]] || return 1
    [[ ${graceid[$1]:-} != "${ids[$2]}" ]]
  }
  if [[ -n $site ]] && sni_taken "$site" 0; then
    if [[ ${owner[$site]} == *"(свой домен)" ]]; then
      die "Это имя уже использует ${owner[$site]}. XHTTP и MTProto нужны отдельные сайты: оставьте автоподбор (kit → Протоколы, порты и маскировка → Сменить сайт маскировки) или укажите другой."
    fi
    die "Это имя уже использует ${owner[$site]}. Каждому подключению нужен отдельный сайт: оставьте автоподбор (kit → Протоколы, порты и маскировка → Сменить сайт маскировки) или укажите другой."
  fi

  [[ -z $site ]] || { pool+=("$site"); }
  if [[ $nearby == yes ]]; then
    say "Ищу сайты в подсети сервера (около 250 коротких подключений к порту 443 соседних адресов)"
    spin_start "Опрашиваю соседние адреса"
    while read -r a; do [[ -n $a ]] && pool+=("$a"); done < <(nearby_sites)
    spin_stop
    if ((${#pool[@]} == 0)); then
      warn "В подсети подходящего сайта не нашёл. Известный сайт на чужом IP подходит хуже остальных."
      echo "  Лучший выход – свой домен (установка с --domain) или другой сайт: kit → Протоколы, порты и маскировка → Сменить сайт маскировки"
      if [[ -t 0 ]]; then
        ask_tty "  Взять запасной сайт из списка? [y/N] "
        [[ $REPLY =~ ^[yYдД]$ ]] || { echo "Отменено."; return 0; }
      fi
    fi
  fi
  pool+=("${SNI_POOL[@]}")

  local c i
  for i in "${!ids[@]}"; do
    for c in "${pool[@]}"; do
      ! sni_taken "$c" "$i" || continue
      if sni_alive "$c"; then news+=("$c"); break; fi
      [[ $c == "$site" ]] && die "$c не отвечает по TLS 1.3 + HTTP/2 – REALITY с ним работать не будет."
    done
    [[ -n ${news[$i]:-} ]] || die "Не нашёл свободный сайт для ${remarks[$i]}: все из списка заняты или не отвечают по TLS 1.3 + HTTP/2. Укажите свой: kit → Протоколы, порты и маскировка → Сменить сайт маскировки"
  done

  echo "${B}Было → станет:${N}"
  for i in "${!ids[@]}"; do
    printf '  %-10s %-28s → %s%s\n' "${remarks[$i]}" "${olds[$i]}" "${news[$i]}" "$(same_net "${news[$i]}" && echo '  (из подсети сервера)')"
  done
  for i in "${!ids[@]}"; do
    if [[ ${news[$i]} =~ $SNI_BRAND_RE ]] && ! same_net "${news[$i]}"; then
      warn "Для ${remarks[$i]} в подсети не хватило сайтов – взят известный сайт из общего списка, он подходит хуже соседа. Лучше другой сайт: kit → Протоколы, порты и маскировка → Сменить сайт маскировки"
      break
    fi
  done
  [[ $dry == no ]] || { echo "${D}(--dry-run: ничего не менял)${N}"; return 0; }
  if [[ -t 0 ]]; then
    ask_tty "Применить? [Y/n] "
    [[ ! $REPLY =~ ^[nNнН]$ ]] || { echo "Отменено."; return 0; }
  fi

  # Заодно убираем прежние имена, у которых закончился льготный срок.
  (grace_cleanup) || true
  local bak
  bak=/root/x-ui-before-sni-$(date +%Y%m%d-%H%M%S).db
  install -m 600 /dev/null "$bak"
  python3 - /etc/x-ui/x-ui.db "$bak" <<'PY' || die "Не удалось сохранить копию базы панели. Ничего не менял."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
  # Храним три последние копии: в них ключи сервера.
  ls -1t /root/x-ui-before-sni-*.db 2>/dev/null | tail -n +4 | while read -r old; do rm -f -- "$old"; done
  say "Копия базы панели: $bak"

  # Льготный срок: прежнее имя REALITY и XHTTP сервер ещё SNI_GRACE_DAYS дней принимает рядом с новым.
  local now gb ga rids="" gadd="" j
  now=$(date +%s)
  gb=$(grace_rows)
  for i in "${!ids[@]}"; do
    [[ ${kinds[$i]} == reality ]] || continue
    rids+="${ids[$i]} "
    [[ ${olds[$i]} =~ $SNI_RE ]] && gadd+="${olds[$i]}"$'\t'"${ids[$i]}"$'\t'"$((now + SNI_GRACE_DAYS * 86400))"$'\n'
  done
  ga=$(printf '%s\n%s' "$gb" "$gadd" | grace_merge "$now" "$rids" "${news[*]}")

  local -a done_i=()
  sni_revert() {
    local j
    warn "Возвращаю прежние сайты."
    for j in "${done_i[@]}"; do
      (api POST "inbounds/update/${ids[$j]}" "$(sni_body "${ids[$j]}" "${kinds[$j]}" "${olds[$j]}" "$(grace_json "${ids[$j]}" <<<"$gb")")" >/dev/null) 2>/dev/null || warn "Не удалось вернуть ${remarks[$j]}: восстановите из $bak"
    done
  }
  local body
  for i in "${!ids[@]}"; do
    body=$(sni_body "${ids[$i]}" "${kinds[$i]}" "${news[$i]}" "$(grace_json "${ids[$i]}" <<<"$ga")")
    [[ -n $body ]] || { sni_revert; die "Не нашёл подключение ${remarks[$i]} в панели."; }
    if ! (api POST "inbounds/update/${ids[$i]}" "$body" >/dev/null); then sni_revert; die "Панель не приняла новый сайт для ${remarks[$i]}. Ничего не изменилось."; fi
    done_i+=("$i")
  done
  # MTProto: секреты клиентов – под новый сайт, иначе Telegram придёт со старым именем и попадёт на заглушку.
  local mt_changed=no MT_QUIET=yes
  for i in "${!ids[@]}"; do [[ ${kinds[$i]} == mtproto ]] && mt_changed=yes; done
  if [[ $mt_changed == yes ]] && ! (mt_rekey); then
    sni_revert; (mt_rekey) >/dev/null 2>&1 || true
    die "Панель не приняла новые секреты MTProto. Всё возвращено как было."
  fi

  # Режим «всё на 443»: nginx различает подключения по имени сайта, обновляем его таблицу.
  local conf=/etc/nginx/kit-stream.conf
  if [[ ${SINGLE:-no} == yes && -f $conf ]]; then
    local cbak tmp dup keep_old
    cbak=$(mktemp); cp -p "$conf" "$cbak"; tmp=$(mktemp)
    cp "$conf" "$tmp"
    # Конфиги, собранные до 1.2.1, без этой директивы: длинное имя сайта роняет nginx.
    if ! grep -q '^[[:space:]]*map_hash_bucket_size' "$tmp"; then
      awk '{print} /^stream \{/ && !d {print "    map_hash_bucket_size 512;"; d=1}' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    fi
    for i in "${!ids[@]}"; do
      # Новое имя уже есть в карте (осталось от прошлых правок или льготное)? Убираем его строку: дубль ключа nginx не примет.
      # REALITY и XHTTP: строка прежнего имени остаётся рядом с новой (льготный срок, тот же порт); MTProto – без неё.
      # Прежнее имя у двух подключений сразу: его строку уже обработали, вторую не трогаем.
      dup=no; for ((j = 0; j < i; j++)); do [[ ${olds[$j]} == "${olds[$i]}" ]] && dup=yes; done
      [[ $dup == no ]] || continue
      keep_old=""; [[ ${kinds[$i]:-} == reality ]] && keep_old=1
      awk -v o="${olds[$i]}" -v n="${news[$i]}" -v k="$keep_old" 'NR == FNR {if ($1 == o && $2 ~ /^127\.0\.0\.1:[0-9]+;$/) h = 1; next}
        h && $1 == n && $2 ~ /^127\.0\.0\.1:[0-9]+;$/ {next}
        $1 == o && $2 ~ /^127\.0\.0\.1:[0-9]+;$/ {printf "        %s %s\n", n, $2; if (k) print; next} {print}' "$tmp" "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done
    # Льготные имена, которые больше не нужны (срок, лимит, стали новыми), – из карты.
    local -a gdrop=()
    mapfile -t gdrop < <(grace_gone "$gb" "$ga" "${news[*]}")
    map_drop "$tmp" "${gdrop[@]}"
    cat "$tmp" >"$conf"; rm -f "$tmp"
    local why=""
    if ! why=$(nginx -t 2>&1) || ! why=$(systemctl reload nginx 2>&1); then
      cat "$cbak" >"$conf"; rm -f "$cbak"
      sni_revert; (mt_rekey) >/dev/null 2>&1 || true; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
      # Причина – последние две строки ответа nginx (только печатные знаки): видно, дубль имени это или что-то другое.
      warn "Ответ nginx: $(tail -n 2 <<<"$why" | tr -cd '[:print:]\n' | tr '\n' ' ' | cut -c1-300)"
      die "nginx не принял новые имена. Всё возвращено как было."
    fi
    rm -f "$cbak"
  fi

  (grace_save <<<"$ga") || warn "Не удалось записать $SNI_GRACE: прежние имена уберите сами: kit → Протоколы, порты и маскировка → Убрать прежние имена сайта"

  sleep 2
  systemctl is-active -q x-ui || warn "Панель не отвечает – проверьте: systemctl status x-ui"
  say "Готово. Сайт маскировки сменён."
  local -a tp=()
  if [[ -n $rids ]]; then
    tp+=("Обновите подписку в приложениях (Happ, Karing, v2rayN, Hiddify, Nekobox): в них пока старое имя сайта. Старое имя работает $SNI_GRACE_DAYS дней, потом уберётся само. Убрать сразу: kit → Протоколы, порты и маскировка → Убрать прежние имена сайта.")
  else
    tp+=("Подписка у клиентов обновится сама при следующем обновлении в приложении.")
  fi
  tp+=("Ссылки REALITY, XHTTP и MTProto, сохранённые вручную, замените на новые: kit → Пользователи → Показать ссылки.")
  if [[ ${mt_changed:-no} == yes && ${SINGLE:-no} == yes ]]; then
    tp+=("Telegram: в ссылке MTProto зашит сайт, поэтому прежние ссылки tg:// перестали работать у всех. Разошлите новые: kit → Пользователи → Показать ссылки → Telegram.")
  fi
  [[ $nearby == no ]] || tp+=("Это чужие сайты из вашей подсети: откройте их в браузере и убедитесь, что на них нет ничего неприятного. Не подошли – подберите другой: kit → Протоколы, порты и маскировка → Сменить сайт маскировки.")
  tips "Что дальше" "${tp[@]}"
}

# ---------- MTProto (прокси для Telegram) ----------

# Секрет FakeTLS: «ee» + 16 байт ключа + имя сайта в hex. Telegram шлёт это имя в SNI, nginx по нему выбирает
# маршрут, а mtg сверяет его с секретом (проверено: чужое имя при верном ключе mtg не принимает). Поэтому имя
# в секрете каждого клиента должно совпадать с сайтом подключения, иначе ссылка уходит на заглушку.
mt_row() { jq -c '[.[] | select(.protocol == "mtproto")][0] // empty' <<<"$1"; } # список подключений → MTProto
mt_hex() { printf %s "$1" | od -An -v -tx1 | tr -d ' \n'; }
mt_stale() { # строка MTProto → «email<TAB>секрет» клиентов, у которых в секрете другой сайт
  local dom want email sec
  dom=$(jq -r '(.settings | if type == "string" then fromjson else . end).fakeTlsDomain // empty' <<<"$1")
  [[ $dom =~ $SNI_RE ]] || return 0
  want=$(mt_hex "$dom")
  while IFS=$'\t' read -r email sec; do
    [[ $email =~ ^[A-Za-z0-9_.@-]{1,64}$ && $email =~ [^.] && $sec =~ ^ee[0-9a-f]{32}([0-9a-f]{2})+$ && ${sec:34} != "$want" ]] && printf '%s\t%s\n' "$email" "$sec"
  done < <(jq -r '(.settings | if type == "string" then fromjson else . end).clients[]? | [.email // "", .secret // ""] | @tsv' <<<"$1")
  return 0
}
mt_host_ok() { # группы hosts подключения (JSON) → 0, если ссылка ведёт на адрес сервера и порт 443
  jq -e --arg a "${LINK_HOST:-$HOST}:443" 'type == "array" and any(.[]; any(.hosts[]?; . == $a))' <<<"$1" >/dev/null 2>&1
}

# Секреты клиентов – под нынешний сайт подключения (ключ прежний). Только «всё на 443»: с отдельным портом
# nginx имя не выбирает, и прежние ссылки продолжают работать.
mt_rekey() {
  local row email sec rec n=0 dom
  [[ ${SINGLE:-no} == yes ]] || return 0
  row=$(mt_row "$(api GET inbounds/list)"); [[ -n $row && $(jq -r '.listen' <<<"$row") == 127.0.0.1 ]] || return 0
  dom=$(jq -r '(.settings | if type == "string" then fromjson else . end).fakeTlsDomain' <<<"$row")
  while IFS=$'\t' read -r email sec; do
    [[ -n $email ]] || continue
    rec=$(client "$email"); [[ -n $rec ]] || continue
    api POST "clients/update/$email" "$(jq -c --arg s "${sec:0:34}$(mt_hex "$dom")" '{email, subId, totalGB, expiryTime, limitIp, enable, comment, secret: $s}' <<<"$rec")" >/dev/null
    n=$((n + 1))
  done < <(mt_stale "$row")
  ((n == 0)) || say "MTProto: у $n польз. секрет выпущен под сайт $dom (ключ прежний)"
  ((n == 0)) || [[ ${MT_QUIET:-no} == yes ]] || echo "      Прежние ссылки tg:// больше не подойдут – новые: kit → Пользователи → Показать ссылки → Telegram"
}

# Ссылка MTProto в панели (всё на 443). Панель 3.9 externalProxy у mtproto не хранит, адрес и порт ссылки берёт
# из таблицы hosts: без строки там ссылка ведёт на localhost:10445. Добавляем адрес сервера с портом 443 через API.
# restore – из копии: группы hosts MTProto с чужим адресом или портом удаляем, адрес из архива не берём.
mt_sync() { # [restore]
  local mode=${1:-} row id addr groups g
  [[ ${SINGLE:-no} == yes ]] || return 0
  row=$(mt_row "$(api GET inbounds/list)"); [[ -n $row && $(jq -r '.listen' <<<"$row") == 127.0.0.1 ]] || return 0
  id=$(jq -r '.id' <<<"$row"); addr=${LINK_HOST:-$HOST}
  [[ $id =~ ^[0-9]+$ && $addr =~ ^[A-Za-z0-9.-]{1,253}$ ]] || return 1
  groups=$(api GET "hosts/byInbound/$id")
  if [[ $mode == restore ]]; then
    for g in $(jq -r --arg a "$addr:443" --arg h "${HOST:-}:443" '.[]? | select(.port != 443 or any(.hosts[]?; . != $a and . != $h)) | .groupId' <<<"$groups"); do
      [[ $g =~ ^[A-Za-z0-9_-]{1,64}$ ]] && api POST "hosts/del/$g" >/dev/null
    done
    groups=$(api GET "hosts/byInbound/$id")
  fi
  if ! mt_host_ok "$groups"; then
    api POST hosts/add "$(jq -nc --argjson i "$id" --arg h "$addr:443" '{inboundIds: [$i], hosts: [$h], remark: "kit", security: "same", port: 443}')" >/dev/null
    say "MTProto: ссылка в панели ведёт на $addr:443"
  fi
  mt_rekey
}

# Нужна ли правка MTProto (для needs_migration): одно-два обращения к API панели; ошибка – «не нужна».
mt_needs() {
  [[ ${SINGLE:-no} == yes ]] || return 1
  (
    row=$(mt_row "$(api GET inbounds/list)"); [[ -n $row && $(jq -r '.listen' <<<"$row") == 127.0.0.1 ]] || exit 1
    [[ -z $(mt_stale "$row") ]] || exit 0
    groups=$(api GET "hosts/byInbound/$(jq -r '.id' <<<"$row")")
    ! mt_host_ok "$groups"
  ) 2>/dev/null
}

telegram_reachable() {
  local ip
  for ip in 149.154.167.51 149.154.175.50 91.108.56.130; do
    timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null && return 0
  done
  return 1
}

# Рукопожатие FakeTLS, как у Telegram: ClientHello с подписью ключом секрета и сайтом из секрета в SNI.
# mtg подписывает ServerHello тем же ключом, сайт-заглушка – нет. Секрет – только через stdin (аргументы видно в ps).
# Код: 0 – ответил mtg, 2 – ответил кто-то другой, 3 – нет ответа, 4 – секрет не FakeTLS.
mt_shake() { # адрес порт <<< секрет
  local script
  IFS= read -r -d '' script <<'PY' || true
import hashlib, hmac, os, socket, struct, sys, time
host, port = sys.argv[1], int(sys.argv[2])
try:
    raw = bytes.fromhex(sys.stdin.readline().strip())
    assert raw[0] == 0xEE and len(raw) > 17
    key, domain = raw[1:17], raw[17:].decode("ascii")
except Exception:
    sys.exit(4)
def ext(t, d): return struct.pack(">HH", t, len(d)) + d
d = domain.encode()
exts = (ext(0, struct.pack(">HBH", len(d) + 3, 0, len(d)) + d) + ext(23, b"") + ext(65281, b"\x00")
        + ext(10, bytes.fromhex("0006001d00170018")) + ext(11, b"\x01\x00") + ext(35, b"")
        + ext(16, b"\x00\x0c\x02h2\x08http/1.1") + ext(13, bytes.fromhex("0012040308040401050308050501080606010201"))
        + ext(51, struct.pack(">HHH", 36, 0x1d, 32) + os.urandom(32)) + ext(45, b"\x01\x01") + ext(43, b"\x04\x03\x04\x03\x03"))
ciphers = bytes.fromhex("130113021303c02bc02fc02cc030cca9cca8c013c014009c009d002f0035")
body = b"\x03\x03" + b"\x00" * 32 + b"\x20" + os.urandom(32) + struct.pack(">H", len(ciphers)) + ciphers + b"\x01\x00"
pad = 517 - (5 + 4 + len(body) + 2 + len(exts)) - 4
if pad >= 0:
    exts += ext(21, b"\x00" * pad)
body += struct.pack(">H", len(exts)) + exts
hs = b"\x01" + struct.pack(">I", len(body))[1:] + body
hello = bytearray(b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs)
dig = bytearray(hmac.new(key, bytes(hello), hashlib.sha256).digest())
for i, b in enumerate(struct.pack("<I", int(time.time()))):
    dig[28 + i] ^= b
hello[11:43] = dig
def recv(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b
recs = []
try:
    s = socket.create_connection((host, port), timeout=8)
    s.sendall(bytes(hello))
    for _ in range(3):
        h = recv(s, 5)
        recs.append((h[0], recv(s, struct.unpack(">H", h[3:5])[0])))
        if recs[0][0] != 0x16:
            break
    s.close()
except (OSError, EOFError):
    sys.exit(2 if recs else 3)
if len(recs) < 3 or recs[0][0] != 0x16 or len(recs[0][1]) < 38:
    sys.exit(2)
resp = bytearray(b"".join(bytes([t]) + b"\x03\x03" + struct.pack(">H", len(p)) + p for t, p in recs))
got = bytes(resp[11:43]); resp[11:43] = b"\x00" * 32
sys.exit(0 if hmac.compare_digest(got, hmac.new(key, bytes(dig) + bytes(resp), hashlib.sha256).digest()) else 2)
PY
  python3 -c "$script" "$1" "$2"
}

# MTProto: процесс mtg, ссылка в панели и сайт в секретах (всё на 443), доступ к Telegram; --deep – рукопожатие.
check_mtproto() {
  local list row pid groups stale port dom sec rc
  systemctl is-active -q x-ui || return 0 # про службу сказано выше
  list=$(api GET inbounds/list 2>/dev/null) || return 0
  row=$(mt_row "$list"); [[ -n $row ]] || return 0
  [[ $(jq -r '.enable' <<<"$row") == true ]] || { c_info "MTProto выключен: kit → Протоколы, порты и маскировка → Выключить или включить протокол"; return 0; }
  pid=$(systemctl show -p MainPID --value x-ui 2>/dev/null || true)
  if [[ $pid =~ ^[1-9][0-9]*$ ]] && pgrep -P "$pid" '^mtg-linux-' >/dev/null 2>&1; then c_ok "MTProto: процесс mtg запущен"
  else c_bad svc:x-ui "MTProto: процесс mtg не запущен (панель обычно поднимает его сама за полминуты; журнал: tail -n 30 /var/log/x-ui/3xui.log)"; fi
  port=$(jq -r '.port' <<<"$row")
  if [[ ${SINGLE:-no} == yes && $(jq -r '.listen' <<<"$row") == 127.0.0.1 ]]; then
    port=443
    if groups=$( (api GET "hosts/byInbound/$(jq -r '.id' <<<"$row")") 2>/dev/null); then
      if mt_host_ok "$groups"; then c_ok "MTProto: ссылка в панели ведёт на порт 443"
      else c_bad mtproto "MTProto: ссылка в панели ведёт не на ${LINK_HOST:-$HOST}:443, а на внутренний порт ${MTPROTO_INNER:-10445} или чужой адрес (kit → Проверка сервера → Исправить безопасное добавит верный)"; fi
    fi
    stale=$(mt_stale "$row" | grep -c . || true)
    if ((stale > 0)); then c_bad mtproto "MTProto: у $stale польз. в секрете прежний сайт маскировки – nginx его не знает, ссылки tg:// не работают (kit → Проверка сервера → Исправить безопасное выпустит секреты под нынешний сайт)"; fi
  fi
  # The entry's local mtg uses a SOCKS5 bridge into Xray instead of direct egress.
  # A direct Telegram TCP probe would be misleading here (and may be blocked).
  if [[ -f /etc/kit-cascade/entry/state.json ]]; then
    c_info "MTProto Cascade: прямой доступ ENTRY к Telegram не требуется; проверьте: python3 cascade_v2/install.py entry-mtproto-probe (из checkout)"
  else
    telegram_reachable || c_warn "MTProto: с сервера не видно серверов Telegram – прокси для Telegram работать не будет (уточните у хостера)"
  fi
  [[ $CHECK_DEEP == yes && $port =~ ^[0-9]+$ ]] || return 0
  command -v python3 >/dev/null || return 0
  # По одному включённому клиенту на каждый сайт в секретах.
  while IFS=$'\t' read -r dom sec; do
    [[ $dom =~ ^[0-9a-f]+$ ]] || continue
    dom=$(printf '%s' "$dom" | sed 's/../\\x&/g'); dom=$(printf '%b' "$dom")
    [[ $dom =~ $SNI_RE ]] || continue
    rc=0; mt_shake 127.0.0.1 "$port" <<<"$sec" || rc=$?
    case $rc in
      0) c_ok "MTProto (сайт $dom): mtg ответил на рукопожатие FakeTLS, как Telegram-клиенту" ;;
      2) c_bad "" "MTProto (сайт $dom): на рукопожатие ответил не mtg, а сайт-заглушка – ссылки с этим сайтом не работают" ;;
      3) c_bad "" "MTProto (сайт $dom): порт $port не ответил на рукопожатие" ;;
      *) c_warn "MTProto (сайт $dom): рукопожатие проверить не удалось" ;;
    esac
  done < <(jq -r '[(.settings | if type == "string" then fromjson else . end).clients[]? | select(.enable != false) | (.secret // "")
    | select(test("^ee[0-9a-f]{34,}$")) | {d: .[34:], s: .}] | unique_by(.d) | .[] | [.d, .s] | @tsv' <<<"$row")
}

# ---------- порты подключений: kit port ----------

port_net() { # protocol → tcp|udp|both
  case $1 in
    hysteria | hysteria2 | tuic | wireguard | amneziawg) echo udp ;;
    shadowsocks) echo both ;;
    *) echo tcp ;;
  esac
}

port_show() {
  local list
  list=$(api GET inbounds/list)
  say "Порты подключений"
  jq -r '.[] | [.remark, .port, .protocol, .listen] | @tsv' <<<"$list" | while IFS=$'\t' read -r name port proto listen; do
    if [[ $listen == 127.0.0.1 ]]; then printf '  %-14s %-6s %s\n' "$name" "$port" "внутренний (за nginx на 443)"
    else printf '  %-14s %-6s %s\n' "$name" "$port" "$(port_net "$proto")"; fi
  done
  echo
  echo "Сменить порт: ${B}kit → Протоколы, порты и маскировка → Сменить порт протокола${N}"
}

port_set() { # имя порт
  local name=${1:-} new=${2:-} list row id old proto listen net body
  [[ -n $name && $new =~ ^[0-9]{1,5}$ ]] || die "kit port set имя порт, например: kit port set REALITY 8443"
  new=$((10#$new)); ((new >= 1 && new <= 65535)) || die "Порт: число от 1 до 65535."
  list=$(api GET inbounds/list)
  row=$(jq -c --arg n "${name,,}" '[.[] | select((.remark | ascii_downcase) == $n)][0] // empty' <<<"$list")
  [[ -n $row ]] || die "Нет подключения «$name». Список: kit → Протоколы, порты и маскировка → Показать протоколы и порты"
  id=$(jq -r '.id' <<<"$row"); old=$(jq -r '.port' <<<"$row"); proto=$(jq -r '.protocol' <<<"$row"); listen=$(jq -r '.listen' <<<"$row")
  [[ $listen != 127.0.0.1 ]] || die "$name работает за nginx на внутреннем порту, снаружи это 443: менять нечего (режим «всё на 443»)."
  [[ $new != "$old" ]] || die "$name уже на порту $new."
  case $new in 22 | 80) die "Порт $new занят под SSH или проверку сертификата – выберите другой." ;; esac
  [[ $new != "${XUI_PANEL_PORT:-}" ]] || die "Порт $new – это панель."
  net=$(port_net "$proto")
  # TCP и UDP на одном номере не конфликтуют (REALITY по tcp и Hysteria2 по udp делят 443).
  local on op opr oid
  while IFS=$'\t' read -r oid op opr; do
    [[ $oid != "$id" && $op == "$new" ]] || continue
    on=$(port_net "$opr")
    [[ $on == both || $net == both || $on == "$net" ]] && die "Порт $new/$on уже занят другим подключением."
  done < <(jq -r '.[] | [.id, .port, .protocol] | @tsv' <<<"$list")
  case $net in
    tcp) ss -Hltn "sport = :$new" | grep -q . && die "Порт $new/tcp занят другой программой." ;;
    udp) ss -Hlun "sport = :$new" | grep -q . && die "Порт $new/udp занят другой программой." ;;
    both) { ss -Hltn "sport = :$new"; ss -Hlun "sport = :$new"; } | grep -q . && die "Порт $new занят другой программой." ;;
  esac
  body=$(jq -c --argjson p "$new" '{id, remark, enable, listen, port: $p, protocol, expiryTime, total, settings: (.settings | if type == "string" then . else tojson end),
    streamSettings: (.streamSettings | if type == "string" then . else tojson end), sniffing: (.sniffing | if type == "string" then . else tojson end)}' <<<"$row")
  local ufw_on=no
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ufw_on=yes
  [[ $ufw_on == no ]] || port_ufw allow "$new" "$net"
  local before; before=$(inbounds_down "$list")
  if ! (api POST "inbounds/update/$id" "$body" >/dev/null); then
    [[ $ufw_on == no ]] || port_ufw delete "$new" "$net"
    die "Панель не приняла новый порт. Ничего не изменилось."
  fi
  [[ $ufw_on == no ]] || port_ufw delete "$old" "$net"
  xray_heal "$before"
  if inbound_listens "$new" "$net"; then say "$name теперь на порту ${B}$new${N} (был $old)."
  else warn "$name переведён на порт $new, но он пока не слушает: проверьте kit → Проверка сервера → Глубокая."; fi
  echo "Подписка обновит ссылки сама. Сохранённые вручную ссылки на $name нужно заменить: ${B}kit → Пользователи → Показать ссылки${N}"
  echo "Если у хостера есть свой межсетевой экран (в личном кабинете), откройте в нём порт $new ($net) и закройте $old."
}

port_ufw() { # allow|delete порт tcp|udp|both
  local act=$1 p=$2 n=$3
  if [[ $n == both ]]; then
    if [[ $act == allow ]]; then ufw allow "$p/tcp" >/dev/null; ufw allow "$p/udp" >/dev/null
    else ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; ufw delete allow "$p/udp" >/dev/null 2>&1 || true; fi
  elif [[ $act == allow ]]; then ufw allow "$p/$n" >/dev/null
  else ufw delete allow "$p/$n" >/dev/null 2>&1 || true; fi
}

# ---------- второй REALITY на высоком порту: kit reality add ----------

reality_add() { # [порт]
  local want=${1:-} list base id port="" keys sid settings stream body c n=0 tries bid
  [[ -z $want || $want =~ ^[0-9]{1,5}$ ]] || die "kit reality add [порт], например: kit reality add 24443"
  list=$(api GET inbounds/list)
  jq -e 'any(.[]; .remark == "REALITY-2")' <<<"$list" >/dev/null && die "REALITY-2 уже есть. Порт: kit → Протоколы, порты и маскировка → Показать протоколы и порты, смена: → Сменить порт протокола"
  base=$(jq -c '[.[] | select(.remark == "REALITY")][0] // empty' <<<"$list")
  [[ -n $base ]] || die "На сервере нет подключения REALITY, на которое можно опереться."
  if [[ -n $want ]]; then
    port=$((10#$want)); ((port >= 1024 && port <= 65535)) || die "Порт: число от 1024 до 65535."
  else
    for tries in $(seq 1 50); do
      port=$(shuf -i 20000-60000 -n 1)
      jq -e --argjson p "$port" 'any(.[]; .port == $p)' <<<"$list" >/dev/null && { port=""; continue; }
      ss -Hlntu "sport = :$port" | grep -q . || break
      port=""
    done
    [[ -n $port ]] || die "Не нашёл свободный порт."
  fi
  jq -e --argjson p "$port" 'any(.[]; .port == $p)' <<<"$list" >/dev/null && die "Порт $port уже занят другим подключением."
  ss -Hlntu "sport = :$port" | grep -q . && die "Порт $port занят другой программой."
  [[ $port != "${XUI_PANEL_PORT:-}" ]] || die "Порт $port – это панель."

  keys=$(api GET server/getNewX25519Cert)
  sid=$(openssl rand -hex 8)
  settings=$(jq -nc '{clients: [], decryption: "none", fallbacks: []}')
  # Сайт маскировки (или свой домен) – как у основного REALITY, ключи и shortId – свои.
  stream=$(jq -c --argjson k "$keys" --arg sid "$sid" '(.streamSettings | if type == "string" then fromjson else . end)
    | .externalProxy = [] | .tcpSettings.acceptProxyProtocol = false
    | .realitySettings.privateKey = $k.privateKey | .realitySettings.shortIds = [$sid]
    | .realitySettings.settings.publicKey = $k.publicKey | del(.sockopt)' <<<"$base")
  body=$(jq -nc --argjson port "$port" --arg s "$settings" --arg st "$stream" '{remark: "REALITY-2", enable: true, listen: "", port: $port, protocol: "vless",
    settings: $s, streamSettings: $st, sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}", expiryTime: 0, total: 0}')
  api POST inbounds/add "$body" >/dev/null
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$port/tcp" >/dev/null; fi
  id=$(api GET inbounds/list | jq -r '[.[] | select(.remark == "REALITY-2")][0].id')
  [[ $id =~ ^[0-9]+$ ]] || die "Панель не создала REALITY-2."
  # Тем же пользователям, что есть на основном REALITY (двойники AmneziaWG и Telegram не подключаются к нему).
  bid=$(jq -r '.id' <<<"$base")
  while read -r c; do
    [[ -n $c ]] || continue
    api POST "clients/$c/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null && n=$((n + 1))
  done < <(clients | jq -r --argjson b "$bid" '.[] | select((.inboundIds // []) | index($b)) | .email')
  say "REALITY-2 создан на порту ${B}$port${N}, подключено пользователей: $n. Подписка у клиентов обновится сама."
  echo "Если у хостера есть свой межсетевой экран (в личном кабинете), откройте в нём порт $port (tcp)."
  echo "Проверить: ${B}kit → Проверка сервера → Глубокая${N}. Ссылки: ${B}kit → Пользователи → Показать ссылки${N}"
}

# ---------- вид: блок ссылок, kit net, меню ----------

# Блок ссылок: основные и запасные по группам, у каждой название, порт и сама ссылка. Печатает и итог установки, и kit user link.
links_block() { # имя subId
  local name=$1 sid=$2 raw
  raw=$(collect_links "$sid" '^[a-z0-9]+://')
  [[ -n $raw ]] || { echo "Отдельных ссылок нет."; return 0; }
  local script
  IFS= read -r -d '' script <<'PY' || true
import base64, json, os, re, subprocess, shutil, sys
from urllib.parse import urlparse, parse_qs, unquote
name = sys.argv[1]
MAIN = ["REALITY", "XHTTP", "Hysteria2"]
items, vpn = [], 0
for line in sys.stdin.read().split():
    sch = line.split("://", 1)[0]
    label, port, net, hint = "", "", "tcp", ""
    try:
        if sch == "vmess":
            d = json.loads(base64.b64decode(line[8:] + "=" * (-len(line[8:]) % 4)))
            label, port = d.get("ps", "VMess"), str(d.get("port", ""))
        elif sch == "vpn":
            vpn += 1
            label, net, hint = ("AmneziaWG" if vpn == 1 else "AmneziaWG 3.1"), "udp", "вставьте в AmneziaVPN"
        elif sch == "tg":
            label, port, hint = "MTProto", parse_qs(urlparse(line).query).get("port", [""])[0], "для Telegram"
        else:
            u = urlparse(line)
            label, port = unquote(u.fragment), str(u.port or "")
            if sch in ("hysteria2", "tuic"):
                net = "udp"
            if sch == "tuic":
                hint = "если приложение ругается на сертификат, включите «Разрешить небезопасный»"
    except Exception:
        continue
    label = re.sub(r"-" + re.escape(name) + r"$", "", label) or sch
    items.append((label, port, net, hint, line))
def show(label, port, net, hint, line):
    where = (port + "/" + net) if port and sch_net_ok(label, net) else (port or net)
    print("  %s  ·  %s%s" % (label, where, ("   → " + hint) if hint else ""))
    print("  " + line)
    print()
def sch_net_ok(label, net):
    return label not in ("Shadowsocks",)
print("ПОДКЛЮЧЕНИЕ  ·  %s" % name)
print()
ORDER = ["REALITY", "XHTTP", "Hysteria2", "REALITY-2", "VLESS-WS", "Trojan-gRPC", "VMess-WS", "Shadowsocks", "TUIC", "AmneziaWG", "AmneziaWG 3.1", "MTProto"]
items.sort(key=lambda i: ORDER.index(i[0]) if i[0] in ORDER else len(ORDER))
qr_done = False
for it in items:
    show(*it)
    if not qr_done and it[0] == "REALITY" and shutil.which("qrencode") and not os.environ.get("KIT_NO_QR"):
        sys.stdout.flush()
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "1", it[4]])
        print()
        qr_done = True
PY
  python3 -c "$script" "$name" <<<"$raw"
}

# ---------- Hysteria2: ответ сайтом на чужой HTTP/3-запрос (masquerade) ----------

hy_masq_state() { api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.protocol == "hysteria")][0] | (.streamSettings | if type == "string" then fromjson else . end).hysteriaSettings.masquerade.type // empty' 2>/dev/null || true; }

hy_masq() { # on|off
  local act=${1:-} id page
  [[ $act == on || $act == off ]] || die "kit net masq on|off"
  id=$(api GET inbounds/list | jq -r '[.[] | select(.protocol == "hysteria")][0].id // empty')
  [[ -n $id ]] || die "На сервере нет Hysteria2."
  if [[ $act == on ]]; then
    # Байт в байт как у nginx (с последним переводом строки).
    page=$(cat /var/www/kit/index.html 2>/dev/null && printf x || true); page=${page%x}
    # Страницы нет только у старых установок с отдельными портами – тогда простая страница без названия.
    [[ -n $page ]] || page='<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head><body style="font-family:sans-serif;text-align:center;margin-top:20vh"><h1>Welcome</h1><p>This site is being updated. Please check back soon.</p></body></html>'
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end) | .hysteriaSettings.masquerade = {type: "string", content: $c, statusCode: 200, headers: {"content-type": "text/html; charset=utf-8"}})' --arg c "$page" \
      || die "Панель не приняла изменение. Ничего не изменилось."
    say "Hysteria2 теперь отвечает на посторонний HTTP/3-запрос страницей сайта."
  else
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end) | del(.hysteriaSettings.masquerade))' || die "Панель не приняла изменение."
    say "Маскировка Hysteria2 выключена."
  fi
}

# ---------- DNS в подписках ----------
# Clash/Mihomo: безопасный dns добавляет kit-sub. Xray JSON: dns берётся из настройки панели subJsonDns (по умолчанию – обычный
# UDP на 8.8.8.8), ставим DoH. Запросы идут по правилам клиента, то есть через прокси.
DNS_XRAY='{"servers":[{"address":"https://1.1.1.1/dns-query","skipFallback":false},{"address":"https://8.8.8.8/dns-query","skipFallback":true}],"queryStrategy":"UseIP","tag":"dns_out"}'

net_dns() { # [on|off]
  local act=${1:-} all cur
  all=$(api POST setting/all '{}')
  cur=$(jq -r '.subJsonDns // ""' <<<"$all")
  case $act in
    "")
      if [[ -n $cur ]]; then echo "DNS в подписках: DoH через прокси (Clash – от kit-sub, Xray JSON – настройка панели)$(mh ". Выключить: kit → Протоколы, порты и маскировка → DNS в подписках (против утечек)")"
      else echo "DNS в подписке Xray JSON: обычный UDP 8.8.8.8 (по умолчанию панели)$(mh ". Включить DoH: kit → Протоколы, порты и маскировка → DNS в подписках (против утечек)")"; fi ;;
    on)
      [[ -z $cur ]] || { say "DNS уже настроен (DoH)."; return 0; }
      api POST setting/update "$(jq -c --arg d "$DNS_XRAY" '.subJsonDns = $d' <<<"$all")" >/dev/null || die "Панель не приняла настройку."
      systemctl restart x-ui; panel_healthy || warn "Панель не ответила после перезапуска: проверьте kit → Проверка сервера → Быстрая проверка."
      say "DNS в подписках: DoH через прокси. Клиенты подхватят при обновлении подписки." ;;
    off)
      api POST setting/update "$(jq -c '.subJsonDns = ""' <<<"$all")" >/dev/null || die "Панель не приняла настройку."
      systemctl restart x-ui; panel_healthy || true
      say "Вернул DNS панели по умолчанию." ;;
    *) die "kit net dns [on|off]" ;;
  esac
}

# ---------- раздельная маршрутизация в подписке ----------
# Необязательно: /etc/kit-sub/rules.yaml. Через VPN идёт только перечисленное, остальное (в том числе местные приложения)
# напрямую. Работает для приложений на Mihomo (Clash Verge, FlClash, Mihomo Party): правила приезжают с подпиской, на телефонах
# ничего настраивать не нужно. DNS при этом не течёт: имена из списка у клиента не разрешаются, а запросы про них идут по DoH
# через VPN (подробности – в kit-sub.py). Нет файла – подписка как обычно, весь трафик через VPN.
SPLIT_FILE=/etc/kit-sub/rules.yaml

split_template() {
  cat <<'YAML'
# Раздельная маршрутизация подписки (приложения на Mihomo: Clash Verge, FlClash, Mihomo Party).
# Через VPN идёт ТОЛЬКО перечисленное ниже (сервисы, которым VPN нужен), всё остальное – напрямую.
# Правка вступает в силу, когда приложение обновит подписку; перезапуск не нужен.
# Проверить файл: kit net split check. Выключить: kit net split off.
#
# Правила (по одному в строке): ТИП,ЗНАЧЕНИЕ
#   GEOSITE,youtube              – готовая категория сервиса (список: github.com/MetaCubeX/meta-rules-dat, geo/geosite)
#   DOMAIN-SUFFIX,example.org    – домен и все его поддомены
#   DOMAIN,api.example.org       – ровно этот домен
#   DOMAIN-KEYWORD,example       – домен, в котором есть слово
#   IP-CIDR,203.0.113.0/24       – подсеть
# GEOSITE и GEOIP: приложение один раз скачивает базу категорий с GitHub.

via_vpn:
  # Нейросети
  - GEOSITE,category-ai-!cn      # ChatGPT, Claude, Gemini, Perplexity и другие
  - GEOSITE,openai
  - GEOSITE,anthropic
  - GEOSITE,perplexity
  - GEOSITE,huggingface
  # Видео и музыка
  - GEOSITE,youtube
  - GEOSITE,netflix
  - GEOSITE,spotify
  - GEOSITE,twitch
  - GEOSITE,disney
  - GEOSITE,hbo
  - GEOSITE,primevideo
  - GEOSITE,soundcloud
  - GEOSITE,vimeo
  - GEOSITE,tiktok
  # Соцсети и мессенджеры
  - GEOSITE,telegram
  - GEOIP,telegram               # Telegram подключается по IP-адресам, без имён
  - GEOSITE,meta                 # Instagram, Facebook, WhatsApp
  - GEOSITE,twitter              # X (Twitter)
  - GEOSITE,discord
  - GEOSITE,reddit
  - GEOSITE,linkedin
  - GEOSITE,pinterest
  - GEOSITE,tumblr
  - GEOSITE,quora
  - GEOSITE,medium
  - GEOSITE,signal
  - GEOSITE,viber
  # Работа и разработка
  - GEOSITE,google               # все сервисы Google
  - GEOSITE,github
  - GEOSITE,gitlab
  - GEOSITE,docker
  - GEOSITE,npmjs
  - GEOSITE,jetbrains
  - GEOSITE,atlassian
  - GEOSITE,slack
  - GEOSITE,notion
  - GEOSITE,figma
  - GEOSITE,canva
  - GEOSITE,adobe
  - GEOSITE,zoom
  - GEOSITE,trello
  - GEOSITE,dropbox
  - GEOSITE,protonmail
  - GEOSITE,mega
  - GEOSITE,imgur
  - GEOSITE,duckduckgo
  - GEOSITE,wikimedia
  # Иностранные СМИ
  - GEOSITE,bbc
  - GEOSITE,cnn
  - GEOSITE,nytimes
  - GEOSITE,reuters
  - GEOSITE,bloomberg
  # Раскомментируйте, если нужно (уберите «# » в начале строки). Это тяжёлый трафик или сервисы с привязкой к региону:
  # - GEOSITE,microsoft
  # - GEOSITE,apple
  # - GEOSITE,steam
  # - GEOSITE,epicgames
  # - GEOSITE,playstation
  # - GEOSITE,xbox
  # - GEOSITE,nintendo
  # - GEOSITE,cloudflare
  # - GEOSITE,paypal
  # - DOMAIN-SUFFIX,example.org

# Необязательно: DNS для всего остального (по умолчанию – системный DNS приложения). Только адреса https://…
# direct_dns:
#   - https://dns.example.net/dns-query
YAML
}

# Приложениям на Xray правила раздаёт сама панель (3X-UI 3.9+): заголовок Routing для Happ и правила JSON-подписки.
# Собираем их из того же rules.yaml. Чужой профиль, уже стоящий в панели, не трогаем.
split_panel_ours() { # наш профиль: JSON или ссылка happ://routing/onadd/<base64> с Name "3X-UI KIT"
  local v=$1
  [[ $v == happ://routing/onadd/* ]] && v=$(printf '%s' "${v#happ://routing/onadd/}" | base64 -d 2>/dev/null || true)
  grep -q '"Name":"3X-UI KIT"' <<<"$v"
}

split_panel_sync() { # on|off
  local all cur_h cur_j h j out
  all=$(api POST setting/all '{}') || return 1
  cur_h=$(jq -r '.subRoutingRules // ""' <<<"$all"); cur_j=$(jq -r '.subJsonRoutingRules // ""' <<<"$all")
  if [[ $1 == on ]]; then
    if { [[ -n $cur_h ]] && ! split_panel_ours "$cur_h"; } || { [[ -n $cur_j ]] && ! split_panel_ours "$cur_j"; }; then
      warn "В панели уже настроена своя маршрутизация подписки (Happ или JSON) – не меняю. Приложения на Mihomo получат список как обычно."
      return 0
    fi
    h=$(python3 /usr/local/lib/kit-sub/kit_sub.py --routing-payload happ 2>/dev/null) && j=$(python3 /usr/local/lib/kit-sub/kit_sub.py --routing-payload json 2>/dev/null) \
      || { warn "Список не разобран – для Happ и Xray ничего не менял (kit → Протоколы, порты и маскировка → Раздельная маршрутизация)."; return 1; }
    out=$(jq -c --arg h "$h" --arg j "$j" '.subEnableRouting = true | .subRoutingRules = $h | .subJsonRoutingRules = $j' <<<"$all")
  else
    [[ -n $cur_h || -n $cur_j ]] || return 0
    if { [[ -n $cur_h ]] && ! split_panel_ours "$cur_h"; } || { [[ -n $cur_j ]] && ! split_panel_ours "$cur_j"; }; then return 0; fi
    out=$(jq -c '.subEnableRouting = false | .subRoutingRules = "" | .subJsonRoutingRules = ""' <<<"$all")
  fi
  api POST setting/update "$out" >/dev/null || { warn "Панель не приняла маршрутизацию для Happ и Xray."; return 1; }
  systemctl restart x-ui; panel_healthy || warn "Панель не ответила после перезапуска: проверьте kit → Проверка сервера → Быстрая проверка."
}

# kit-sub работает без root и читает файл сам: если права закрыты (после правки редактором, копирования), список молча не применится.
split_perms() {
  [[ -f $SPLIT_FILE ]] || return 0
  if ! [[ $(stat -c %a "$SPLIT_FILE") =~ ^[0-7][0-7][4-7]$ && $(stat -c %a /etc/kit-sub) =~ ^[0-7][0-7][1357]$ ]]; then
    chmod 644 "$SPLIT_FILE"; chmod 755 /etc/kit-sub
    warn "Права на $SPLIT_FILE были закрыты для подписки (kit-sub работает не от root) – исправил."
  fi
}

net_split() { # [on|off|check]
  local act=${1:-} n
  split_perms
  case $act in
    "")
      if [[ -f $SPLIT_FILE ]]; then
        n=$(python3 /usr/local/lib/kit-sub/kit_sub.py --check-rules 2>&1 | grep -a '^Правил через VPN' || true)
        echo "Раздельная маршрутизация включена: $n"
        echo "Файл: $SPLIT_FILE$(mh ". Включить, выключить и проверить: kit → Протоколы, порты и маскировка → Раздельная маршрутизация")"
        echo "Mihomo-приложения берут список из подписки сами; Happ и JSON-подписка Xray – из панели (после правки файла примените список: kit → Протоколы, порты и маскировка → Раздельная маршрутизация)."
      else
        echo "Раздельная маршрутизация выключена: через VPN идёт весь трафик$(mh ". Включить: kit → Протоколы, порты и маскировка → Раздельная маршрутизация")"
      fi ;;
    on)
      [[ -f /usr/local/lib/kit-sub/kit_sub.py ]] || die "Нужна подписка kit-sub (обновите kit: kit → Обновить kit и подписку)."
      if [[ -f $SPLIT_FILE ]]; then say "Уже включено: $SPLIT_FILE"; return 0; fi
      if [[ -f $SPLIT_FILE.off ]]; then install -m 644 "$SPLIT_FILE.off" "$SPLIT_FILE"; else split_template >"$SPLIT_FILE"; fi
      chmod 755 /etc/kit-sub; chmod 644 "$SPLIT_FILE"
      say "Включил: $SPLIT_FILE"
      split_panel_sync on || true
      echo "Сейчас через VPN идут только перечисленные сервисы (популярные иностранные сервисы: YouTube, ChatGPT, Telegram и другие), остальное напрямую."
      echo "Список правится в файле $SPLIT_FILE; проверить его: kit → Протоколы, порты и маскировка → Раздельная маршрутизация."
      echo "Приложения на Mihomo подхватят при обновлении подписки; после правки списка для Happ и Xray: kit → Протоколы, порты и маскировка → Раздельная маршрутизация." ;;
    off)
      [[ -f $SPLIT_FILE ]] || { say "Уже выключено."; return 0; }
      mv "$SPLIT_FILE" "$SPLIT_FILE.off"
      split_panel_sync off || true
      say "Выключил: подписка снова отдаёт весь трафик через VPN (список сохранён: $SPLIT_FILE.off)." ;;
    check)
      [[ -f $SPLIT_FILE ]] || die "Файла нет: $SPLIT_FILE (включить: kit → Протоколы, порты и маскировка → Раздельная маршрутизация)"
      python3 /usr/local/lib/kit-sub/kit_sub.py --check-rules && return 0
      case $? in
        2) die "Исправьте список: с неизвестной категорией приложения на Mihomo не смогут запустить конфиг." ;;
        *) die "Список не применится – подписка останется без раздельной маршрутизации." ;;
      esac ;;
    apply)
      [[ -f $SPLIT_FILE ]] || die "Файла нет: $SPLIT_FILE (включить: kit → Протоколы, порты и маскировка → Раздельная маршрутизация)"
      python3 /usr/local/lib/kit-sub/kit_sub.py --check-rules >/dev/null 2>&1 || die "Список не применится: сначала kit → Протоколы, порты и маскировка → Раздельная маршрутизация."
      split_panel_sync on && say "Списки для Happ и Xray в панели обновлены (приложения на Mihomo подхватывают файл сами)." ;;
    *) die "kit net split [on|off|check|apply]" ;;
  esac
}

# ---------- панель и подписка: по IP или по домену ----------
# Со своим доменом (режим «всё на 443») заход по имени домена попадает к сайту-прикрытию. Панель и подписка по
# умолчанию открываются по IP; `kit net panel domain` добавляет их и в блок домена (сертификат Let's Encrypt домена),
# `kit net panel ip` возвращает как было. Пути у них секретные, как и на IP.

PANEL_CONF=/etc/nginx/conf.d/kit.conf

# Разбор и пересборка блока домена в конфиге nginx. info – домен, сертификат, ключ; render – новый текст конфига.
panel_conf_py() {
  python3 - "$@" <<'PY'
import re, sys
op, conf = sys.argv[1], sys.argv[2]
text = open(conf).read()

def match_brace(t, start):
    depth = 0
    for j in range(start, len(t)):
        if t[j] == "{":
            depth += 1
        elif t[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return -1

def servers(t):
    out, i = [], 0
    while True:
        m = re.search(r"^server\s*\{", t[i:], re.M)
        if not m:
            return out
        a = i + m.start()
        b = match_brace(t, a)
        out.append((a, b))
        i = b

blocks = servers(text)
web = next((b for b in blocks if "server_name _;" in text[b[0]:b[1]]), None)
steal = next((b for b in blocks if "server_name _;" not in text[b[0]:b[1]] and re.search(r"server_name\s+\S+;", text[b[0]:b[1]])), None)
def location(t, path):
    m = re.search(r"^[ \t]*location\s+" + re.escape(path) + r"\s*\{", t, re.M)
    if not m:
        return ""
    b = match_brace(t, m.end() - 1)
    return t[m.start():b]
if op == "addloc":
    # addloc конфиг путь-подписки доп.пути…: в блок сайта по IP добавляются места для доп. путей (копия места подписки)
    if web is None:
        sys.exit(2)
    wt = text[web[0]:web[1]]
    base = location(wt, sys.argv[3])
    if not base:
        sys.exit(3)
    new_wt = wt
    for e in sys.argv[4:]:
        if location(new_wt, e):
            continue
        copy = base.replace(sys.argv[3], e, 1)
        new_wt = new_wt.replace(base, base + "\n" + copy, 1)
    sys.stdout.write(text[:web[0]] + new_wt + text[web[1]:])
    sys.exit(0)
if steal is None:
    sys.exit(2)
sb = text[steal[0]:steal[1]]
domain = re.search(r"server_name\s+(\S+);", sb).group(1)
cert = re.search(r"ssl_certificate\s+(\S+);", sb).group(1)
key = re.search(r"ssl_certificate_key\s+(\S+);", sb).group(1)
port = re.search(r"listen\s+127\.0\.0\.1:(\d+)", sb).group(1)
if op == "info":
    print(domain, cert, key)
    sys.exit(0)
mode, sub_path, panel_path = sys.argv[3], sys.argv[4], sys.argv[5]
extras = sys.argv[6:]
if mode == "domain":
    wb = text[web[0]:web[1]] if web else ""
    locs = "\n".join(x for x in [location(wb, sub_path), location(wb, panel_path)] + [location(wb, e) for e in extras] if x)
    if not locs:
        sys.exit(3)
    new = f"""server {{
    listen 127.0.0.1:{port} ssl http2 proxy_protocol;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    absolute_redirect off;
    access_log off;
    # kit:panel-on-domain
{locs}
    location / {{
        root /var/www/kit;
        index index.html;
    }}
}}"""
else:
    new = f"""server {{
    listen 127.0.0.1:{port} ssl http2;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    location / {{
        root /var/www/kit;
        index index.html;
    }}
}}"""
sys.stdout.write(text[:steal[0]] + new + text[steal[1]:])
PY
}

# Путь панели (install-result.env) и подписки (kit.env) идут в конфиг nginx: только буквы, цифры, _ и -.
panel_web_path() {
  [[ ${XUI_WEB_BASE_PATH:-} =~ ^/?[A-Za-z0-9_-]{1,64}/?$ && ${SUB_PATH:-} =~ ^/[A-Za-z0-9_-]{1,64}/$ ]] || return 1
  local p=/${XUI_WEB_BASE_PATH#/}
  echo "${p%/}/"
}

kit_env_set() { # ключ значение: меняет или добавляет строку в /etc/kit/kit.env
  python3 - "$KIT_ENV" "$1" "$2" <<'PY'
import re, shlex, sys
p, k, v = sys.argv[1:4]
lines = open(p).read().splitlines()
new = f"{k}={shlex.quote(v)}"
for i, l in enumerate(lines):
    if l.startswith(k + "="):
        lines[i] = new
        break
else:
    lines.append(new)
open(p, "w").write("\n".join(lines) + "\n")
PY
}

# Страница подписки в браузере показывает ещё два адреса (Clash и JSON) с отдельными секретными путями. Пропускаем их через
# kit-sub (те же «Авто» и DNS) и через nginx. Повторный запуск безопасен.
sub_extra_sync() {
  local cfg=/etc/kit-sub/config.json all jp cp extras tmp bak panel_path
  [[ -f $cfg ]] || return 0
  all=$(api POST setting/all '{}')
  jp=$(jq -r '.subJsonPath // ""' <<<"$all"); cp=$(jq -r '.subClashPath // ""' <<<"$all")
  extras=$(jq -nc --arg a "$jp" --arg b "$cp" --arg s "${SUB_PATH:-}" '[$a, $b] | map(select(. != "" and . != "/")) | map("/" + (ltrimstr("/") | rtrimstr("/")) + "/")
    | map(select(test("^/[A-Za-z0-9_-]+/$") and . != $s)) | unique')
  tmp=$(mktemp)
  jq --argjson e "$extras" '.extra_paths = $e' "$cfg" >"$tmp" && install -m 600 "$tmp" "$cfg"
  rm -f "$tmp"
  if [[ ${SINGLE:-no} == yes && -f $PANEL_CONF ]]; then
    local -a ex=()
    mapfile -t ex < <(jq -r '.[]' <<<"$extras")
    tmp=$(mktemp); bak=$(mktemp); cp -p "$PANEL_CONF" "$bak"
    if panel_conf_py addloc "$PANEL_CONF" "$SUB_PATH" "${ex[@]}" >"$tmp" && [[ -s $tmp ]]; then
      cat "$tmp" >"$PANEL_CONF"
      if [[ ${PANEL_ON:-ip} == domain ]] && panel_path=$(panel_web_path); then
        panel_conf_py render "$PANEL_CONF" domain "$SUB_PATH" "$panel_path" "${ex[@]}" >"$tmp" && [[ -s $tmp ]] && cat "$tmp" >"$PANEL_CONF"
      fi
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx
      else cat "$bak" >"$PANEL_CONF"; warn "nginx не принял новые пути подписки – оставил прежние настройки."; fi
    fi
    rm -f "$tmp" "$bak"
  fi
  systemctl restart kit-sub
}

net_panel() { # [domain|ip]
  local want=${1:-} info domain cert key cur new tmp bak rid panel_path old_host new_host all
  [[ ${SINGLE:-no} == yes && -f $PANEL_CONF ]] || die "Работает в режиме «всё на 443» со своим доменом (--domain при установке)."
  info=$(panel_conf_py info "$PANEL_CONF") || die "В настройках nginx нет блока своего домена: панель по домену доступна только при установке с --domain."
  read -r domain cert key <<<"$info"
  cur=${PANEL_ON:-ip}
  if [[ -z $want ]]; then
    if [[ $cur == domain ]]; then echo "Панель и подписка открываются по домену $domain$(mh " (вернуть на IP: kit → Протоколы, порты и маскировка → Панель и подписка: по IP или по домену)")"
    else echo "Панель и подписка открываются по IP ${HOST:-?}; домен $domain – сайт для маскировки$(mh " (открывать и по домену: kit → Протоколы, порты и маскировка → Панель и подписка: по IP или по домену)")"; fi
    return 0
  fi
  [[ $want == domain || $want == ip ]] || die "kit net panel [domain|ip]"
  [[ $want != "$cur" ]] || { say "Уже так: панель и подписка по $([[ $want == domain ]] && echo "домену $domain" || echo "IP")."; return 0; }
  panel_path=$(panel_web_path) || die "Странный путь панели или подписки в $XUI_ENV или $KIT_ENV – не трогаю nginx."
  if [[ $want == domain ]]; then
    dns_a "$domain" | grep -qx "$(host_ip)" || die "Домен $domain не указывает на этот сервер ($(host_ip)). Исправьте A-запись и повторите."
    [[ -s $cert && -s $key ]] || die "Нет сертификата домена ($cert) – не трогаю nginx."
  fi
  tmp=$(mktemp); bak=$(mktemp); cp -p "$PANEL_CONF" "$bak"
  local -a ex=()
  mapfile -t ex < <(jq -r '.extra_paths[]?' /etc/kit-sub/config.json 2>/dev/null || true)
  panel_conf_py render "$PANEL_CONF" "$want" "$SUB_PATH" "$panel_path" "${ex[@]}" >"$tmp" || { rm -f "$tmp" "$bak"; die "Не удалось собрать настройки nginx. Ничего не изменилось."; }
  local -a rids=()
  mapfile -t rids < <(sni_targets | awk -F'\t' '$2 == "self" {print $1}')
  ((${#rids[@]})) || { rm -f "$tmp" "$bak"; die "Не нашёл REALITY со своим доменом."; }
  panel_xver() { # 0|1 – у всех REALITY, чей сайт – блок домена (в том числе REALITY-2)
    local r
    for r in "${rids[@]}"; do
      inbound_patch "$r" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.xver = $x)' --argjson x "$1" || return 1
    done
  }
  # Передача настоящего IP клиента сайту домена (PROXY protocol) нужна, чтобы панель видела, кто заходит.
  local xv=0; [[ $want == domain ]] && xv=1
  panel_revert() { cat "$bak" >"$PANEL_CONF"; panel_xver "$((1 - xv))" || true; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; }
  if [[ $want == domain ]]; then
    cat "$tmp" >"$PANEL_CONF"
    nginx -t >/dev/null 2>&1 || { cat "$bak" >"$PANEL_CONF"; rm -f "$tmp" "$bak"; die "nginx не принял настройки. Ничего не изменилось."; }
    panel_xver 1 || { cat "$bak" >"$PANEL_CONF"; rm -f "$tmp" "$bak"; die "Панель не приняла изменение. Ничего не изменилось."; }
    systemctl reload nginx || { panel_revert; rm -f "$tmp" "$bak"; die "nginx не перезагрузился. Всё возвращено."; }
  else
    panel_xver 0 || { rm -f "$tmp" "$bak"; die "Панель не приняла изменение. Ничего не изменилось."; }
    cat "$tmp" >"$PANEL_CONF"
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx; then panel_revert; rm -f "$tmp" "$bak"; die "nginx не принял настройки. Всё возвращено."; fi
  fi
  rm -f "$tmp" "$bak"
  # Ссылки: адрес подписки в kit, панели и файле с данными входа.
  old_host=${HOST}; new_host=$domain
  if [[ $want == ip ]]; then old_host=$domain; new_host=${HOST}; fi
  kit_env_set PANEL_ON "$want"
  kit_env_set SUB_BASE "https://$([[ $want == domain ]] && echo "$domain" || echo "$HOST")${SUB_PATH}"
  all=$(api POST setting/all '{}')
  api POST setting/update "$(jq -c --arg u "https://$([[ $want == domain ]] && echo "$domain" || echo "$HOST")${SUB_PATH}" '.subURI = $u' <<<"$all")" >/dev/null || warn "Не обновил адрес подписки в панели."
  [[ -f /root/3x-ui.txt ]] && python3 - /root/3x-ui.txt "https://$old_host" "https://$new_host" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
open(p, "w").write(s.replace(a + "/", b + "/").replace(a + ":", b + ":"))
PY
  if [[ $want == domain ]]; then
    say "Панель и подписка теперь открываются и по домену $domain."
    echo "Панель:   https://$domain$panel_path"
    echo "Подписка: https://$domain${SUB_PATH}ПОДПИСКА_ПОЛЬЗОВАТЕЛЯ  (ссылки: kit → Пользователи → Показать ссылки)"
    echo "По IP они тоже работают$(mh ". Вернуть как было: kit → Протоколы, порты и маскировка → Панель и подписка: по IP или по домену")"
  else
    say "Панель и подписка снова только по IP ${HOST}."
    echo "Панель:   https://${HOST}$panel_path"
  fi
}

# ---------- kit net: протоколы, порты, сайт маскировки, отпечаток ----------

net_main_name() { case $1 in REALITY | XHTTP | Hysteria2) return 0 ;; *) return 1 ;; esac; }

net_resolve() { # короткое имя → название подключения
  case ${1,,} in
    reality) echo REALITY ;; reality2 | reality-2) echo REALITY-2 ;; xhttp) echo XHTTP ;; hy2 | hysteria2 | hysteria) echo Hysteria2 ;;
    ws | vless-ws) echo VLESS-WS ;; grpc | trojan | trojan-grpc) echo Trojan-gRPC ;; vmess | vmess-ws) echo VMess-WS ;;
    ss | shadowsocks) echo Shadowsocks ;; tuic) echo TUIC ;; wg | wireguard) echo WireGuard ;;
    awg | amneziawg) echo AmneziaWG ;; awg3 | amneziawg-3.1) echo AmneziaWG-3.1 ;; mtproto) echo MTProto ;;
    *) echo "$1" ;;
  esac
}

inbound_body_of() { # строка подключения (json) → тело для inbounds/update
  jq -c '{id, remark, enable, listen, port, protocol, expiryTime, total,
    settings: (.settings | if type == "string" then . else tojson end),
    streamSettings: (.streamSettings | if type == "string" then . else tojson end),
    sniffing: (.sniffing | if type == "string" then . else tojson end)}' <<<"$1"
}

inbound_patch() { # id фильтр-jq [аргументы jq...]: меняет подключение, ошибка – код возврата, не выход
  local id=$1 filter=$2 row new list before
  shift 2
  list=$(api GET inbounds/list)
  row=$(jq -c --argjson id "$id" '.[] | select(.id == $id)' <<<"$list")
  [[ -n $row ]] || return 1
  new=$(jq -c "$@" "$filter" <<<"$row") || return 1
  before=$(inbounds_down "$list")
  (api POST "inbounds/update/$id" "$(inbound_body_of "$new")" >/dev/null) || return 1
  xray_heal "$before"
}

net_show() {
  local list name port proto listen en sni fp shown_reality2=no mark note fpl=""
  list=$(api GET inbounds/list)
  printf '%s %s %s %s\n' "$(padr Протоколы 22)" "$(padr Порт 12)" "$(padr Статус 8)" "Заметка"
  {
    while IFS='|' read -r name port proto listen en sni fp; do
      [[ -n $name ]] || continue
      [[ $name == REALITY-2 ]] && shown_reality2=yes
      if [[ $listen == 127.0.0.1 ]]; then mark="443/tcp"; else mark="$port/$(port_net "$proto")"; fi
      [[ $(port_net "$proto") == both ]] && mark=$port
      note=""
      [[ -z $sni ]] || note="сайт: $sni"
      [[ -n $fp && -z $fpl ]] && fpl=$fp
      printf '  %s %s %s %s\n' "$(padr "$name" 20)" "$(padr "$mark" 12)" "$(padr "$([[ $en == true ]] && echo вкл || echo выкл)" 8)" "$note"
    done < <(jq -r '.[] | (.streamSettings | if type == "string" then fromjson else . end) as $s
      | [.remark, .port, .protocol, .listen, .enable, ($s.realitySettings.serverNames[0] // ""),
         ($s.realitySettings.settings.fingerprint // $s.tlsSettings.settings.fingerprint // "")] | map(tostring) | join("|")' <<<"$list")
  }
  [[ $shown_reality2 == yes ]] || printf '  %s %s %s %s\n' "$(padr REALITY-2 20)" "$(padr – 12)" "$(padr выкл 8)" "$(mh "включить: kit → Протоколы, порты и маскировка → Второй REALITY на высоком порту")"
  echo
  echo "Отпечаток клиента: ${fpl:-?}$(mh " (сменить: kit → Протоколы, порты и маскировка → Сменить отпечаток клиента)")"
  if [[ ${SINGLE:-no} == yes && -f $PANEL_CONF ]] && panel_conf_py info "$PANEL_CONF" >/dev/null 2>&1; then
    net_panel
  fi
  if jq -e 'any(.[]; .protocol == "hysteria")' <<<"$list" >/dev/null; then
    if [[ -n $(hy_masq_state) ]]; then echo "Hysteria2 отвечает на посторонний запрос страницей сайта$(mh " (выключить: kit → Протоколы, порты и маскировка → Hysteria2: ответ чужим запросам)")"
    else echo "Hysteria2 без маскировки под сайт$(mh " (включить: kit → Протоколы, порты и маскировка → Hysteria2: ответ чужим запросам)")"; fi
  fi
}

net_toggle() { # on|off имя [-y]
  local act=$1 name row id en listen proto port net yes=no
  shift
  [[ -n ${1:-} ]] || die "kit net $act имя (например: kit net $act vmess-ws). Список: kit net"
  name=$(net_resolve "$1"); [[ ${2:-} == -y || ${2:-} == --yes ]] && yes=yes
  row=$(api GET inbounds/list | jq -c --arg n "${name,,}" '[.[] | select((.remark | ascii_downcase) == $n)][0] // empty')
  if [[ -z $row ]]; then
    if [[ $name == REALITY-2 && $act == on ]]; then reality_add; return; fi
    die "Нет подключения «$name». Список: kit → Протоколы, порты и маскировка → Показать протоколы и порты"
  fi
  id=$(jq -r '.id' <<<"$row"); en=$(jq -r '.enable' <<<"$row"); listen=$(jq -r '.listen' <<<"$row")
  proto=$(jq -r '.protocol' <<<"$row"); port=$(jq -r '.port' <<<"$row"); net=$(port_net "$proto")
  if [[ $act == off ]]; then
    [[ $en == true ]] || { say "$name уже выключен."; return 0; }
    if net_main_name "$name" && [[ $yes == no ]]; then
      if [[ -t 0 ]]; then
        local ans; read -r -p "$name – основной протокол. Выключить? [y/N] " ans
        [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return 0; }
      else die "$name – основной протокол. Выключить: kit → Протоколы, порты и маскировка → Выключить или включить протокол"; fi
    fi
    (api POST "inbounds/setEnable/$id" '{"enable":false}' >/dev/null) || die "Панель не приняла изменение. Ничего не изменилось."
    if [[ $listen != 127.0.0.1 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then port_ufw delete "$port" "$net"; fi
    if [[ $listen != 127.0.0.1 ]]; then say "$name выключен, порт $port/$net закрыт$(mh ". Вернуть: kit → Протоколы, порты и маскировка → Выключить или включить протокол")"; else say "$name выключен. Вернуть: kit → Протоколы, порты и маскировка → Выключить или включить протокол"; fi
    echo "Из подписки пропадёт при её обновлении в приложении."
  else
    [[ $en == true ]] && { say "$name уже включён."; return 0; }
    if [[ $listen != 127.0.0.1 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then port_ufw allow "$port" "$net"; fi
    local before; before=$(inbounds_down)
    (api POST "inbounds/setEnable/$id" '{"enable":true}' >/dev/null) || die "Панель не приняла изменение. Ничего не изменилось."
    xray_heal "$before"
    say "$name включён."
  fi
}

net_fp() { # отпечаток
  local f=${1:-} n=0 id old
  [[ -n $f ]] || die "kit net fp отпечаток (chrome, firefox, safari, edge, ios, android, qq, 360, random, randomized)"
  f=${f,,}
  [[ $f =~ ^(chrome|firefox|safari|edge|ios|android|qq|360|random|randomized)$ ]] || die "Неизвестный отпечаток «$f». Доступны: chrome, firefox, safari, edge, ios, android, qq, 360, random, randomized."
  old=$(api GET inbounds/list | jq -r '[.[] | (.streamSettings | if type == "string" then fromjson else . end) | (.realitySettings.settings.fingerprint // .tlsSettings.settings.fingerprint // empty)][0] // "?"')
  while read -r id; do
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end)
      | (if .realitySettings.settings then .realitySettings.settings.fingerprint = $f else . end)
      | (if .tlsSettings.settings then .tlsSettings.settings.fingerprint = $f else . end)
      | (if .externalProxy then .externalProxy |= map(if has("fingerprint") then .fingerprint = $f else . end) else . end))' --arg f "$f" \
      && n=$((n + 1))
  done < <(api GET inbounds/list | jq -r '.[] | select((.streamSettings | if type == "string" then fromjson else . end) | (.security == "reality" or .security == "tls")) | .id')
  say "Отпечаток $old → ${B}$f${N}, обновлено подключений: $n."
  echo "Подписка обновится сама; вручную сохранённые ссылки замените (kit → Пользователи → Показать ссылки)."
  [[ ${KIT_IN_MENU:-} == 1 ]] || echo "Вернуть прежний: kit → Протоколы, порты и маскировка → Сменить отпечаток клиента."
}

cmd_net() {
  local sub=${1:-}
  [[ -z $sub ]] || shift
  case ${sub,,} in
    "") net_show ;;
    site)
      if [[ ${1:-} == cleanup ]]; then
        [[ -f $SNI_GRACE ]] || { say "Прежних имён сайта нет – убирать нечего."; return 0; }
        grace_cleanup all; return $?
      fi
      [[ $# -gt 0 ]] || set -- --nearby; sni_rotate "$@" ;;
    port) port_set "$@" ;;
    off | on) net_toggle "${sub,,}" "$@" ;;
    fp) net_fp "$@" ;;
    masq) hy_masq "$@" ;;
    dns) net_dns "$@" ;;
    panel) net_panel "$@" ;;
    split) net_split "$@" ;;
    vision) case ${1:-} in on) cmd_vision --all ;; off) cmd_vision --all off ;; *) die "kit net vision on|off" ;; esac ;;
    *) die "kit net [site [cleanup] | port имя порт | off имя | on имя | fp отпечаток | masq on|off | dns on|off | panel domain|ip | split on|off|check|apply | vision on|off]" ;;
  esac
}

# ---------- меню (как у x-ui) ----------

BOX_W=48
box_rule() { local i; for ((i = 0; i < BOX_W; i++)); do printf '─'; done; }
box_top() { printf '╔'; box_rule; printf '╗\n'; }
box_bot() { printf '╚'; box_rule; printf '╝\n'; }
box_sep() { printf '│'; box_rule; printf '│\n'; }
padr() { local n=$(($2 - ${#1})); ((n < 0)) && n=0; printf '%s%*s' "$1" "$n" ''; }  # по символам: printf %-Ns считает байты
box_line() { printf '│  %s│\n' "$(padr "$1" $((BOX_W - 2)))"; }
box() { # заголовок, затем пункты; пустой пункт – разделитель
  local t=$1 l; shift
  box_top; box_line "$t"; box_sep
  for l in "$@"; do if [[ -z $l ]]; then box_sep; else box_line "$l"; fi; done
  box_bot
}
ask_tty() { read -r -p "$1" REPLY </dev/tty || exit 0; }
ask_num() { ask_tty "$1"; REPLY=${REPLY//[[:space:]]/}; }
pause() { read -r -p "${D}Enter – в меню${N} " _ </dev/tty || exit 0; }
# Подсказка «как сделать через меню» нужна в командной строке, но лишняя, когда человек уже в меню.
mh() { [[ ${KIT_IN_MENU:-} == 1 ]] || printf '%s' "$*"; }
run_action() { ( export KIT_IN_MENU=1; "$@" ) || true; }

menu_status() {
  local sni users st auto
  sni=$(sni_targets 2>/dev/null | awk -F'\t' '$2 == "reality" || $2 == "self" {print $4; exit}' || true)
  users=$(clients 2>/dev/null | jq '[.[] | select(.email | test("-awg[0-9]*$") | not)] | length' 2>/dev/null || echo "?")
  if systemctl is-active -q x-ui; then st="панель работает"; else st="панель НЕ работает"; fi
  if auto_enabled; then auto=вкл; else auto=выкл; fi
  echo "Сервер: ${HOST:-?} · Сайт маскировки: ${sni:--}"
  echo "Состояние: $st · Xray $(xray_version 2>/dev/null || echo '?') · пользователей $users · автообновление $auto"
}

pick_user() {
  cmd_list
  ask_tty "Имя пользователя: "
  PICK=${REPLY//[[:space:]]/}
  [[ -n $PICK ]] || return 1
  valid_name "$PICK"
}

u_add() {
  local name gb days dev a=()
  ask_tty "Имя пользователя: "; name=${REPLY//[[:space:]]/}
  ask_tty "Лимит трафика, ГБ (Enter – без лимита): "; gb=${REPLY//[[:space:]]/}
  ask_tty "Срок, дней (Enter – без срока): "; days=${REPLY//[[:space:]]/}
  ask_tty "Устройств (Enter – без ограничения): "; dev=${REPLY//[[:space:]]/}
  [[ -z $gb ]] || a+=(--gb "$gb"); [[ -z $days ]] || a+=(--days "$days"); [[ -z $dev ]] || a+=(--devices "$dev")
  cmd_add "$name" "${a[@]}"
}
u_link() {
  pick_user || return 0
  ask_num "1 – ссылки, 2 – AmneziaVPN, 3 – Telegram [1]: "
  case ${REPLY:-1} in 2) cmd_link "$PICK" --amnezia ;; 3) cmd_link "$PICK" --telegram ;; *) cmd_link "$PICK" ;; esac
}
u_limit() {
  local gb days dev a=()
  pick_user || return 0
  echo "Enter – не менять, 0 – без ограничения."
  ask_tty "Лимит трафика, ГБ: "; gb=${REPLY//[[:space:]]/}
  ask_tty "Срок, дней: "; days=${REPLY//[[:space:]]/}
  ask_tty "Устройств: "; dev=${REPLY//[[:space:]]/}
  [[ -z $gb ]] || a+=(--gb "$gb"); [[ -z $days ]] || a+=(--days "$days"); [[ -z $dev ]] || a+=(--devices "$dev")
  ((${#a[@]})) || { echo "Ничего не изменено."; return 0; }
  cmd_limit "$PICK" "${a[@]}"
}
u_toggle() {
  pick_user || return 0
  ask_num "1 – выключить, 2 – включить: "
  case $REPLY in 1) cmd_toggle "$PICK" false ;; 2) cmd_toggle "$PICK" true ;; *) echo "Отменено." ;; esac
}
u_del() { pick_user || return 0; cmd_del "$PICK"; }

menu_users() {
  local c
  while :; do
    echo
    box "Пользователи" "1. Список (трафик, срок, статус)" "2. Добавить" "3. Показать ссылки" "4. Изменить лимит" "5. Выключить или включить" "6. Удалить" "" "0. Назад"
    ask_num "Выбор [0-6]: "; c=$REPLY
    case $c in
      1) run_action cmd_list; pause ;;
      2) run_action u_add; pause ;;
      3) run_action u_link; pause ;;
      4) run_action u_limit; pause ;;
      5) run_action u_toggle; pause ;;
      6) run_action u_del; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

pick_proto() { # PICK = название подключения (в том числе ещё не созданный REALITY-2)
  local -a names=(); local i n en
  mapfile -t names < <(api GET inbounds/list | jq -r '.[] | [.remark, (if .enable then "вкл" else "выкл" end)] | @tsv')
  names+=("REALITY-2"$'\t'"создать")
  i=0
  for n in "${names[@]}"; do
    i=$((i + 1))
    if [[ $n == REALITY-2$'\t'* ]] && api GET inbounds/list | jq -e 'any(.[]; .remark == "REALITY-2")' >/dev/null; then names[i-1]=""; i=$((i)); continue; fi
    printf '  %2d  %-16s %s\n' "$i" "${n%%$'\t'*}" "${n#*$'\t'}"
  done
  ask_num "Номер: "
  [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#names[@]})) && [[ -n ${names[REPLY-1]} ]] || { echo "Отменено."; return 1; }
  PICK=${names[REPLY-1]%%$'\t'*}
}

n_site() {
  ask_num "1 – подобрать автоматически (сначала соседи по подсети), 2 – другой сайт, адрес введёте сами [1]: "
  if [[ ${REPLY:-1} == 2 ]]; then
    ask_tty "Адрес сайта (например example.com): "
    [[ -n ${REPLY//[[:space:]]/} ]] || { echo "Отменено."; return 0; }
    sni_rotate "${REPLY//[[:space:]]/}"
  else
    sni_rotate --nearby
  fi
}
n_port() { local p; pick_proto || return 0; p=$PICK; ask_num "Новый порт: "; port_set "$p" "$REPLY"; }
n_toggle() {
  local en
  pick_proto || return 0
  en=$(api GET inbounds/list | jq -r --arg n "$PICK" '[.[] | select(.remark == $n)][0].enable // "none"')
  case $en in
    true) net_toggle off "$PICK" ;;
    false) net_toggle on "$PICK" ;;
    *) net_toggle on "$PICK" ;;
  esac
}
n_panel() {
  net_panel
  ask_num "1 – открывать по домену, 2 – только по IP, Enter – оставить: "
  case $REPLY in 1) net_panel domain ;; 2) net_panel ip ;; esac
}
n_fp() {
  local -a fps=(chrome firefox safari edge ios android qq 360 random randomized); local i
  for i in "${!fps[@]}"; do printf '  %2d  %s\n' "$((i + 1))" "${fps[$i]}"; done
  ask_num "Номер: "
  [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#fps[@]})) || { echo "Отменено."; return 0; }
  net_fp "${fps[REPLY-1]}"
}

# Пункты меню «Протоколы, порты и маскировка»: вопросы вместо аргументов команд.
n_split() {
  net_split
  echo
  ask_num "1 – включить, 2 – выключить, 3 – проверить список, 4 – применить правки списка, Enter – назад: "
  case $REPLY in 1) net_split on ;; 2) net_split off ;; 3) net_split check ;; 4) net_split apply ;; esac
}
n_dns() {
  net_dns
  echo
  ask_num "1 – включить, 2 – выключить, Enter – оставить как есть: "
  case $REPLY in 1) net_dns on ;; 2) net_dns off ;; esac
}
n_masq() {
  echo "Hysteria2 может отвечать на чужие запросы страницей обычного сайта, а не ошибкой."
  ask_num "1 – включить, 2 – выключить, Enter – оставить как есть: "
  case $REPLY in 1) hy_masq on ;; 2) hy_masq off ;; esac
}
n_cleanup() {
  [[ -f $SNI_GRACE ]] || { say "Прежних имён сайта нет – убирать нечего."; return 0; }
  grace_cleanup all
}

n_vision() {
  echo "Поток xtls-rprx-vision ускоряет REALITY и нужен большинству клиентов."
  ask_num "1 – включить у всех пользователей, 2 – выключить, Enter – оставить: "
  case $REPLY in 1) cmd_vision --all ;; 2) cmd_vision --all off ;; esac
}

menu_net() {
  local c
  while :; do
    echo
    box "Протоколы, порты и маскировка" "1. Показать протоколы и порты" "2. Сменить сайт маскировки" "3. Сменить порт протокола" "4. Выключить или включить протокол" "5. Сменить отпечаток клиента" "6. Второй REALITY на высоком порту" "7. Панель и подписка: по IP или по домену" "8. Раздельная маршрутизация" "9. DNS в подписках (против утечек)" "10. Hysteria2: ответ чужим запросам" "11. Убрать прежние имена сайта" "12. Поток vision у REALITY" "" "0. Назад"
    ask_num "Выбор [0-12]: "; c=$REPLY
    case $c in
      1) run_action net_show; pause ;;
      2) run_action n_site; pause ;;
      3) run_action n_port; pause ;;
      4) run_action n_toggle; pause ;;
      5) run_action n_fp; pause ;;
      6) run_action net_toggle on reality2; pause ;;
      7) run_action n_panel; pause ;;
      8) run_action n_split; pause ;;
      9) run_action n_dns; pause ;;
      10) run_action n_masq; pause ;;
      11) run_action n_cleanup; pause ;;
      12) run_action n_vision; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

menu_check() {
  local c
  while :; do
    echo
    box "Проверка сервера" "1. Быстрая проверка" "2. Глубокая (подключиться клиентом)" "3. Исправить безопасное" "" "0. Назад"
    ask_num "Выбор [0-3]: "; c=$REPLY
    case $c in
      1) run_action cmd_check; pause ;;
      2) run_action cmd_check --deep; pause ;;
      3) run_action cmd_fix; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

menu_auto() {
  local ans
  if auto_enabled; then
    ask_tty "Автообновление сейчас включено (ночью, только подписанные релизы). Выключить? [y/N] "
    [[ $REPLY =~ ^[yYдД]$ ]] && auto_off && say "Автообновление выключено. Обновляться вручную: пункт 4."
  else
    ask_tty "Автообновление сейчас выключено. Включить? [y/N] "
    [[ $REPLY =~ ^[yYдД]$ ]] && auto_on && say "Автообновление включено."
  fi
  return 0
}

menu_main() {
  local c
  while :; do
    echo
    box "3X-UI KIT $KIT_VERSION – управление сервером" "1. Пользователи" "2. Протоколы, порты и маскировка" "3. Проверка сервера" "" \
      "4. Обновить kit и подписку" "5. Обновить панель 3X-UI" "6. Автообновление: включить или выключить" "" \
      "7. Резервная копия" "8. Версии" "" "9. Панель 3X-UI (меню x-ui)" "10. Удалить KIT с сервера" "0. Выход"
    echo
    menu_status
    update_hint
    echo
    ask_num "Выбор [0-10]: "; c=$REPLY
    case $c in
      1) menu_users ;;
      2) menu_net ;;
      3) menu_check ;;
      4) run_action cmd_update; pause ;;
      5) run_action panel_update; pause ;;
      6) run_action menu_auto; pause ;;
      7) run_action cmd_backup; pause ;;
      8) run_action cmd_version; pause ;;
      9) command -v x-ui >/dev/null && x-ui || echo "Меню x-ui не найдено." ;;
      10) run_action cmd_uninstall; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

# ---------- полное удаление ----------

# Порты, которые KIT открывал в ufw: подключения и панель из базы панели, подписка из конфига.
uninstall_ports() {
  python3 - <<'PY' 2>/dev/null || true
import json, sqlite3
out = set()
try:
    db = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
    out.update(str(r[0]) for r in db.execute("SELECT port FROM inbounds"))
    out.update(r[0] for r in db.execute("SELECT value FROM settings WHERE key IN ('webPort', 'subPort')"))
except Exception:
    pass
try:
    out.add(str(json.load(open("/etc/kit-sub/config.json")).get("port", "")))
except Exception:
    pass
print("\n".join(sorted(p for p in out if p.isdigit())))
PY
}

cmd_uninstall() { # [--yes] [--no-backup] [--dry-run]
  local yes=no backup=ask dry=no a
  for a in "$@"; do
    case $a in
      --yes | -y) yes=yes ;;
      --no-backup) backup=no ;;
      --dry-run) dry=yes ;;
      *) die "kit uninstall [--yes] [--no-backup] [--dry-run]" ;;
    esac
  done
  local -a units=(x-ui kit-sub kit-limit.timer kit-limit.service kit-update.timer kit-update.service)
  local -a paths=(/usr/local/x-ui /etc/x-ui /var/log/x-ui /usr/local/lib/kit-sub /etc/kit-sub /etc/kit /var/www/kit
    /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf /etc/cron.d/kit-xui-menu /etc/cron.d/kit-sub-cert /etc/cron.d/kit-nginx-reload
    /root/cert/ip /root/cert/custom /root/cert/self /root/cert/domain /root/3x-ui.txt /usr/bin/x-ui
    /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
    /var/log/3x-ui-install.log /var/log/kit-install-check.log /var/log/kit-domain-cert.log /var/log/kit-update.log)
  local -a ports=()
  mapfile -t ports < <(uninstall_ports)

  echo
  echo "${B}Полное удаление 3X-UI KIT${N}"
  echo "Будет остановлено и удалено: панель 3X-UI с базой (все пользователи и ключи), подписка, таймеры, настройки nginx от KIT,"
  echo "сертификаты в /root/cert, логи установки, команда kit. Сделать это обратно нельзя."
  echo "Останутся: пакеты (nginx, fail2ban, jq и др.), ваш SSH и правила ufw для SSH."
  [[ $dry == no ]] || echo "${Y}Пробный прогон: ничего не удаляется.${N}"
  echo
  if [[ $dry == yes ]]; then
    printf '  сервисы:   %s\n' "${units[*]}"
    printf '  каталоги:  %s\n' "${paths[*]}"
    printf '  ufw:       %s\n' "${ports[*]:-нет}"
    return 0
  fi

  if [[ $yes == no ]]; then
    [[ -t 0 && -t 1 ]] || die "Без терминала нужен флаг --yes."
    ask_tty "Для подтверждения введите слово «удалить»: " || return 1
    a=${REPLY//[[:space:]]/}; a=${a,,}
    [[ $a == "удалить" || $a == "delete" ]] || { echo "Отменено, ничего не тронуто."; return 0; }
    if [[ $backup == ask ]]; then
      ask_tty "Сделать резервную копию перед удалением? Она останется в /root. [Y/n] " || REPLY=""
      [[ ${REPLY,,} == n* || ${REPLY,,} == н* ]] && backup=no || backup=yes
    fi
  fi
  if [[ $backup != no ]]; then
    (cmd_backup) || die "Копию сделать не удалось, поэтому ничего не удалил. Повторите или запустите с --no-backup."
  fi

  local u p sshp
  say "Останавливаю сервисы"
  for u in "${units[@]}"; do systemctl disable --now "$u" >/dev/null 2>&1 || true; done
  pkill -f '/usr/local/x-ui/' >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/x-ui.service /etc/systemd/system/kit-*.service /etc/systemd/system/kit-*.timer
  systemctl daemon-reload >/dev/null 2>&1 || true

  say "Закрываю порты в ufw"
  sshp=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u)
  if command -v ufw >/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      [[ $p == 22 || " $sshp " == *" $p "* ]] && continue
      ufw delete allow "$p" >/dev/null 2>&1 || true
      ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
      ufw delete allow "$p/udp" >/dev/null 2>&1 || true
    done
  fi

  say "Убираю nginx от KIT"
  sed -i '/kit-stream\.conf/d' /etc/nginx/nginx.conf 2>/dev/null || true
  rm -f /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf
  if command -v nginx >/dev/null 2>&1; then
    if [[ -z $(find /etc/nginx/conf.d -mindepth 1 -name '*.conf' 2>/dev/null) && -z $(find /etc/nginx/sites-enabled -mindepth 1 ! -name default 2>/dev/null) ]]; then
      systemctl disable --now nginx >/dev/null 2>&1 || true
    elif nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || true
    else
      warn "nginx не принял конфиг после удаления наших файлов: посмотрите nginx -t."
    fi
  fi

  # Порт 80 установщик открывал ради сертификата: если после уборки на нём никто не слушает, закрываем и его.
  if command -v ufw >/dev/null 2>&1 && [[ " $sshp " != *" 80 "* ]] && ! ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw delete allow 80 >/dev/null 2>&1 || true
  fi

  say "Удаляю файлы и сертификаты"
  # acme.sh убираем, только если там нет чужих сертификатов.
  if [[ -x /root/.acme.sh/acme.sh ]]; then
    if [[ -z $(/root/.acme.sh/acme.sh --list 2>/dev/null | awk 'NR > 1 && $1 !~ /^[0-9.]+$/ {print $1}' | grep -vxF -e "${HOST:-}" -e "${LINK_HOST:-}" | grep . || true) ]]; then
      /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
      rm -rf /root/.acme.sh
    else
      warn "В acme.sh есть другие сертификаты, его оставил."
    fi
  fi
  rm -rf -- /root/x-ui-before-update-* /root/x-ui-before-sni-*
  for p in "${paths[@]}"; do rm -rf -- "$p"; done
  # /root/cert мог содержать и чужие сертификаты: убираем только наши подкаталоги, а саму папку – если опустела.
  rmdir /root/cert 2>/dev/null || true
  # Правила fail2ban от 3X-UI (3x-ipl): без файлов джейл остался бы загруженным до перезапуска службы.
  if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
    fail2ban-client reload >/dev/null 2>&1 || systemctl reload fail2ban >/dev/null 2>&1 || true
  fi

  echo
  say "Готово: KIT удалён. Резервные копии (kit-backup-*.tar.gz в /root), если вы их делали, не тронуты: храните как пароль или удалите."
  echo "Пакеты остались; убрать их: apt purge nginx jq qrencode socat fail2ban. Перезагрузка не нужна."
  rm -f /usr/local/bin/kit
}

usage() {
  cat <<EOF
${B}3X-UI KIT $KIT_VERSION${N} – команды (то же самое есть в меню: просто ${B}kit${N})

  kit                        меню
  kit user …                 add, list, link, limit, on, off, del
  kit links [имя]            все ссылки на подключения (подписка, протоколы, Telegram)
  kit net …                  протоколы, порты, сайт маскировки, отпечаток
  kit check [--deep|--fix]   проверка сервера
  kit update [--panel]       обновление (--auto и --manual – автообновление)
  kit backup                 копия сервера
  kit uninstall              полное удаление (спросит подтверждение; --dry-run – только показать)
  kit version                версии
EOF
}

# Регистр и «users» вместо «user» не должны ломать команду; имя пользователя (третье слово) не трогаем.
cmd_key="${1:-} ${2:-}"; cmd_key=${cmd_key,,}; cmd_key=${cmd_key/users /user }
case "$cmd_key" in
  " ") if [[ -t 0 && -t 1 ]]; then menu_main; else usage; fi ;;
  "user add") shift 2; cmd_add "$@"; update_hint ;;
  "user list") cmd_list; update_hint ;;
  "user link") shift 2; cmd_link "$@" ;;
  "links "*) shift; cmd_links "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  "user enforce") shift 2; cmd_enforce "$@" ;;
  "user vision") shift 2; cmd_vision "$@" ;;
  "net ") shift; cmd_net; update_hint ;;
  "net "*) shift; cmd_net "$@" ;;
  "sni rotate") shift 2; sni_rotate "$@" ;;
  "sni "*) [[ -z ${2:-} ]] || die "Команда: kit net site"; sni_show ;;
  "port set") shift 2; port_set "$@" ;;
  "port "*) [[ -z ${2:-} ]] || die "Команда: kit net port имя порт"; net_show ;;
  "reality add") shift 2; reality_add "$@" ;;
  "panel update") shift 2; panel_update "$@" ;;
  "__limit-timer on") limit_timer_on ;;
  "__xver "*) # служебная: xver у всех REALITY со своим доменом (возврат после неудачного --restore)
    [[ ${2:-} =~ ^[01]$ ]] || exit 1
    while read -r _id; do
      inbound_patch "$_id" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.xver = $x)' --argjson x "$2" || true
    done < <(sni_targets | awk -F'\t' '$2 == "self" {print $1}') ;;
  "__links "*) links_block "${2:-}" "${3:-}" ;;
  "__subextra "*) # служебная: её зовёт kit update уже новой версией, поэтому заодно догоняем таймер лимита (старый kit его не ставит)
    limit_timer_enabled || limit_timer_on >/dev/null 2>&1 || true
    (mt_sync) >/dev/null 2>&1 || true # ссылка MTProto в панели и секреты под нынешний сайт (1.2.1)
    (grace_cleanup) >/dev/null 2>&1 || true
    sub_extra_sync ;;
  "__mtproto "*) mt_sync "${2:-}" ;;
  "__applinks "*) app_links "${2:-}" ;;
  "update "*) shift; cmd_update "$@" ;;
  "backup "*) cmd_backup ;;
  "uninstall"*) shift; cmd_uninstall "$@" ;;
  "check "*) shift; cmd_check "$@" ;;
  "fix "*) shift; cmd_fix "$@" ;;
  "version "*|"--version "*|"-v "*) cmd_version ;;
  *) usage; update_hint ;;
esac
