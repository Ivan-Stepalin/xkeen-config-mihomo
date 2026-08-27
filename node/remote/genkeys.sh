#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ. Генерирует реквизиты Reality и печатает их одним
# блоком key=value.
#
# Свои ключи на каждый вход, а не общие: если один донор окажется засвечен и
# вход придётся выбросить, второй продолжает работать на своей паре ключей.
#
# Формат вывода x25519 менялся между версиями Xray — было "Private key/Public
# key", стало "PrivateKey/Password". Разбираем оба.
set -euo pipefail

emit_pair() {
  local prefix="$1" keys priv pub
  keys="$(xray x25519)"
  priv="$(echo "$keys" | grep -iE '^private'            | head -1 | sed 's/^[^:]*: *//')"
  pub="$( echo "$keys" | grep -iE '^(public|password)'  | head -1 | sed 's/^[^:]*: *//')"
  [ -n "$priv" ] && [ -n "$pub" ] || { echo "не разобрал x25519: $keys" >&2; exit 1; }
  echo "${prefix}_PRIVATE_KEY=$priv"
  echo "${prefix}_PUBLIC_KEY=$pub"
  echo "${prefix}_SHORT_ID=$(openssl rand -hex 8)"
}

echo "###KEYS###"
emit_pair XHTTP
emit_pair VISION
# Путь XHTTP — часть секрета: без него вход не отвечает даже с верным ключом.
echo "XHTTP_PATH=/$(openssl rand -hex 12)"
