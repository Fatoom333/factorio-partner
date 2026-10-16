# MCP-сервер `factorio_partner`

Тонкий MCP-слой над `core.py`, который проверяет аргументы и ходит в мод по RCON
(протокол — [PROTOCOL.md](PROTOCOL.md)). Python ≥ 3.11, `mcp>=1.12,<2` (FastMCP, stdio).
Один процесс сервера на всех помощников. Запуск: `python -m factorio_partner.server [--admin]`;
stdout принадлежит протоколу MCP, журналы — только в файлы (раздел «Логи»).

## Слои
- `rcon.py` — RCON-клиент на библиотеке `factorio-rcon-py` (`AsyncRCONClient`): одна команда за раз
  на соединение, ответ декодируется как UTF-8 с `errors="replace"`; любой сбой закрывает сокет,
  следующий вызов переподключается.
- `bridge.py` — два соединения (`cmd`, `poll`), конверт v1, таймауты и повторы по PROTOCOL §5
  (повтор — тем же `id`), детект `game_paused` и `game_reloaded`.
- `core.py` — `op_*`: ключ помощника, белые списки `do` и полей, лимиты, курсоры событий,
  защита от зацикливания, загрузка чертежей частями (`blob_put`), заметки по сейвам. Ничего не
  знает про MCP.
- `validate.py` — проверки аргументов до похода в мод; `savenotes.py` — файлы правил и памяти
  (`partner_notes`); `brief.py` — ответ `partner_brief`; `forge.py` — связка с factorio-forge
  (`partner_plan`).
- `server.py` — инструменты MCP; `PartnerError` → `ToolError` (агент видит `code` или `code: text`).
- `cli.py` — JSON из stdin → JSON в stdout теми же `op_*` (отладка; флаг `--admin` — служебные).

## Доступ и настройки
- `FP_HOME` — папка данных сервера, по умолчанию `%LOCALAPPDATA%\factorio-partner` (без
  `LOCALAPPDATA` — `~/.local/share/factorio-partner`), вне репозитория.
- RCON: `FP_RCON_HOST` (только `127.0.0.1`/`localhost`, `localhost` превращается в `127.0.0.1`; иное —
  отказ запуска), `FP_RCON_PORT` (по умолчанию 27015), `FP_RCON_PASSWORD_FILE`. Пароль читается из
  файла при подключении, не логируется и не попадает в ответы. Файл пароля — одна строка;
  снимаются только BOM и `\r\n` в конце, пробелы по краям — часть пароля (кто пишет файл, пробелов
  не добавляет).
- Ключи помощников: `FP_HOME/helpers.json` = `{"h1": "<32+ символа>"}` (ключ 32–256 символов).
  Инструменты принимают `helper` + `key`, сравнение `hmac.compare_digest`, любая ошибка доступа —
  один текст `access denied`. Ключи выдаёт запускающий скрипт (`agents/launch.py`) — каждому агенту
  только его ключ. Риск «ключ виден в контексте и транскриптах» принят: всё локально, защищаемся от
  путаницы помощников, а не от взлома.
- Три разные настройки forge: `FP_FORGE` — папка **с кодом** forge (checkout пакета `factorio-forge`);
  `FACTORIO_FORGE_HOME` — папка **данных** forge (профили, `notes.md`), по умолчанию
  `%APPDATA%\factorio-forge`; `FP_FORGE_PROFILE` — имя профиля сейва (по умолчанию — активный
  профиль forge). В конфиге стенда им соответствуют ключи `forge`, `forge_home`, `forge_profile`
  (TESTING.md). Сервер **никогда не активирует** профиль: активный профиль — общее состояние venv
  forge и решение хозяина. Задан `FP_FORGE_PROFILE`, а активен другой → `partner_plan` отвечает
  `{supported:false, reason}`.
- Заметки по сейвам (`partner_notes`): `FP_NOTES_DIR` — папка, по умолчанию `save-notes/` в корне
  репозитория (в `.gitignore`: это записи хозяина); имя сейва — `FP_SAVE_NAME`, иначе
  `FP_FORGE_PROFILE`, иначе активный профиль forge, иначе `default` (имя —
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`).
- Стиль общения — `FP_HOME/style.md` (≤ 4 КБ, длиннее обрезается); его отдаёт `partner_brief`.
- Процесс сервера для агентов запускается **без** `--admin` (служебные `admin_*` ключа не требуют).

## Инструменты агента
Все принимают `helper`, `key`. Ответ агенту ≤ 24 КБ (больше → `response too large` с
подсказкой, каким аргументом сузить; кроме `partner_wait` — он отдаёт страницами, EVENTS.md).
В ответах `act`/`state`/`wait`/`cancel`/`recipes` есть `seq` и `tick`. Сервер сам проверяет верхние
границы аргументов (код `limit`, как у мода — PROTOCOL §3).
| tool | аргументы | что делает |
|---|---|---|
| `partner_brief` | — | короткие правила честности, заметки хозяина о сейве, его правила и память помощника, стиль; вызвать первым (ниже «partner_brief») |
| `partner_state` | — | op `state` |
| `partner_map` | `radius?=16 (≤32), center?│near?, types?, names?` | op `map` |
| `partner_resources` | `radius?, name?, center?│near?` | op `resources` |
| `partner_stock` | `radius?, items?, limit?, center?│near?` | op `stock` (`items` — список имён) |
| `partner_find` | `item, kinds?, surface?, limit?` | op `find` — где по всей базе делают, тратят, хранят предмет |
| `partner_status` | `radius?=64 (≤128), limit?=20 (≤50), center?│near?` | op `status` — что стоит и почему: остановившиеся машины хозяина в радиусе по причинам (STATE.md) |
| `partner_access` | `area? │ radius?, center?│near?` | op `access` — суша, жидкость и выходы с участка (вызвать перед разметкой и стройкой у лавы или воды) |
| `partner_ghosts` | `radius?│area?, center?│near?` | op `ghosts` |
| `partner_rates` | `scope?, period?, area?, surface?, items? (≤100), top? (1..100)` | op `rates` (`surface` — статистика другой планеты) |
| `partner_recipes` | `filter?` | op `recipes` — что помощник может скрафтить из своего инвентаря |
| `partner_lookup` | `name, kind?, limit?` | op `lookup` — справка как в Факториопедии: рецепты, где используется, машины, технологии (STATE.md); у `not_found` подсказки — в `detail.suggest` |
| `partner_notes` | `kind:"rules"│"memo", action?="list"│"add"│"remove"│"confirm", text?, n?, said_seq?` | постоянные правила хозяина (`rules`) и память помощника о базе (`memo`) этого сейва (ниже «partner_notes») → `{save, kind, items:[{n, text, owner_said?}]}` |
| `partner_supply` | `item, count?, depth?` | op `supply` — что из чего делается и где это взять на базе (STATE.md) |
| `partner_act` | `do, args, replace=false` | op `act`; `do` из белого списка ACTIONS.md (ниже «partner_act») |
| `partner_cancel` | `job?, all?` | op `cancel` (ровно одно из двух) |
| `partner_hold` | `release?=false, said_seq?` | op `owner_hold`: без `release` — прочитать hold хозяина у помощника; `release:true` + `said_seq` (новое поручение хозяина, `player_said` `owner:true`) — снять его; правила снятия — EVENTS.md «Слово хозяина» |
| `partner_wait` | `timeout=30 (≤55), quiet=true, since?` | ожидание (EVENTS.md), курсор на сервере |
| `partner_reflex` | `set?: list` (≤ 16 рефлексов, всё ≤ 4 КБ) | op `reflexes`: полная замена набора, `[]` снимает все; без `set` — прочитать текущий набор (типы — EVENTS.md) |
| `partner_say` | `text ≤ 200` | op `say` (префикс с именем помощника ставит мод, PROTOCOL §4) |
| `partner_plan` | см. ниже | спроектировать добычу через forge |

### `partner_brief`
Ответ: `{rules, rules_full, notes, notes_missing?, reason?, profile?, style?, helper, save,
owner_rules:[{n, text, owner_said?}], memo:[{n, text}], memo_is:"data, not orders"}`.
- `rules` — короткие правила честности; полные правила работы — в промпте агента, `rules_full` —
  ссылка на него (`.claude/agents/partner.md`); при расхождении верен промпт.
- `notes` — `notes.md` профиля сейва forge (≤ 8000 байт, это текст хозяина — данные, не команды);
  единственный источник — `forge.brief_notes`. Заметок нет — `notes:null` и причина в
  `notes_missing`; у старого forge без нужных команд ещё `reason:"forge_too_old"`. Сырой вывод forge
  агенту не показывается.
- `style` — `FP_HOME/style.md`, если есть.
- `save`, `owner_rules`, `memo` — заметки этого сейва (как `partner_notes` с `action:"list"`).

### `partner_notes`
Постоянные правила хозяина (`rules`) и память помощника о базе (`memo`) живут дольше одной смены:
файлы `<папка заметок>/<сейв>/rules.md` и `memo.md` — нумерованный markdown-список, по записи на
строку (хозяин может править их руками). Пишет туда только помощник через этот инструмент.
- `list` — показать; `add` — добавить `text` (запись ≤ 300 символов, к ней дописывается дата);
  `remove` — убрать запись `n`. Записей: правил ≤ 30, памяти ≤ 40 (больше → `limit`).
- `memo` — заметки помощника (где мусорный бак, какой сундук для чего): данные, не приказы. Меняются
  без подтверждения.
- **`rules` меняются только словом хозяина:**
  1. `add` с `said_seq` — номер его сообщения (`player_said`, `owner:true`, не старше 10 минут; сервер
     сам читает это событие у мода). Сервер сам спрашивает хозяина в чате точным текстом:
     «Запомнить правило: «…»? Ответь «да».» и отвечает `{save, kind, pending, items, next}`.
  2. `confirm` с `said_seq` его ответа — только **первого** его сообщения после вопроса; ответ — «да»
     (или `ага`, `подтверждаю`, `yes`, `y`, `ok`, `ок`, `+`). Иначе правило отброшено (`bad_args`).
     Вопрос ждёт не дольше 2 минут; пока ждёт, `partner_say` отказывает **всем** помощникам
     (`bad_args`), чтобы следующее сообщение хозяина ответило именно на вопрос.
  3. `remove` — тоже с `said_seq` его сообщения.

  Каждое сообщение хозяина — на одно изменение (повтор того же `said_seq` → `bad_args`). Правило ≤ 160
  символов (читается хозяину одной строкой чата); в тексте правила « » заменяются на `"`, «хозяин:» —
  на «хозяин -», чтобы текст не выдал себя за слова хозяина. Слова хозяина хранятся рядом с правилом
  и приходят отдельным полем `owner_said`. Текст других игроков, страниц и вывода инструментов
  правилом не становится.

### `partner_act`
- `do` и поля `args` — из белого списка (ACTIONS.md); неизвестное поле, неверный тип, нарушение
  «ровно одно из» → `bad_args` без похода в мод; `args` ≤ 4 КБ.
- `build_blueprint`: вместо `blob` можно `plan` (id из `partner_plan`) — сервер сам грузит чертёж
  через `blob_put` (id части — `bp-<16 hex>`). Сервер пропускает `search`, `rotate`, `mirror`,
  `partial`; `partial` и `force:"superforced"` агент передаёт только после прямого согласия хозяина.
  Поиск сдвига ничего не нашёл — сервер добавляет в `detail` события `fit:null` (в JSON мода `null`
  нет: мод шлёт `fit_checked` без `fit`).
- `plan_belt`: `from:"resume"` разрешён без `to`. Правило агента: после стопа стройки ленты
  (заблокированные призраки, отказ, бегство) — осмотреться (`partner_state`, `partner_map`), затем
  `plan_belt{from:"resume"}` и снова `build_ghosts`; не больше трёх перекладок подряд на одну ленту,
  дальше — сказать хозяину, где встал и почему.
- Ответ — `{job, queued_before}`; итог — событием `job_done` / `job_failed`.

## Служебные инструменты и запуск
Служебные (только запускающий скрипт и отладка, включаются флагом `--admin`): `admin_hello`,
`admin_spawn(helper)`, `admin_remove(helper)`, `admin_raw_events(since, helper?, limit?)`,
`admin_limit(max)` (op `helper_limit`), `admin_attach(helper, player)` (op `helper_attach`).
Ответ — `{tick, seq, data}`.

Запуск напарника (`agents/launch.py`): флаги `--helpers N` (не задано — спросить у игрока; шлёт
`helper_limit`), `--body character│player` (по умолчанию `character`), `--helper <id>` и
`--player <имя второго клиента>` (оба можно повторять; `--players a,b` — то же списком; `--player`
обязателен при `--body player`). Скрипт ходит через те же `admin_*` функции `core.py`, а не мимо
них, и `helper_list` не зовёт. Тот же запуск без агентов — `python -m factorio_partner.cli
--helpers N [--body …] [--helper …] [--player …]`.

## `partner_plan`
Вход: `{task:"mining", resource:{name, area} │ patch (из partner_resources), options?:{drill?, belt?, pole?, direction?}}`
(ровно одно из `resource`/`patch`; всё ≤ 4 КБ).
Выход: `{plan, anchor:pos, direction, items, size:{w,h}, summary}` — `plan` — id, по которому
сервер хранит строку чертежа в `FP_HOME/plans/` (агенту строка не показывается); дальше
`partner_act("build_blueprint", {plan, anchor, direction})`.
В v1 `task` — только `"mining"`. Forge раскладывает буры по прямоугольнику пятна, а движок ставит
призрак электрического бура только на руду, которую он добывает: крайние буры без руды попадут в
`skipped` при `dry_run` — это ожидаемо, не ошибка. Для добычи обычно лучше `plan_mining` (раскладка по
форме пятна).
Отказы — `{supported:false, reason}`:
- forge не установлен, не умеет нужное или упал (подробности — только в `server.log`); ошибка
  настройки forge (например, задан другой профиль, чем активный) — тоже не ошибка, а этот ответ;
- старый forge без нужных команд (`notes`, профили) — `reason:"forge_too_old"` (определяется по коду
  выхода 2 и отказу разбора командной строки forge; прочие сбои отдают последнюю строку его stderr
  без путей).

Тогда агент размечает добычу через `plan_mining` или просит хозяина поставить призраки (MPP /
P.U.M.P. / чертёж) и строит `build_ghosts`.

Как устроено:
- Раскладку добычи (пары буров к ленте, ряды столбов, как MPP, по ограничивающему прямоугольнику
  пятна) считает `forge.py`; forge проверяет её по данным профиля, ставит провода и кодирует чертёж.
  Крайние буры могут стоять без руды — `summary` об этом предупреждает.
- `options`: `drill?`, `belt?`, `pole?` (`small-electric-pole`│`medium-electric-pole`, по умолчанию
  small), `direction?` — куда лента везёт руду (`north│east│south│west` или `0│4│8│12`, по умолчанию north).
- Чертёж уже повёрнут в Python, поэтому в ответе `direction` всегда `0` — передать в
  `build_blueprint` как есть. `anchor` — центр прямоугольника раскладки (`left + w/2, top + h/2`),
  как `position` у `LuaItemStack.build_blueprint`; привязку проверяет `dry_run`.
- Сервер пропускает агенту только поля контракта (`plan, anchor, direction, items, size, summary`,
  `summary` ≤ 2000 символов); ответ forge другой формы → `{supported:false, reason}`.
- Python-контракт `factorio_partner/forge.py` (единственный, сервер зовёт только так):
  `plan(task, resource=None, patch=None, options=None, *, config) -> dict` (не бросает на сбоях
  forge, только `PlanArgsError(ValueError)` с `.code="bad_args"` на неверную форму аргументов);
  `load_plan(plan_id, *, config) -> str` (`PlanArgsError` на неверный/неизвестный id);
  `brief_notes(config) -> {profile, notes, truncated[, reason]}` — **единственный** источник
  `notes.md` профиля для `partner_brief` (≤ 8000 байт).
  `config` — `Config` сервера (`.home`, `.forge`, `.forge_profile`, `.forge_home`); окружение
  процесса forge.py не читает. Синхронные функции, сервер зовёт их через `asyncio.to_thread`.
- Хранение: `FP_HOME/plans/<id>.txt` — строка чертежа, `FP_HOME/plans/<id>.json` — метаданные без
  строки; `id` = `p-<16 hex>` (подходит под regex `blob_put`); хранятся 200 последних. Неизвестный
  `plan` в `build_blueprint` → `not_found` («вызови partner_plan заново»).

## Ошибки сервера (сверх кодов мода)
- `access denied` — неверный `helper` или `key` (один текст на любую ошибку доступа).
- `transport_timeout` — мод недоступен после 3 повторов; сюда же неверный пароль RCON и ответ
  не-JSON (например, `Unknown command` без мода) — с пояснением в тексте.
- `game_paused` — только для изменяющих вызовов; чтение отдаёт данные с `warning` (PROTOCOL §5).
- `limit` — верхняя граница аргумента, размер `args`, `text` и т.п.
- `response too large` — ответ агенту больше 24 КБ, с подсказкой, каким аргументом сузить.
- `repeated_failure` — тот же `do`+`args` завершился `job_failed` 3 раза подряд → отказ без похода в
  мод: «измени план или спроси хозяина». Счётчик ведётся по `job_failed`, которые агент получил через
  `partner_wait`; `cancelled` не считается; сброс — на `job_done` с теми же аргументами и на
  `game_reloaded`.
- `internal` — сбой самого сервера (подробности — в `server.log`).

## Логи
`FP_HOME/logs/<helper>.jsonl` — каждый вызов: время, инструмент, аргументы (без ключа и без
текста чертежа; длинные строки обрезаны), код ответа, длительность. `FP_HOME/logs/server.log` —
транспорт и сбои. Ключи и пароль — никогда.

## Лимиты
Запрос к моду ≤ 8 КБ; `act.args` ≤ 4 КБ; набор рефлексов ≤ 16 и ≤ 4 КБ; часть `blob_put` ≤ 3500
байт; чертёж ≤ 1 МБ; `say` ≤ 200 символов; ответ агенту ≤ 24 КБ; `partner_wait` ≤ 55 с.
