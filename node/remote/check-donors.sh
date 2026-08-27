#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ. Проверяет каждое переданное аргументом имя как
# донора для Reality. Печатает по строке на кандидата: PASS или SKIP с причиной.
#
# Имена идут аргументами, а не через stdin: stdin занят самим скриптом —
# он приезжает на сервер как "bash -s".
#
# Проверяется только пригодность самого имени: доступно ли оно с узла, отдаёт
# ли TLS 1.3 с h2 и x25519, валиден ли сертификат. Пройдёт ли это имя
# российский фильтр — отсюда не видно и видно быть не может: душат путь
# «дом → узел», а не «узел → донор». Это решает замер из дома.
set -uo pipefail
export LC_ALL=C

is_cdn_ip() {
  case "$1" in
    104.1[6-9].*|104.2[0-7].*|172.6[4-9].*|172.7[01].*|188.114.*|162.159.*|198.41.*) return 0;;
    *) return 1;;
  esac
}

check() {
  local host="$1" out ip tempkey verify ms best=99999 i t0 t1 code httpver

  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '/STREAM/{print $1; exit}')"
  [ -n "$ip" ] || { echo "SKIP $host не резолвится"; return 0; }
  is_cdn_ip "$ip" && { echo "SKIP $host за Cloudflare ($ip)"; return 0; }

  for i in 1 2 3; do
    t0="$(date +%s%N)"
    out="$(timeout 8 openssl s_client -connect "$host:443" -servername "$host" \
             -alpn h2 -tls1_3 -groups x25519 -brief </dev/null 2>&1)"
    t1="$(date +%s%N)"
    echo "$out" | grep -q 'Protocol version: TLSv1.3' || { echo "SKIP $host нет TLS 1.3 с x25519"; return 0; }
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -lt "$best" ] && best="$ms"
  done

  tempkey="$(echo "$out" | sed -n 's/^Server Temp Key: *//p' | head -1)"
  verify="$( echo "$out" | sed -n 's/^Verification: *//p'    | head -1)"
  echo "$tempkey" | grep -qi 'X25519' || { echo "SKIP $host группа не x25519: $tempkey"; return 0; }
  [ "$verify" = "OK" ] || { echo "SKIP $host сертификат не проходит проверку: $verify"; return 0; }

  read -r code httpver <<<"$(timeout 10 curl -sS -o /dev/null -w '%{http_code} %{http_version}' --http2 \
    -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0' \
    "https://$host/" 2>/dev/null || echo '000 0')"
  [ "$code" = "000" ] && { echo "SKIP $host не отвечает по HTTP"; return 0; }
  [ "$httpver" = "2" ] && echo "PASS $host $ip ${tempkey%%,*} $code ${best}ms" \
                       || echo "SKIP $host не отдаёт HTTP/2 (версия $httpver)"
}
export -f check is_cdn_ip

printf '%s\n' "$@" | xargs -P 8 -I{} bash -c 'check {}'
