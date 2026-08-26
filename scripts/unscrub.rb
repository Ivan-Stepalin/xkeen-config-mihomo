#!/usr/bin/env ruby
# frozen_string_literal: true
#
# smudge-фильтр git: плейсхолдеры -> реальные ссылки из .secrets.yaml.
# Запускается на checkout. Без .secrets.yaml файл остаётся с
# плейсхолдерами — это осознанное поведение, а не ошибка: на чужой машине
# конфиг просто не содержит чужих секретов.

require 'yaml'

ROOT    = File.expand_path('..', __dir__)
SECRETS = File.join(ROOT, '.secrets.yaml')

text = $stdin.binmode.read
if File.exist?(SECRETS)
  (YAML.load_file(SECRETS) || {}).each do |name, value|
    text = text.gsub("${#{name}}", value.to_s)
  end
end
$stdout.binmode.write(text)
