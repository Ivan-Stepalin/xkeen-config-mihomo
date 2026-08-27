#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ. Отвечает на вопрос «годится ли IP этого узла под
# Google и AI-сервисы». Последней строкой печатает VERDICT=PASS|FAIL.
#
# Нужно это потому, что Google определяет страну не по тому, где физически
# стоит сервер, а по своей гео-базе, и она регулярно расходится с ipinfo:
# из 54 узлов коммерческих подписок Google считал российскими 43 (замер
# 26.08.2026), и Gemini на них падал на заглушку про страну.
set -uo pipefail

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0'
C="curl -4 -s -m 15 -A"
FAIL=0

INFO="$($C "$UA" https://ipinfo.io/json || true)"
echo "ip.country   = $(echo "$INFO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)"
echo "ip.org       = $(echo "$INFO" | grep -o '"org": *"[^"]*"'     | cut -d'"' -f4)"

# Страну спрашиваем у самого Google, а не выводим из косвенных признаков.
# В HTML YouTube есть "GL":"XX" — это ровно та гео-база, по которой Gemini
# выносит вердикт о стране. Косвенные маркеры (наличие BardChatUi в разметке
# Gemini) не годятся: они есть и на странице-заглушке.
YT_HTML="$($C "$UA" -L https://www.youtube.com/ || true)"
GL="$(echo "$YT_HTML" | grep -o '"GL":"[A-Z]\{2\}"' | head -1 | cut -d'"' -f4)"
case "$GL" in
  "")  echo "google.страна = не определилась (разметка изменилась?)"; FAIL=1 ;;
  RU)  echo "google.страна = RU — узел не годится, Gemini даст заглушку"; FAIL=1 ;;
  *)   echo "google.страна = $GL" ;;
esac

# Контрольный прогон: убеждаемся, что детектор вообще различает варианты.
# Без него «страна не RU» может означать просто сломанный тест.
GL_CTRL="$($C "$UA" -L 'https://www.youtube.com/?persist_gl=1&gl=NL' \
           | grep -o '"GL":"[A-Z]\{2\}"' | head -1 | cut -d'"' -f4)"
[ -n "$GL_CTRL" ] && echo "google.контроль = $GL_CTRL (детектор различает варианты)" \
                  || echo "google.контроль = пусто — к вердикту выше доверия нет"

if $C "$UA" -o /dev/null -w '%{redirect_url}' 'https://www.google.com/search?q=test' \
   | grep -q '/sorry/'; then
  echo "google       = ЗАБЛОКИРОВАН (петля /sorry/, GOOGLE_ABUSE)"; FAIL=1
else
  echo "google       = ok"
fi

GEM="$($C "$UA" -o /dev/null -w '%{http_code}' https://gemini.google.com/app || true)"
case "$GEM" in
  200|302|303) echo "gemini       = ok ($GEM)" ;;
  *)           echo "gemini       = подозрительно ($GEM)"; FAIL=1 ;;
esac

# chatgpt.com сидит за Cloudflare и отдаёт 403 любому curl без браузерных
# заголовков — по нему о гео судить нельзя. Отказ по стране виден на
# api.openai.com: 401 без ключа = пускают, 403 с unsupported_country = блок.
BODY="$(mktemp)"
OAI="$($C "$UA" -o "$BODY" -w '%{http_code}' https://api.openai.com/v1/models || true)"
LOC="$($C "$UA" https://chatgpt.com/cdn-cgi/trace | grep '^loc=' || true)"
case "$OAI" in
  401) echo "openai       = ok (401 без ключа — гео пропускает, ${LOC:-loc=?})" ;;
  403) if grep -qi 'unsupported_country\|country' "$BODY"; then
         echo "openai       = блок по стране (403, ${LOC:-loc=?})"; FAIL=1
       else
         echo "openai       = 403 без гео-причины, вероятно бот-фильтр (${LOC:-loc=?})"
       fi ;;
  *)   echo "openai       = неясно ($OAI, ${LOC:-loc=?})" ;;
esac
rm -f "$BODY"

[ "$FAIL" = 0 ] && echo "VERDICT=PASS" || echo "VERDICT=FAIL"
