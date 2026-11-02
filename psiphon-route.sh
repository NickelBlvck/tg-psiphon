#!/usr/bin/env bash
# ============================================================================
#  psiphon-route — поднимает TUN-интерфейс поверх Psiphon и направляет
#  через него выбранный трафик (Telegram + пользовательский список маршрутов).
#
#  Рассчитан на сервер, где Psiphon уже поднят через vps-psiphon
#  (ставится в том числе из RemnaSuper): Psiphon работает в Docker и отдаёт
#  локальный SOCKS5 (порт 1080 на docker0/127.0.0.1; UDP не поддерживается).
#
#  Схема трафика:
#    приложения хоста ──(ip route)──▶ psiphon0 (TUN) ──▶ tun2socks (Docker)
#      ──▶ SOCKS5 vps-psiphon ──▶ Psiphon ──▶ интернет
#
#  Команды:
#    install          установить (конфиг, список маршрутов, systemd-юниты)
#    start            поднять туннель и применить маршруты
#    stop             снять маршруты и остановить туннель
#    restart          перезапуск
#    refresh          обновить DNS-маршруты доменов / самовосстановление
#    status           состояние туннеля и проверка api.telegram.org
#    update-cidrs     обновить блок Telegram CIDR из официального списка
#    install-psiphon  установить сам vps-psiphon (если ещё не стоит)
#    logs [N]         логи контейнера tun2socks
#    uninstall        удалить psiphon-route
# ============================================================================
set -uo pipefail

VERSION="1.1.0"

CONF_DIR="/etc/psiphon-route"
CONF_FILE="$CONF_DIR/psiphon-route.conf"
ROUTES_FILE="$CONF_DIR/routes.list"
STATE_DIR="/var/lib/psiphon-route"
STATE_FILE="$STATE_DIR/domain-ips"
BIN="/usr/local/bin/psiphon-route"
SYSTEMD_DIR="/etc/systemd/system"

TUN_NAME="psiphon0"
TUN_ADDR="198.18.0.1/30"
TUN_ADDR6="fd00:198:18::1/64"
CONTAINER="psiphon-tun2socks"
IMAGE="xjasonlyu/tun2socks:latest"
TG_CIDR_URL="https://core.telegram.org/resources/cidr.txt"

# --- Дефолты (переопределяются в $CONF_FILE) ---
PSIPHON_SOCKS=""       # host:port; пусто = авто-поиск SOCKS5 vps-psiphon
PSIPHON_REGION=""      # для install-psiphon (ISO-код страны выхода)
MTU=""                 # пусто = не передавать флаг (умолчание tun2socks)
ENABLE_IPV6="0"        # 1 = маршрутизировать и IPv6-адреса

# Официальный список Telegram CIDR (fallback, если не удалось скачать)
TG_CIDRS_FALLBACK=(
  "91.105.192.0/23" "91.108.4.0/22" "91.108.8.0/22" "91.108.12.0/22"
  "91.108.16.0/22" "91.108.20.0/22" "91.108.56.0/22" "149.154.160.0/20"
  "95.161.64.0/20"
  "2001:b28:f23d::/48" "2001:b28:f23f::/48" "2001:67c:4e8::/48"
  "2001:b28:f242::/48" "2001:b28:f243::/48" "2a0a:f280:203::/48"
)

# ----------------------------------------------------------------------------
# Утилиты
# ----------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] ВНИМАНИЕ: %s\n' "$(date '+%F %T')" "$*" >&2; }
err()  { printf '[%s] ОШИБКА: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { err "$*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Запустите от root"; }

# ask "вопрос" → 0, если пользователь согласился (или нажал Enter на умолчании [Y])
ask() {
  [[ -t 0 ]] || return 1
  local a
  read -r -p "$1 [Y/n] " a || return 1
  ! [[ "$a" =~ ^(n|N|no|нет|н)$ ]]
}

load_conf() {
  [[ -f "$CONF_FILE" ]] && . "$CONF_FILE"
}

ensure_dirs() { mkdir -p "$CONF_DIR" "$STATE_DIR"; }

trim() { # trim <имя_переменной> — убирает пробелы по краям значения
  local __v="${!1}"
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$1" '%s' "$__v"
}

docker0_addr() {
  ip -4 -o addr show dev docker0 scope global 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1]; exit}'
}

tcp_open() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; }

# classify_line <строка> → cidr | cidr6 | ip | domain | unknown
classify_line() {
  local l=$1
  # IPv6-адрес/CIDR: до '/' только hex и двоеточия (отсекает "domain:port")
  if [[ "$l" == *:* && "${l%%/*}" =~ ^[0-9a-fA-F:]+$ ]]; then echo cidr6; return; fi
  [[ "$l" == */* ]] && { echo cidr; return; }
  if [[ "$l" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo ip; return; fi
  if [[ "$l" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]]; then
    echo domain; return
  fi
  echo unknown
}

# cidr_contains <cidr|ip> <ip> → 0, если ip входит в сеть (только v4)
cidr_contains() {
  local cidr=$1 ip=$2 net mask n i m
  net=${cidr%%/*}
  if [[ "$cidr" != */* ]]; then [[ "$net" == "$ip" ]] && return 0 || return 1; fi
  mask=${cidr##*/}
  [[ "$mask" =~ ^[0-9]+$ ]] || return 1
  ip2int() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (10#${a:-0} << 24) + (10#${b:-0} << 16) + (10#${c:-0} << 8) + 10#${d:-0} ))
  }
  n=$(ip2int "$net"); i=$(ip2int "$ip") || return 1
  [[ $mask -eq 0 ]] && return 0
  m=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
  [[ $(( n & m )) -eq $(( i & m )) ]]
}

# ----------------------------------------------------------------------------
# Установка зависимостей для чистой машины
# ----------------------------------------------------------------------------
pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "$@"
  else
    return 1
  fi
}

ensure_base_deps() {
  local missing=() c
  for c in curl getent ip; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]})) || return 0
  log "Не хватает утилит: ${missing[*]} — ставлю…"
  pkg_install curl iproute2 glibc || true
  for c in curl getent ip; do
    command -v "$c" >/dev/null 2>&1 || die "Утилита '$c' не найдена — установите вручную и повторите"
  done
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0
  echo
  if ask "Docker не найден. Установить (официальный скрипт get.docker.com)?"; then
    log "Устанавливаю Docker…"
    curl -fsSL https://get.docker.com | sh || die "Не удалось установить Docker"
    systemctl enable --now docker >/dev/null 2>&1 || true
    command -v docker >/dev/null 2>&1 || die "Docker установлен, но не найден в PATH — перезапустите сессию"
    log "Docker установлен"
  else
    die "Docker обязателен для работы туннеля — установите его и повторите: psiphon-route install"
  fi
}

ensure_tun_module() {
  [[ -e /dev/net/tun ]] && return 0
  modprobe tun 2>/dev/null || true
  [[ -e /dev/net/tun ]] || die "Нет /dev/net/tun — у вашего провайдера не проброшен TUN? Выполните: modprobe tun"
}

# ----------------------------------------------------------------------------
# Поиск SOCKS5 Psiphon
# ----------------------------------------------------------------------------
detect_socks() {
  local h p d0
  if [[ -n "${PSIPHON_SOCKS:-}" ]]; then
    h="${PSIPHON_SOCKS%%:*}"; p="${PSIPHON_SOCKS##*:}"
    [[ "$PSIPHON_SOCKS" != *:* ]] && p=1080
    if tcp_open "$h" "$p"; then
      SOCKS_HOST="$h"; SOCKS_PORT="$p"; SOCKS_ADDR="$h:$p"
      return 0
    fi
    return 1
  fi
  local -a hosts=()
  d0=$(docker0_addr)
  [[ -n "$d0" ]] && hosts+=("$d0")
  hosts+=("127.0.0.1")
  # vps-psiphon: инстанс N слушает порт 1080+N-1
  for h in "${hosts[@]}"; do
    for p in 1080 1081 1082 1083 1084 1085; do
      if tcp_open "$h" "$p"; then
        SOCKS_HOST="$h"; SOCKS_PORT="$p"; SOCKS_ADDR="$h:$p"
        return 0
      fi
    done
  done
  return 1
}

ensure_socks() {
  if detect_socks; then
    log "SOCKS5 Psiphon: $SOCKS_ADDR"
    return 0
  fi
  err "Не найден SOCKS5 Psiphon (порты 1080-1085 на docker0/127.0.0.1)."
  err "  - поставьте Psiphon:  psiphon-route install-psiphon   (или через RemnaSuper)"
  err "  - либо задайте вручную в $CONF_FILE:  PSIPHON_SOCKS=\"хост:порт\""
  return 1
}

# ----------------------------------------------------------------------------
# Контейнер tun2socks и TUN-интерфейс
# ----------------------------------------------------------------------------
start_tun2socks() {
  ensure_socks || return 1
  command -v docker >/dev/null || die "docker не установлен (нужен для vps-psiphon и tun2socks)"
  [[ -e /dev/net/tun ]] || die "Нет /dev/net/tun — выполните: modprobe tun"

  local want_proxy="socks5://$SOCKS_HOST:$SOCKS_PORT"
  local -a args=(-device "tun://$TUN_NAME" -proxy "$want_proxy" -loglevel warning)
  [[ -n "${MTU:-}" ]] && args+=(-mtu "$MTU")

  docker pull -q "$IMAGE" >/dev/null 2>&1 || true

  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)
    local cur_args
    cur_args=$(docker inspect -f '{{range .Args}}{{.}} {{end}}' "$CONTAINER" 2>/dev/null)
    if [[ "$cur_args" != *"$want_proxy"* ]]; then
      log "Адрес SOCKS изменился ($cur_args→ $want_proxy), пересоздаю контейнер"
      docker rm -f "$CONTAINER" >/dev/null
      running="absent"
    fi
    if [[ "$running" == "true" ]]; then
      return 0
    fi
    docker start "$CONTAINER" >/dev/null || { err "Не удалось запустить $CONTAINER"; return 1; }
  else
    docker run -d --name "$CONTAINER" --restart unless-stopped \
      --net host --cap-add NET_ADMIN --device /dev/net/tun \
      "$IMAGE" "${args[@]}" >/dev/null || { err "Не удалось создать $CONTAINER"; return 1; }
  fi
  log "Контейнер $CONTAINER запущен"
}

ensure_tun() {
  local i=0
  while ! ip link show "$TUN_NAME" >/dev/null 2>&1; do
    (( i++ >= 30 )) && { err "Интерфейс $TUN_NAME не появился за 15 c"; return 1; }
    sleep 0.5
  done
  if [[ -z "$(ip -4 -o addr show dev "$TUN_NAME" 2>/dev/null)" ]]; then
    ip addr replace "$TUN_ADDR" dev "$TUN_NAME"
  fi
  ip link set "$TUN_NAME" up
  if [[ "$ENABLE_IPV6" == "1" ]]; then
    ip -6 addr replace "$TUN_ADDR6" dev "$TUN_NAME" 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------------
# Маршруты
# ----------------------------------------------------------------------------
resolve_domain() { # <домен> <tmp_state_file>
  local d=$1 tmp=$2
  local ips
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
  if [[ "$ENABLE_IPV6" == "1" ]]; then
    ips="${ips}
$(getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}' | sort -u)"
  fi
  if [[ -z "${ips//[[:space:]]/}" ]]; then
    warn "Не удалось резолвить '$d' — сохраняю прежние маршруты"
    [[ -f "$STATE_FILE" ]] && awk -v d="$d" '$2 == d { print $1 "\t" $2 }' "$STATE_FILE" >> "$tmp"
    return
  fi
  while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" == "$SOCKS_HOST" ]] && continue
    if [[ "$ip" == *:* ]]; then
      ip -6 route replace "$ip/128" dev "$TUN_NAME"
    else
      ip route replace "$ip/32" dev "$TUN_NAME"
    fi
    printf '%s\t%s\n' "$ip" "$d" >> "$tmp"
  done <<< "$ips"
}

add_line() { # <строка> <tmp_state_file>
  local line=$1 tmp=$2 kind
  kind=$(classify_line "$line")
  case "$kind" in
    cidr6)
      if [[ "$ENABLE_IPV6" != "1" ]]; then
        warn "IPv6 выключен (ENABLE_IPV6=0), пропускаю $line"
        return
      fi
      ip -6 route replace "$line" dev "$TUN_NAME"
      ;;
    cidr)
      if [[ -n "${SOCKS_HOST:-}" ]] && cidr_contains "$line" "$SOCKS_HOST"; then
        warn "$line накрывает адрес SOCKS5 ($SOCKS_HOST) — пропускаю, иначе петля"
        return
      fi
      ip route replace "$line" dev "$TUN_NAME"
      ;;
    ip)
      [[ "$line" == "$SOCKS_HOST" ]] && return
      ip route replace "$line/32" dev "$TUN_NAME"
      ;;
    domain) resolve_domain "$line" "$tmp" ;;
    *)      warn "Не понял строку '$line' в $ROUTES_FILE — пропускаю" ;;
  esac
}

apply_routes() {
  [[ -f "$ROUTES_FILE" ]] || die "Нет $ROUTES_FILE — выполните: psiphon-route install"
  [[ -n "${SOCKS_HOST:-}" ]] || detect_socks || true
  local tmp="$STATE_DIR/.new-domain-ips"
  : > "$tmp"
  local raw line
  while IFS= read -r raw; do
    line="${raw%%#*}"
    trim line
    [[ -z "$line" ]] && continue
    add_line "$line" "$tmp"
  done < "$ROUTES_FILE"
  # Удаляем /32 устаревших DNS-записей, которых больше нет
  if [[ -f "$STATE_FILE" ]]; then
    comm -23 \
      <(awk '{print $1}' "$STATE_FILE" | sort -u) \
      <(awk '{print $1}' "$tmp" | sort -u) \
    | while IFS= read -r old; do
        if [[ "$old" == *:* ]]; then
          ip -6 route del "$old/128" dev "$TUN_NAME" 2>/dev/null || true
        else
          ip route del "$old/32" dev "$TUN_NAME" 2>/dev/null || true
        fi
      done
  fi
  mv "$tmp" "$STATE_FILE"
}

del_line() {
  local line=$1 kind
  kind=$(classify_line "$line")
  case "$kind" in
    cidr6) ip -6 route del "$line" dev "$TUN_NAME" 2>/dev/null || true ;;
    cidr)  ip route del "$line" dev "$TUN_NAME" 2>/dev/null || true ;;
    ip)    ip route del "$line/32" dev "$TUN_NAME" 2>/dev/null || true ;;
    domain) : ;; # /32 доменов удаляются в stop_routes по state-файлу
  esac
}

stop_routes() {
  local raw line
  if [[ -f "$ROUTES_FILE" ]]; then
    while IFS= read -r raw; do
      line="${raw%%#*}"
      trim line
      [[ -z "$line" ]] && continue
      del_line "$line"
    done < "$ROUTES_FILE"
  fi
  if [[ -f "$STATE_FILE" ]]; then
    awk '{print $1}' "$STATE_FILE" | sort -u | while IFS= read -r ip; do
      if [[ "$ip" == *:* ]]; then
        ip -6 route del "$ip/128" dev "$TUN_NAME" 2>/dev/null || true
      else
        ip route del "$ip/32" dev "$TUN_NAME" 2>/dev/null || true
      fi
    done
    rm -f "$STATE_FILE"
  fi
}

# ----------------------------------------------------------------------------
# Команды
# ----------------------------------------------------------------------------
cmd_start() {
  load_conf
  start_tun2socks || die "Туннель не поднят"
  ensure_tun || die "Интерфейс $TUN_NAME не готов"
  apply_routes
  log "Готово. Через $TUN_NAME: $(ip route show dev "$TUN_NAME" | wc -l) v4 и $(ip -6 route show dev "$TUN_NAME" 2>/dev/null | wc -l) v6 маршрутов"
}

cmd_stop() {
  load_conf
  stop_routes
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  log "Туннель остановлен, маршруты сняты"
}

cmd_restart() { cmd_stop; sleep 1; cmd_start; }

cmd_refresh() {
  load_conf
  # Самовосстановление, только если туннель уже установлен
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    docker inspect "$CONTAINER" >/dev/null 2>&1 || return 0
    start_tun2socks || return 1
  fi
  ip link show "$TUN_NAME" >/dev/null 2>&1 || return 0
  ensure_tun || return 0
  ensure_socks || return 1
  apply_routes
  log "Маршруты обновлены"
}

cmd_status() {
  load_conf
  echo "psiphon-route v$VERSION"
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "  контейнер: $CONTAINER ($(docker inspect -f '{{.State.Status}}' "$CONTAINER"))"
  else
    echo "  контейнер: $CONTAINER отсутствует"
  fi
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    echo "  интерфейс: $TUN_NAME ($(ip -4 -o addr show dev "$TUN_NAME" | awk '{print $4}'))"
  else
    echo "  интерфейс: $TUN_NAME отсутствует"
  fi
  if detect_socks; then
    echo "  SOCKS5:    $SOCKS_ADDR"
    echo "  выход Psiphon: $(curl -s -m 8 --socks5-hostname "$SOCKS_ADDR" https://ifconfig.me 2>/dev/null || echo 'н/д')"
  else
    echo "  SOCKS5:    не найден"
  fi
  echo "  маршруты:  $(ip route show dev "$TUN_NAME" 2>/dev/null | wc -l) (v4), $(ip -6 route show dev "$TUN_NAME" 2>/dev/null | wc -l) (v6)"
  echo "  api.telegram.org с хоста: HTTP $(curl -s -o /dev/null -m 8 -w '%{http_code}' https://api.telegram.org 2>/dev/null || echo 'нет ответа')"
}

telegram_cidr_block() {
  local fetched=""
  if command -v curl >/dev/null 2>&1; then
    fetched=$(curl -fsS -m 15 "$TG_CIDR_URL" 2>/dev/null \
      | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$' | sort -u || true)
  fi
  if [[ -z "$fetched" ]]; then
    warn "Не удалось скачать $TG_CIDR_URL — использую встроенный список"
    fetched=$(printf '%s\n' "${TG_CIDRS_FALLBACK[@]}" | sort -u)
  fi
  echo "# >>> telegram (psiphon-route update-cidrs) >>>"
  echo "$fetched"
  echo "# <<< telegram <<<"
}

seed_routes_file() {
  local block
  block=$(telegram_cidr_block)
  cat > "$ROUTES_FILE" <<EOF
# ============================================================================
# Маршруты, которые пойдут через Psiphon (psiphon-route)
#
# Формат — по одной строке:
#   CIDR     91.108.4.0/22   (или IPv6: 2001:67c:4e8::/48)
#   IP       149.154.167.220
#   домен    api.telegram.org   (резолвится автоматически, обновляется таймером)
#
# Комментарии — строки, начинающиеся с #. Wildcard (*.example.com) не
# поддерживается — добавляйте конкретные поддомены.
# После правок: psiphon-route refresh
# Примечание: t.me / web-вебхуки живут за Cloudflare — их IP добавлять не
# стоит, иначе через Psiphon пойдёт половина интернета.
# ============================================================================

$block

# --- Telegram API и веб-клиент ---
api.telegram.org
# web.telegram.org

# --- Примеры пользовательских маршрутов ---
# core.telegram.org
# 2001:67c:4e8::/48
# 203.0.113.10
EOF
}

write_conf_file() {
  cat > "$CONF_FILE" <<'EOF'
# Конфиг psiphon-route
# SOCKS5 Psiphon (пусто = авто-поиск vps-psiphon на docker0/127.0.0.1, порты 1080-1085)
PSIPHON_SOCKS=""
# MTU для tun2socks (пусто = умолчание tun2socks)
MTU=""
# Маршрутизировать IPv6-адреса из списка (0/1)
ENABLE_IPV6=0
# Регион выхода для install-psiphon, например "DE" или пул "NL,DE,SE"
PSIPHON_REGION=""
EOF
  chmod 600 "$CONF_FILE"
}

write_systemd_units() {
  cat > "$SYSTEMD_DIR/psiphon-route.service" <<EOF
[Unit]
Description=Psiphon TUN routing (Telegram и пользовательские маршруты)
Documentation=https://github.com/obkaiter/RemnaSuper
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN start
ExecStop=$BIN stop
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SYSTEMD_DIR/psiphon-route-refresh.service" <<EOF
[Unit]
Description=Обновление маршрутов psiphon-route (DNS и самовосстановление)
After=psiphon-route.service

[Service]
Type=oneshot
ExecStart=$BIN refresh
EOF

  cat > "$SYSTEMD_DIR/psiphon-route-refresh.timer" <<EOF
[Unit]
Description=Таймер обновления маршрутов psiphon-route

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=psiphon-route-refresh.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

cmd_install() {
  need_root
  log "psiphon-route install: проверяю окружение…"
  ensure_base_deps
  ensure_docker
  ensure_tun_module

  ensure_dirs
  [[ -f "$CONF_FILE" ]]   || write_conf_file
  [[ -f "$ROUTES_FILE" ]] || seed_routes_file

  # Копия себя в /usr/local/bin (работает и при запуске через bash <(curl …))
  if [[ "$0" != "$BIN" && "$(readlink -f "$0" 2>/dev/null)" != "$BIN" ]]; then
    cat "$0" > "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN"
    log "Скрипт скопирован в $BIN"
  fi

  write_systemd_units
  systemctl enable psiphon-route.service psiphon-route-refresh.timer >/dev/null 2>&1 || true

  if ! detect_socks; then
    echo
    warn "Psiphon (vps-psiphon) не найден."
    if ask "Установить vps-psiphon сейчас?"; then
      cmd_install_psiphon || true
    else
      echo "Установите позже: psiphon-route install-psiphon  (или через RemnaSuper)"
    fi
  fi

  if detect_socks; then
    log "Psiphon найден — запускаю туннель…"
    systemctl start psiphon-route
    cmd_status
    echo
    echo "Готово. Трафик настраивается в $ROUTES_FILE, после правок: psiphon-route refresh"
  else
    cat <<EOF

Psiphon не найден — как только установите (psiphon-route install-psiphon),
поднимите туннель:  systemctl start psiphon-route

Дальнейшие шаги:
  1) Проверьте список трафика:  $ROUTES_FILE
     (Telegram CIDR и api.telegram.org уже добавлены)
  2) Поднимите туннель:         systemctl start psiphon-route
  3) Проверьте:                 psiphon-route status
EOF
  fi
}

cmd_install_psiphon() {
  need_root
  command -v curl >/dev/null || die "curl не найден"
  load_conf
  local url="https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh"
  local -a args=(--no-http)
  [[ -n "${PSIPHON_REGION:-}" ]] && args+=(--region "$PSIPHON_REGION")
  log "Установка vps-psiphon (установщик Chara-Freedom/vps-psiphon)…"
  bash <(curl -fsSL "$url") "${args[@]}"
}

cmd_update_cidrs() {
  need_root
  load_conf
  local block
  block=$(telegram_cidr_block)
  if [[ -f "$ROUTES_FILE" ]] && grep -q '^# >>> telegram' "$ROUTES_FILE"; then
    awk -v block="$block" '
      /^# >>> telegram/ { print block; skip=1; next }
      /^# <<< telegram/ { skip=0; next }
      skip { next }
      { print }
    ' "$ROUTES_FILE" > "$ROUTES_FILE.tmp" && mv "$ROUTES_FILE.tmp" "$ROUTES_FILE"
  elif [[ -f "$ROUTES_FILE" ]]; then
    printf '\n%s\n' "$block" >> "$ROUTES_FILE"
  else
    ensure_dirs
    printf '%s\n' "$block" > "$ROUTES_FILE"
  fi
  log "Блок Telegram CIDR обновлён в $ROUTES_FILE"
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    apply_routes
    log "Маршруты применены"
  fi
}

cmd_logs() {
  docker logs --tail "${1:-100}" "$CONTAINER"
}

cmd_uninstall() {
  need_root
  systemctl disable --now psiphon-route.service psiphon-route-refresh.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/psiphon-route.service" \
        "$SYSTEMD_DIR/psiphon-route-refresh.service" \
        "$SYSTEMD_DIR/psiphon-route-refresh.timer"
  systemctl daemon-reload
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" "$STATE_DIR"
  rm -f "$BIN"
  log "psiphon-route удалён (vps-psiphon не тронут)"
}

usage() {
  cat <<EOF
psiphon-route v$VERSION — TUN-интерфейс поверх Psiphon (vps-psiphon) с
выборочной маршрутизацией (Telegram + пользовательский список).

Быстрый старт на чистом сервере:
  bash <(curl -fsSL https://raw.githubusercontent.com/NickelBlvck/tg-psiphon/main/psiphon-route.sh) install
  (сам поставит Docker, предложит установить vps-psiphon, запустит туннель)

Использование: psiphon-route <команда>

  install            Установка на чистую машину: зависимости, Docker,
                     конфиг, список маршрутов, systemd, запуск
  start              Поднять туннель и применить маршруты
  stop               Снять маршруты и остановить туннель
  restart            Перезапустить
  refresh            Обновить DNS-маршруты / самовосстановление
  status             Состояние туннеля, проверка api.telegram.org
  update-cidrs       Обновить Telegram CIDR из официального списка
  install-psiphon    Установить vps-psiphon (если ещё нет)
  logs [N]           Логи tun2socks (по умолчанию 100 строк)
  uninstall          Удалить psiphon-route

Список трафика задаётся в $ROUTES_FILE:
  - CIDR (91.108.4.0/22, 2001:67c:4e8::/48)
  - отдельный IP
  - домен (api.telegram.org) — резолвится и обновляется автоматически
EOF
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    install)         need_root; cmd_install ;;
    start)           need_root; cmd_start ;;
    stop)            need_root; cmd_stop ;;
    restart)         need_root; cmd_restart ;;
    refresh)         need_root; cmd_refresh ;;
    status)          cmd_status ;;
    update-cidrs)    cmd_update_cidrs ;;
    install-psiphon) cmd_install_psiphon ;;
    logs)            shift; cmd_logs "${1:-100}" ;;
    uninstall)       need_root; cmd_uninstall ;;
    help|-h|--help)  usage ;;
    *) usage; die "Неизвестная команда: $cmd" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
