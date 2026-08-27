#!/usr/bin/env ruby
# frozen_string_literal: true
#
# clean-фильтр git: реальные ссылки подписок -> плейсхолдеры.
# Запускается на `git add`, поэтому в индекс и в коммит уходит уже
# обезличенная версия, а рабочий файл на диске остаётся нетронутым.
#
# Обратная операция: scripts/unscrub.rb
# Подключение описано в README, раздел «Секреты».

require 'yaml'

ROOT    = File.expand_path('..', __dir__)
SECRETS = File.join(ROOT, '.secrets.yaml')

text = $stdin.binmode.read

secrets = File.exist?(SECRETS) ? (YAML.load_file(SECRETS) || {}) : {}
# Длинные значения подставляются первыми: адрес узла входит внутрь URL
# подписки, и при обратном порядке от ссылки осталась бы только середина —
# с токеном в открытом виде.
secrets.sort_by { |_, value| -value.to_s.length }
       .each { |name, value| text = text.gsub(value.to_s, "${#{name}}") }

# Страховка: если в индекс уходит живой секрет, которого нет в .secrets.yaml,
# — падаем. git прервёт коммит, и секрет не уедет молча.
#
# Сторожим два места. Ссылки подписок в proxy-providers — по ним отдаётся весь
# список узлов с ключами. И реквизиты своего узла в proxies: с 27.08.2026 он
# прописан прямо в конфиге, а не подпиской, так что адрес, UUID и параметры
# Reality лежат теперь здесь.
GUARDS = {
  'proxy-providers:' => %w[url],
  'proxies:'         => %w[server uuid password public-key short-id path]
}.freeze

section = nil
leaked  = []
text.each_line.with_index(1) do |line, no|
  if line.match?(/\A\S/)
    key = line[/\A\S+:/]
    section = GUARDS.key?(key) ? key : nil
  end
  next unless section
  next unless (m = line.match(/^\s*(#{GUARDS[section].join('|')}):\s*(\S+)/))
  # Порт и флаги не секрет; ловим только то, что похоже на реквизит.
  leaked << [no, m[1], m[2]] unless m[2].start_with?('${')
end

unless leaked.empty?
  warn 'scrub.rb: в индекс уходит незакрытый секрет — коммит остановлен.'
  leaked.each { |no, key, val| warn "  строка #{no}: #{key}: #{val[0, 60]}" }
  warn 'Добавьте значение в .secrets.yaml и подставьте ${ИМЯ} в config.yaml.'
  exit 1
end

$stdout.binmode.write(text)
