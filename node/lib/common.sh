#!/usr/bin/env bash
# Общее для всех скриптов проекта: вывод, доступ к Hetzner, ssh на узел.
# Подключается как: source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# node.conf — присваивания без export, поэтому подтягиваем через set -a.
set -a; source ./node.conf; set +a
SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
bad() { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null || die "нет $c — поставь: brew install $c"
  done
}

need_token() {
  hcloud location list >/dev/null 2>&1 \
    || die "нет активного токена Hetzner. В отдельной вкладке: hcloud context create vpn"
}

node_ip() {
  hcloud server ip "$SERVER_NAME" 2>/dev/null || die "сервер $SERVER_NAME не найден в проекте Hetzner"
}

# known_hosts не ведём: пересоздание сервера меняет ключ хоста, и ssh начнёт
# отказываться соединяться на второй итерации.
rssh() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=10 \
      "root@$ip" "$@"
}

rscp() {
  local src="$1" ip="$2" dst="$3"
  scp -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=10 \
      "$src" "root@$ip:$dst" >/dev/null
}

# Правит присваивание в node.conf на месте, чтобы найденное сканером не
# приходилось вписывать руками.
set_conf() {
  local key="$1" val="$2"
  grep -q "^${key}=" node.conf || die "в node.conf нет ключа ${key}"
  local tmp; tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '$0 ~ "^"k"=" {print k"="v; next} {print}' node.conf > "$tmp"
  mv "$tmp" node.conf
  ok "node.conf: ${key}=${val}"
}
