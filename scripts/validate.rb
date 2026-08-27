#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Проверка config.yaml на ошибки, которые mihomo молча проглатывает:
# висячие ссылки, мёртвые провайдеры, перекрытие правил по порядку.
#
#   ruby scripts/validate.rb          проверить локальный config.yaml
#   ruby scripts/validate.rb --live   дополнительно сверить с роутером
#
# Код возврата: 0 — чисто (возможны предупреждения), 1 — есть ошибки.

require 'yaml'
require 'set'

ROOT     = File.expand_path('..', __dir__)
CONFIG   = File.join(ROOT, 'config.yaml')
RULES_DIR = File.join(ROOT, 'rules')
ROUTER   = ENV.fetch('MIHOMO_API', 'http://192.168.1.1:9090')

# Встроенные цели mihomo — это не группы, объявлять их не нужно.
BUILTIN_TARGETS = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE].to_set
# Модификаторы, которые могут стоять последним полем правила.
RULE_FLAGS = %w[no-resolve src].to_set
# Типы правил, у которых первый аргумент — имя rule-provider'а.
SET_TYPES = %w[RULE-SET].to_set

ERRORS = []
WARNS  = []

def err(msg)
  ERRORS << msg
end

def warn!(msg)
  WARNS << msg
end

# ── Разбор правил ─────────────────────────────────────────────────────
# Запятые внутри скобок не разделяют поля:
#   AND,((DST-PORT,443),(NETWORK,UDP)),QUIC  ->  [AND, ((…),(…)), QUIC]
def split_top(str)
  parts = []
  depth = 0
  cur = +''
  str.each_char do |ch|
    if ch == '('
      depth += 1
      cur << ch
    elsif ch == ')'
      depth -= 1
      cur << ch
    elsif ch == ',' && depth.zero?
      parts << cur
      cur = +''
    else
      cur << ch
    end
  end
  parts << cur
  parts
end

# Цель правила — последнее поле, не считая модификаторов вроде no-resolve.
def rule_target(rule)
  body = rule.split('#').first.strip
  parts = split_top(body).map(&:strip)
  parts.pop while parts.size > 1 && RULE_FLAGS.include?(parts.last)
  parts.last
end

# ── Загрузка ──────────────────────────────────────────────────────────
begin
  cfg = YAML.load_file(CONFIG)
rescue StandardError => e
  puts "config.yaml не разбирается: #{e.message}"
  exit 1
end
cfg.delete('x-templates') # служебный блок якорей, mihomo его не читает

groups    = cfg['proxy-groups'] || []
manual    = cfg['proxies'] || []
providers = cfg['rule-providers'] || {}
rules     = cfg['rules'] || []

group_names = groups.map { |g| g['name'] }.to_set
# Ручные узлы из секции proxies: — на них группы ссылаются по имени так же,
# как на другие группы. Узлы из подписок сюда не попадают: их имена приходят
# от провайдера в рантайме, проверить их статически нельзя.
manual_names = manual.map { |p| p['name'] }.to_set

# RULE-SET встречается и в rules, и внутри payload у inline-провайдеров.
inline_payloads = providers.values.flat_map { |p| p['payload'] || [] }
referenced_sets = (rules + inline_payloads)
                  .flat_map { |r| r.to_s.scan(/RULE-SET,([^,()]+)/).flatten }
                  .map(&:strip).to_set

# ── 1. Висячие ссылки ─────────────────────────────────────────────────
referenced_sets.each do |name|
  err "RULE-SET,#{name} — такого rule-provider'а нет" unless providers.key?(name)
end

rules.each_with_index do |rule, i|
  target = rule_target(rule)
  next if group_names.include?(target) || BUILTIN_TARGETS.include?(target)

  err "правило ##{i + 1} ведёт в несуществующую группу #{target.inspect}: #{rule}"
end

groups.each do |g|
  (g['proxies'] || []).each do |p|
    next if group_names.include?(p) || manual_names.include?(p) || BUILTIN_TARGETS.include?(p)

    err "группа #{g['name'].inspect} ссылается на несуществующий прокси #{p.inspect}"
  end
end

# ── 2. Мёртвый вес ────────────────────────────────────────────────────
providers.each_key do |name|
  next if referenced_sets.include?(name)

  warn! "rule-provider #{name.inspect} не используется ни в одном правиле " \
        '(качается впустую)'
end

rule_targets = rules.map { |r| rule_target(r) }.to_set
group_names.each do |name|
  next if rule_targets.include?(name)
  # Группа может быть не целью правила, а запасным вариантом внутри другой.
  next if groups.any? { |g| (g['proxies'] || []).include?(name) }

  warn! "группа #{name.inspect} недостижима: на неё не ведёт ни одно правило"
end

# ── 3. Коллизии путей ─────────────────────────────────────────────────
providers.each_with_object(Hash.new { |h, k| h[k] = [] }) { |(n, p), h|
  h[p['path']] << n if p['path']
}.each do |path, names|
  err "провайдеры #{names.join(', ')} пишут в один файл #{path}" if names.size > 1
end

# ── 4. Структура правил ───────────────────────────────────────────────
match_at = rules.each_index.select { |i| rules[i].to_s.start_with?('MATCH,') }
if match_at.empty?
  err 'нет завершающего правила MATCH — трафик без совпадений повиснет'
elsif match_at.size > 1
  err "MATCH встречается #{match_at.size} раз (позиции #{match_at.map { |i| i + 1 }.join(', ')})"
elsif match_at.first != rules.size - 1
  err "MATCH стоит на позиции #{match_at.first + 1} из #{rules.size} — " \
      'всё, что ниже, недостижимо'
end

# ── 5. Рассинхрон источников ──────────────────────────────────────────
# Провайдер тянет .mrs, а рядом в rules/ лежит .yaml с тем же именем —
# правки в yaml не влияют ни на что (случай community).
providers.each do |name, p|
  url = p['url'].to_s
  next unless url.include?('/xkeen-config-mihomo/')

  file = File.basename(url)
  local = File.join(RULES_DIR, file)
  unless File.exist?(local)
    err "провайдер #{name.inspect} тянет rules/#{file}, но такого файла в репозитории нет"
    next
  end
  next unless File.extname(file) == '.mrs'

  twin = file.sub(/\.mrs\z/, '.yaml')
  next unless File.exist?(File.join(RULES_DIR, twin))

  warn! "провайдер #{name.inspect} использует rules/#{file}, но рядом лежит " \
        "rules/#{twin} — правки в yaml не применяются, пока источник не пересобран"
end

# ── 6. Перекрытие правил по порядку ───────────────────────────────────
# Читаем только локальные yaml-списки: содержимое .mrs недоступно.
def domains_of(path)
  doc = YAML.load_file(path)
  unless doc.is_a?(Hash) && doc['payload'].is_a?(Array)
    err "rules/#{File.basename(path)}: нет списка payload — файл не будет работать как rule-provider"
    return Set.new
  end
  doc['payload'].map do |entry|
    d = entry.to_s.split(',')[-1].to_s.strip     # DOMAIN-SUFFIX,foo.com -> foo.com
    next nil if d.empty?

    d.sub(/\A[+*]\./, '').downcase               # +.foo.com -> foo.com
  end.compact.to_set
rescue Psych::SyntaxError => e
  err "rules/#{File.basename(path)}: битый YAML — #{e.message.split("\n").first}"
  Set.new
end

local_sets = {}
providers.each do |name, p|
  url = p['url'].to_s
  next unless url.include?('/xkeen-config-mihomo/') && url.end_with?('.yaml')

  file = File.join(RULES_DIR, File.basename(url))
  local_sets[name] = domains_of(file) if File.exist?(file)
end

order = {}
rules.each_with_index do |rule, i|
  rule.to_s.scan(/RULE-SET,([^,()]+)/).flatten.each { |n| order[n.strip] ||= i }
end

local_sets.keys.combination(2) do |a, b|
  next unless order[a] && order[b]

  first, second = order[a] < order[b] ? [a, b] : [b, a]
  overlap = local_sets[first] & local_sets[second]
  next if overlap.empty?

  sample = overlap.to_a.sort.first(3).join(', ')
  more = overlap.size > 3 ? " и ещё #{overlap.size - 3}" : ''
  warn! "#{second.inspect} перекрыт правилом #{first.inspect}, стоящим выше: " \
        "общие домены — #{sample}#{more}"
end

# ── 7. Сверка с роутером ──────────────────────────────────────────────
if ARGV.include?('--live')
  require 'net/http'
  require 'json'
  begin
    uri = URI("#{ROUTER}/configs")
    live = JSON.parse(Net::HTTP.get_response(uri).body)
    puts "роутер #{ROUTER}: mihomo отвечает, режим #{live['mode'].inspect}"

    uri = URI("#{ROUTER}/providers/rules")
    live_p = JSON.parse(Net::HTTP.get_response(uri).body)['providers'] || {}
    (providers.keys.to_set ^ live_p.keys.to_set).each do |n|
      where = providers.key?(n) ? 'только в config.yaml' : 'только на роутере'
      warn! "rule-provider #{n.inspect}: #{where} — конфиг не задеплоен"
    end
  rescue StandardError => e
    warn! "роутер #{ROUTER} недоступен: #{e.class} — сверка пропущена"
  end
end

# ── Итог ──────────────────────────────────────────────────────────────
puts "групп: #{groups.size}   rule-provider'ов: #{providers.size}   правил: #{rules.size}"
puts
WARNS.each  { |m| puts "  ПРЕДУПРЕЖДЕНИЕ  #{m}" }
puts unless WARNS.empty?
ERRORS.each { |m| puts "  ОШИБКА  #{m}" }

if ERRORS.empty?
  puts WARNS.empty? ? 'Проверка пройдена, замечаний нет.' : "Ошибок нет, предупреждений: #{WARNS.size}."
  exit 0
else
  puts
  puts "Ошибок: #{ERRORS.size}. Деплоить нельзя."
  exit 1
end
