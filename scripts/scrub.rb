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
secrets.each { |name, value| text = text.gsub(value.to_s, "${#{name}}") }

# Страховка: если в proxy-providers осталась живая ссылка, которой нет в
# .secrets.yaml, — падаем. git прервёт коммит, и секрет не уедет молча.
in_providers = false
leaked = []
text.each_line.with_index(1) do |line, no|
  in_providers = line.start_with?('proxy-providers:') if line.match?(/\A\S/)
  next unless in_providers
  next unless (m = line.match(/^\s*url:\s*(\S+)/))
  leaked << [no, m[1]] unless m[1].start_with?('${')
end

unless leaked.empty?
  warn "scrub.rb: в proxy-providers осталась незакрытая ссылка — коммит остановлен."
  leaked.each { |no, url| warn "  строка #{no}: #{url[0, 60]}" }
  warn "Добавьте её в .secrets.yaml (SUB_C: <ссылка>) и повторите."
  exit 1
end

$stdout.binmode.write(text)
