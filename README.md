# xkeen-configuration

xkeen -ap 80,443,8443,596:599,1400,2000-2300,3478,5222,19200-19400,46420,50000-51000

## Секреты

Ссылки на подписки не хранятся в репозитории. В `config.yaml` на диске они
настоящие — файл в таком виде и заливается на роутер, — а в коммит уходит
версия с плейсхолдерами `${SUB_A}` / `${SUB_B}`. Подмена в обе стороны
делается фильтром git, править файл нужно как обычно.

Реальные значения лежат в `.secrets.yaml` (в `.gitignore`). **Держите его
копию вне репозитория**: без него после свежего клона в `config.yaml`
останутся плейсхолдеры.

### Подключение на новой машине

Фильтры не переносятся клонированием — это локальная настройка git:

    git config filter.scrub-subs.clean  "ruby scripts/scrub.rb"
    git config filter.scrub-subs.smudge "ruby scripts/unscrub.rb"
    git config filter.scrub-subs.required true

Затем положить рядом `.secrets.yaml`:

    SUB_A: https://…
    SUB_B: https://…

и обновить рабочую копию: `rm config.yaml && git checkout config.yaml`.

### Как это устроено

| Файл | Роль |
|---|---|
| `scripts/scrub.rb` | clean-фильтр: ссылки → плейсхолдеры, на `git add` |
| `scripts/unscrub.rb` | smudge-фильтр: плейсхолдеры → ссылки, на checkout |
| `.gitattributes` | привязывает фильтр к `config.yaml` |

Если в `proxy-providers` окажется ссылка, которой нет в `.secrets.yaml`,
`scrub.rb` завершится с ошибкой и git прервёт коммит — секрет не уедет молча.
Добавьте её в `.secrets.yaml` под новым именем и повторите.

Кэш подписок (`proxy-providers/*.yaml`, `*.url`) не версионируется: mihomo
перезаписывает его сам, а внутри лежат узлы с UUID.
