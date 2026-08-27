#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ. Ищет донора для маскировки Reality и печатает
# таблицу кандидатов, отсортированную по времени рукопожатия.
#
# Почему сканируем именно соседей по подсети, а не берём известный крупный
# сайт: DPI видит связку «наш IP + чужое имя в SNI». Если имя принадлежит
# машине из той же подсети, связка выглядит согласованно, а рукопожатие идёт
# внутри датацентра — десятки микросекунд вместо десятков миллисекунд.
# Вдобавок популярные доноры (tesla, microsoft, cloudflare) засвечены: их
# перебирают тысячи чужих узлов, и фильтру дешевле выучить их, чем всю сеть.
#
# Требования Reality к донору: TLS 1.3, ALPN h2, обмен ключами x25519,
# не за CDN. Всё это здесь и проверяется.
set -uo pipefail
export LC_ALL=C

PREFIX_LEN="${1:-24}"   # 24 = свои 254 соседа; 22 даст вчетверо больше

command -v openssl >/dev/null || { echo "нет openssl"; exit 1; }

MYIP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -n "$MYIP" ] || { echo "не определил свой IP"; exit 1; }
BASE24="${MYIP%.*}"

echo ">> свой адрес: $MYIP, подсеть ${BASE24}.0/${PREFIX_LEN}"

# ---------------------------------------------------------------- соседи
# Обычным bash /dev/tcp, без nmap: 254 адреса в 64 потока укладываются
# в пару секунд, ставить лишние пакеты на узел не хочется.
scan_ips() {
  local third_from third_to o3
  if [ "$PREFIX_LEN" = 22 ]; then
    o3="$(echo "$MYIP" | cut -d. -f3)"
    third_from=$(( (o3 / 4) * 4 )); third_to=$(( third_from + 3 ))
  else
    o3="$(echo "$MYIP" | cut -d. -f3)"; third_from="$o3"; third_to="$o3"
  fi
  local a b c
  a="$(echo "$MYIP" | cut -d. -f1)"; b="$(echo "$MYIP" | cut -d. -f2)"
  for c in $(seq "$third_from" "$third_to"); do
    for d in $(seq 1 254); do echo "$a.$b.$c.$d"; done
  done
}

probe() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null && echo "$1"; }
export -f probe

echo ">> ищу открытый 443 у соседей"
ALIVE="$(scan_ips | grep -v "^${MYIP}$" | xargs -P 64 -I{} bash -c 'probe {}' | sort -u)"
N_ALIVE="$(echo "$ALIVE" | grep -c . || true)"
echo ">> отвечают на 443: $N_ALIVE"

# ------------------------------------------------- имена из сертификатов
# Снимаем сертификат, который сосед отдаёт по умолчанию (без SNI), и
# вытаскиваем из него CN и SAN. Wildcard-имена отбрасываем: Reality требует
# конкретное имя, а угадывать поддомен вслепую смысла нет.
names_of() {
  local ip="$1" pem
  pem="$(timeout 5 openssl s_client -connect "$ip:443" -tls1_3 </dev/null 2>/dev/null)"
  echo "$pem" | grep -q 'BEGIN CERTIFICATE' || return 0
  echo "$pem" \
    | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' \
    | sed -n 's/.*DNS://p; s/.*CN *= *//p' \
    | tr -d ' ' \
    | grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$' \
    | awk -v ip="$ip" '{print $1"\t"ip}'
}
export -f names_of

echo ">> снимаю сертификаты"
CANDS="$( [ -n "$ALIVE" ] && echo "$ALIVE" | xargs -P 32 -I{} bash -c 'names_of {}' | sort -u )"

# --------------------------------------------------------------- отсев
# Cloudflare отбрасываем по замеру 27.08.2026: диапазоны бесплатного плана
# (104.21.*, 172.67.*) душат так же, как свой домен. Google — потому что
# узел нужен именно для Google-сервисов, и заворачивать их же имя в SNI
# значит отдать фильтру самый заметный признак.
BAD_RE='(^|\.)(google|gstatic|googleapis|googleusercontent|youtube|ytimg|doubleclick)\.|cloudflare|(^|\.)cloudflaressl\.com$|letsencrypt\.org$|(^|\.)hetzner\.(com|de|cloud)$|localhost|\.(local|default|internal|lan|home|test)$|\.invalid$|example\.(com|org|net)$|^app-[0-9a-f]{8,}|(^|\.)(sandbox|sandbox-api|preview|staging|stage|dev|test|demo|tmp)\.'

is_cdn_ip() {
  case "$1" in
    104.1[6-9].*|104.2[0-7].*|172.6[4-9].*|172.7[01].*|188.114.*|162.159.*|198.41.*) return 0;;
    *) return 1;;
  esac
}

# ------------------------------------------------------------- проверка
# Каждое имя проверяем как донора всерьёз: три рукопожатия, берём лучшее.
#
# ALPN и группу обмена ключами приходится добывать двумя разными путями:
# openssl 3.x в режиме -brief не печатает ни строку "ALPN protocol", ни
# "Negotiated TLS1.3 group" — только "Server Temp Key". Поэтому x25519
# читаем оттуда, а h2 подтверждаем самим curl: он скажет, по какой версии
# HTTP реально договорился, а не какой список был предложен.
check() {
  local host="$1" src_ip="$2" out ip proto tempkey verify ms best=99999 i t0 t1 code httpver

  echo "$host" | grep -qEi "$BAD_RE" && return 0

  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '/STREAM/{print $1; exit}')"
  [ -n "$ip" ] || return 0
  is_cdn_ip "$ip" && return 0

  for i in 1 2 3; do
    t0="$(date +%s%N)"
    out="$(timeout 6 openssl s_client -connect "$host:443" -servername "$host" \
             -alpn h2 -tls1_3 -groups x25519 -brief </dev/null 2>&1)"
    t1="$(date +%s%N)"
    echo "$out" | grep -q 'Protocol version: TLSv1.3' || return 0
    ms=$(( (t1 - t0) / 1000000 ))
    [ "$ms" -lt "$best" ] && best="$ms"
  done

  proto="$(echo "$out"   | sed -n 's/^Protocol version: *//p'  | head -1)"
  tempkey="$(echo "$out" | sed -n 's/^Server Temp Key: *//p'   | head -1)"
  verify="$(echo "$out"  | sed -n 's/^Verification: *//p'      | head -1)"

  # x25519 обязателен: REALITY подменяет ServerHello донора и умеет только
  # эту группу. Валидный публичный сертификат тоже обязателен — самоподписной
  # выдаст узел при первой же активной проверке со стороны фильтра.
  echo "$tempkey" | grep -qi 'X25519' || return 0
  [ "$verify" = "OK" ] || return 0

  # Живой сайт по HTTP/2, а не заглушка и не голый TLS.
  read -r code httpver <<<"$(timeout 8 curl -sS -o /dev/null -w '%{http_code} %{http_version}' --http2 \
            -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0' \
            "https://$host/" 2>/dev/null || echo '000 0')"
  [ "$code" = "000" ] && return 0
  [ "$httpver" = "2" ] || return 0

  # Ранжирование. Сосед по подсети важнее всего: у такого имени адрес лежит
  # рядом с нашим, и связка «IP + SNI» согласована. Дальше — отдаёт ли имя
  # настоящую страницу: 200 значит живой сайт, 301/302 — редирект (годится),
  # 403/404 — имя есть в сертификате, но сайта за ним нет, донор так себе.
  # Скорость идёт последней: внутри одного датацентра разброс миллисекунд
  # это накладные расходы на запуск openssl, а не свойство донора.
  local near=1
  [ "${ip%.*}" = "${src_ip%.*}" ] && near=0
  local rank
  case "$code" in
    200)     rank=0 ;;
    301|302) rank=1 ;;
    *)       rank=2 ;;
  esac

  printf '%d\t%d\t%05d\t%s\t%s\t%s\t%s\t%s\n' \
    "$near" "$rank" "$best" "$host" "$ip" "$proto" "${tempkey%%,*}" "$code"
}
export -f check is_cdn_ip
export BAD_RE

echo ">> проверяю кандидатов (TLS 1.3 + h2 + x25519 + живой ответ)"
RESULT="$( [ -n "$CANDS" ] && echo "$CANDS" | xargs -P 16 -n2 bash -c 'check "$0" "$1"' | sort -k1,1n -k2,2n -k3,3n )"

echo
printf '%-3s %-6s %-38s %-16s %-9s %-8s %s\n' "бл" "мс" "имя" "адрес" "протокол" "группа" "код"
printf '%.0s-' {1..96}; echo
if [ -n "$RESULT" ]; then
  echo "$RESULT" | while IFS=$'\t' read -r near rank ms host ip proto group code; do
    printf '%-3s %-6s %-38s %-16s %-9s %-8s %s\n' \
      "$([ "$near" = 0 ] && echo да || echo нет)" "$((10#$ms))" "$host" "$ip" "$proto" "$group" "$code"
  done
else
  echo "(ни один кандидат не прошёл проверку)"
fi
echo

BEST="$(echo "$RESULT" | head -1 | cut -f4)"
echo "###BEST###"
echo "${BEST:-}"
