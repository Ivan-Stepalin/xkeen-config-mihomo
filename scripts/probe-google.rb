#!/usr/bin/env ruby
# frozen_string_literal: true

# probe-google.rb — какие узлы подписки Google считает нероссийскими.
#
# Зачем. Google относит IP к странам по своей базе, а не по тому, где стоит
# сервер: узел с флагом 🇳🇱 в названии может быть для Google российским, и
# тогда Gemini отдаёт заглушку «не поддерживается в вашей стране». Проверить
# это можно только запросом: скрипт спрашивает страну у самого Google.
#
# Как. Пробный запрос идёт на www.youtube.com — в его HTML есть "GL":"XX",
# та же гео-база, что у Gemini (сверено: Poland n3 → PL, dt 1 → RU, ровно как
# hl= на www.google.com). YouTube выбран потому, что правило GEOSITE,youtube
# ведёт в группу YouTube — её и переключает скрипт, не трогая группу AI, через
# которую идут Claude, ChatGPT и Gemini. Значит проба ничего не ломает на
# время своей работы.
#
# Выбранный в группе узел скрипт запоминает и возвращает на выходе, в том
# числе по Ctrl-C.
#
#   ruby scripts/probe-google.rb                      # все живые узлы
#   ruby scripts/probe-google.rb -f 'Poland|Germany'   # только совпавшие
#   ruby scripts/probe-google.rb -g Twitch             # другая группа-пробник
#   MIHOMO_API=http://192.168.1.2:9090 ruby scripts/probe-google.rb
#
# В конце печатается готовая строка filter: для группы Google-выход.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'

API   = ENV.fetch('MIHOMO_API', 'http://192.168.1.1:9090')
GROUP = 'YouTube'

options = { group: GROUP, filter: nil, timeout: 8 }
OptionParser.new do |o|
  o.banner = 'Использование: ruby scripts/probe-google.rb [опции]'
  o.on('-g', '--group NAME', 'группа-пробник (по умолчанию YouTube)') { |v| options[:group] = v }
  o.on('-f', '--filter REGEX', 'проверять только узлы, чьё имя совпало') { |v| options[:filter] = Regexp.new(v, Regexp::IGNORECASE) }
  o.on('-t', '--timeout SEC', Integer, 'таймаут одной пробы (по умолчанию 8)') { |v| options[:timeout] = v }
  o.on('-h', '--help') { puts o; exit }
end.parse!

# В путь имя узла нужно percent-кодировать: encode_www_form_component ставит
# на месте пробела «+», а в пути это буквальный плюс, и узел не находится.
def esc_path(str)
  URI::DEFAULT_PARSER.escape(str, /[^A-Za-z0-9\-_.~]/)
end

class ApiError < StandardError; end

def api_get(path)
  uri = URI("#{API}#{path}")
  res = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |h| h.request(Net::HTTP::Get.new(uri)) }
  JSON.parse(res.body)
rescue StandardError => e
  raise ApiError, "#{API}: #{e.message}"
end

def select_node(group, name, tries: 1)
  uri = URI("#{API}/proxies/#{esc_path(group)}")
  req = Net::HTTP::Put.new(uri, 'Content-Type' => 'application/json')
  req.body = JSON.dump(name: name)
  attempt = 0
  begin
    attempt += 1
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    true
  rescue StandardError => e
    retry if attempt < tries
    raise ApiError, "#{API}: #{e.message}"
  end
end

# Задержка через сам mihomo: он делает запрос узлом, не трогая выбор в группе.
def delay(node, timeout)
  path = "/proxies/#{esc_path(node)}/delay" \
         "?timeout=#{timeout * 1000}&url=#{URI.encode_www_form_component('http://www.msftncsi.com/ncsi.txt')}"
  api_get(path)['delay']
rescue ApiError
  nil
end

# Страна по версии Google. grep -m1 по потоку: как только "GL":"XX" найден,
# соединение закрывается, качать весь мегабайт HTML не нужно.
def google_country(timeout)
  out = `curl -s -m #{timeout} --compressed https://www.youtube.com/ 2>/dev/null | grep -m1 -o '"GL":"[A-Z][A-Z]"'`
  out[/"GL":"([A-Z]{2})"/, 1]
end

begin
  proxies = api_get('/proxies')['proxies']
rescue ApiError => e
  abort "mihomo не отвечает (#{e.message}). Роутер в сети? Порт 9090 открыт?"
end
group   = proxies[options[:group]] or abort "Группы «#{options[:group]}» нет. Есть: #{proxies.select { |_, v| v['all'] }.keys.join(', ')}"
original = group['now']
GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance Relay Direct Reject Compatible Pass].freeze

nodes = group['all'].reject { |n| GROUP_TYPES.include?(proxies.dig(n, 'type')) }
nodes.select! { |n| n =~ options[:filter] } if options[:filter]
abort 'Под фильтр не попал ни один узел.' if nodes.empty?

puts "mihomo: #{API}   группа-пробник: #{options[:group]}   узлов: #{nodes.size}"
puts "Выбранный сейчас узел (вернётся на место): #{original}"
puts
printf("%-46s %8s  %s\n", 'УЗЕЛ', 'мс', 'СТРАНА ПО ВЕРСИИ GOOGLE')

clean = []
begin
  nodes.each do |node|
    short = node.sub(/ (?:\p{So}|\p{Sk})*\s*(?:G\d|us_\d+).*\z/, '').strip
    ms = delay(node, options[:timeout])
    if ms.nil?
      printf("%-46s %8s  %s\n", short, '—', 'мёртв, пропущен')
      next
    end
    begin
      select_node(options[:group], node, tries: 3)
    rescue ApiError => e
      printf("%-46s %8s  %s\n", short, '—', "mihomo не ответил: #{e.message}")
      next
    end
    gl = google_country(options[:timeout])
    verdict = case gl
              when nil then 'нет ответа'
              when 'RU' then 'RU — Gemini не поедет'
              else "#{gl} — годен"
              end
    clean << [short, ms, gl] if gl && gl != 'RU'
    printf("%-46s %8d  %s\n", short, ms, verdict)
  end
ensure
  begin
    select_node(options[:group], original, tries: 5)
    puts "\nУзел в группе #{options[:group]} возвращён: #{original}"
  rescue ApiError => e
    warn "\nНЕ УДАЛОСЬ вернуть узел в группе #{options[:group]} (#{e.message})."
    warn "В группе остался узел последней пробы. Вернуть вручную, когда роутер будет доступен:"
    warn %(  curl -X PUT #{API}/proxies/#{esc_path(options[:group])} -d '#{JSON.dump(name: original)}')
  end
end

puts
if clean.empty?
  puts 'Нероссийских узлов не нашлось. Gemini на этой подписке не заработает —'
  puts 'нужен провайдер, чьи диапазоны Google видит европейскими.'
  exit 1
end

puts "Годных узлов: #{clean.size} из #{nodes.size}. Отсортированы по задержке:"
clean.sort_by! { |(_, ms, _)| ms }
clean.each { |(short, ms, gl)| printf("  %-44s %5d мс  %s\n", short, ms, gl) }

# Регексп для filter: у группы Google-выход. Из имени узла берётся часть до
# эмодзи и служебного хвоста — она у провайдера стабильнее остального.
# Экранируются только настоящие метасимволы. Regexp.escape трогает ещё пробел
# и «#» — в двойных кавычках YAML «\#» невалидная escape-последовательность,
# и такой filter уронил бы разбор конфига.
META = /[.*+?^$()\[\]{}|\\\/]/.freeze

alts = clean.map do |(short, _, _)|
  bare = short.sub(/\A\[[AB]\]\s*/, '').gsub(/\p{So}|\p{Sk}/, '').strip
  bare.gsub(META) { |ch| "\\#{ch}" }
end
puts
puts 'Готовая строка для группы Google-выход в config.yaml:'
puts %(    filter: "(?i)(#{alts.join('|')})")
