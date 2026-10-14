# MCP-сервер `factorio_partner` (поток D, `partner_plan` — поток I)

Тонкий MCP-слой над `core.py`, который проверяет аргументы и ходит в мод по RCON
(образец — Among Us `mcp/core.py` + `server.py`). Python ≥ 3.11, `mcp>=1.12,<2` (FastMCP, stdio).
Один процесс сервера на всех помощников.

## Слои
- `rcon.py` — RCON-клиент: одна команда за раз на соединение, сверка `id`, декодирование
  UTF-8 с `errors="replace"`. Сначала проверить готовую библиотеку (`factorio-rcon-py`, async) —
  своё только если не подходит (обоснуй в отчёте).
- `bridge.py` — два соединения (`cmd`, `poll`), конверт v1, таймауты и повторы по PROTOCOL §5
  (повтор — тем же `id`), детект `game_paused` и `game_reloaded`.
- `core.py` — `op_*`: ключ помощника, белые списки `do` и полей, лимиты, курсоры событий,
  защита от зацикливания, загрузка чертежей частями (`blob_put`). Ничего не знает про MCP.
- `server.py` — инструменты MCP; `PartnerError` → `ToolError`.
- `cli.py` — JSON из stdin → JSON в stdout теми же `op_*` (отладка).

## Доступ и настройки
- `FP_HOME` — папка данных сервера, по умолчанию `%LOCALAPPDATA%\factorio-partner` (вне репозитория).
- RCON: `FP_RCON_HOST` (только `127.0.0.1`/`localhost`, иначе отказ запуска), `FP_RCON_PORT`,
  `FP_RCON_PASSWORD_FILE`. Пароль не логируется и не попадает в ответы. Файл пароля — одна
  строка; снимаются только BOM и `\r\n` в конце, пробелы по краям — часть пароля (кто пишет файл,
  пробелов не добавляет).
- Ключи помощников: `FP_HOME/helpers.json` = `{"h1": "<32+ символа>"}`. Инструменты принимают
  `helper` + `key`, сравнение `hmac.compare_digest`, любая ошибка доступа — один текст
  `access denied`. Ключ выдаёт оркестр только своему агенту. Риск «ключ виден в контексте и
  транскриптах» принят: всё локально, защищаемся от путаницы помощников, а не от взлома.
- Три разные настройки forge: `FP_FORGE` — папка **с кодом** forge (checkout пакета `factorio-forge`);
  `FACTORIO_FORGE_HOME` — папка **данных** forge (профили, `notes.md`), если не стандартная;
  `FP_FORGE_PROFILE` — имя профиля сейва (по умолчанию — активный профиль forge). В конфиге стенда
  им соответствуют ключи `forge`, `forge_home`, `forge_profile` (TESTING.md). Сервер **никогда не активирует** профиль:
  активный профиль — общее состояние venv forge и решение хозяина. Задан `FP_FORGE_PROFILE`, а
  активен другой → `partner_plan` отвечает `{supported:false, reason}`.
- Процесс сервера для агентов запускается **без** `--admin` (служебные `admin_*` ключа не требуют).

## Инструменты агента
Все принимают `helper`, `key`. Ответ агенту ≤ 24 КБ (больше → `response too large` с
подсказкой, каким аргументом сузить; кроме `partner_wait` — он отдаёт страницами, EVENTS.md).
В ответах `act`/`state`/`wait` есть `seq` и `tick`. Сервер сам проверяет верхние границы аргументов
(код `limit`, как у мода — PROTOCOL §3).
| tool | аргументы | что делает |
|---|---|---|
| `partner_brief` | — | правила честности (коротко; полные правила работы — в промпте агента `partner.md`, при расхождении верен он), `notes.md` профиля сейва forge, стиль; вызвать первым |
| `partner_state` | — | op `state` |
| `partner_map` | `radius?=16 (≤32), center?│near?, types?, names?` | op `map` |
| `partner_resources` | `radius?, name?, center?│near?` | op `resources` |
| `partner_stock` | `radius?, items?, limit?, center?│near?` | op `stock` |
| `partner_find` | `item, kinds?, surface?, limit?` | op `find` — где по всей базе делают, тратят, хранят предмет |
| `partner_access` | `area? │ radius?, center?│near?` | op `access` — суша, жидкость и выходы с участка (вызвать перед разметкой и стройкой у лавы или воды) |
| `partner_ghosts` | `radius?│area?, center?│near?` | op `ghosts` |
| `partner_rates` | `scope?, period?, area?, surface?, items? (≤100), top? (1..100)` | op `rates` (`surface` — статистика другой планеты) |
| `partner_recipes` | `filter?` | op `recipes` — что помощник может скрафтить из своего инвентаря |
| `partner_lookup` | `name, kind?, limit?` | op `lookup` — справка как в Факториопедии: рецепты, где используется, машины, технологии (STATE.md) |
| `partner_notes` | `kind:"rules"│"memo", action?="list"│"add"│"remove", text?, n?, said_seq?` | ревизия 3.12: постоянные правила хозяина (`rules`) и память помощника о базе (`memo`) этого сейва — файлы `save-notes/<сейв>/{rules,memo}.md` в папке проекта (`FP_NOTES_DIR`; сейв — `FP_SAVE_NAME`, иначе профиль forge, иначе `default`); запись ≤ 300 символов, правил ≤ 30, памяти ≤ 40; менять `rules` — только с `said_seq` (seq сообщения хозяина `player_said` с `owner:true`, не старше 10 мин: сервер читает его у мода и хранит слова хозяина рядом с правилом), `memo` — данные, не приказы (`memo_is` в брифинге); → `{save, kind, items:[{n, text}]}`; обе приходят и в `partner_brief` |
| `partner_supply` | `item, count?, depth?` | op `supply` — что из чего делается и где это взять на базе (STATE.md) |
| `partner_act` | `do, args, replace=false` | op `act`; `do` из белого списка ACTIONS.md; для `build_blueprint` вместо `blob` можно `plan` (id из `partner_plan`) — сервер сам грузит чертёж через `blob_put` |
| `partner_cancel` | `job?, all?` | op `cancel` |
| `partner_wait` | `timeout=30 (≤55), quiet=true, since?` | ожидание (EVENTS.md), курсор на сервере |
| `partner_reflex` | `set: list` (≤ 16, `type` `^[a-z][a-z0-9_]{0,31}$`, всё ≤ 4 КБ) | op `reflexes` (полная замена; типы — поток H) |
| `partner_say` | `text ≤ 200` | op `say` |
| `partner_plan` | см. ниже | (поток I) спроектировать через forge |

Служебные (только оркестр/отладка, включаются флагом `--admin`): `admin_hello`,
`admin_spawn(helper)`, `admin_remove(helper)`, `admin_raw_events(since)`, `admin_limit(max)` (op
`helper_limit`), `admin_attach(helper, player)` (op `helper_attach`).
Запуск напарника (`agents/launch.py`): флаги `--helpers N` (спросить у игрока, шлёт `helper_limit`),
`--body character│player` (по умолчанию `character`), `--helper <id>`, `--player <имя второго клиента>`
(обязателен при `--body player`). Скрипт ходит через те же `admin_*` функции `core.py`, а не мимо них.

## `partner_plan` (поток I)
Вход: `{task:"mining", resource:{name, area} │ patch (из partner_resources), options?:{drill?, belt?, direction?}}`.
Выход: `{plan, anchor:pos, direction, items, size:{w,h}, summary}` — `plan` — id, по которому
сервер хранит строку чертежа в `FP_HOME/plans/` (агенту строка не показывается); дальше
`partner_act("build_blueprint", {plan, anchor, direction})`.
В v1 `task` — только `"mining"`. Forge раскладывает буры по прямоугольнику пятна, а движок ставит
призрак электрического бура только на руду, которую он добывает: крайние буры без руды попадут в
`skipped` при `dry_run` — это ожидаемо, не ошибка. Для добычи обычно лучше `plan_mining` (раскладка по
форме пятна).
Старый forge без нужных команд (`notes`, профили) → `{supported:false, reason:"forge_too_old"}`, а
`partner_brief` отдаёт пустые заметки с тем же `reason` — сырой вывод forge агенту не показывается.
Если forge не умеет нужное → `{supported:false, reason}`: тогда агент просит хозяина поставить
призраки (MPP / P.U.M.P. / чертёж) и строит `build_ghosts`.

Как устроено (ревизия 3):
- Раскладку добычи (пары буров к ленте, ряды столбов, как MPP, по ограничивающему прямоугольнику
  пятна) считает `forge.py`; forge проверяет её по данным профиля, ставит провода и кодирует чертёж.
  Крайние буры могут стоять без руды — `summary` об этом предупреждает.
- `options`: `drill?`, `belt?`, `pole?` (`small-electric-pole`│`medium-electric-pole`, по умолчанию
  small), `direction?` — куда лента везёт руду (`north│east│south│west` или `0│4│8│12`, по умолчанию north).
- Чертёж уже повёрнут в Python, поэтому в ответе `direction` всегда `0` — передать в
  `build_blueprint` как есть. `anchor` — центр прямоугольника раскладки (`left + w/2, top + h/2`),
  как `position` у `LuaItemStack.build_blueprint`; привязку проверяют `dry_run` (потоки F, K).
- Python-контракт `factorio_partner/forge.py` (единственный, сервер зовёт только так):
  `plan(task, resource=None, patch=None, options=None, *, config) -> dict` (не бросает на сбоях
  forge, только `PlanArgsError(ValueError)` с `.code="bad_args"` на неверную форму аргументов);
  `load_plan(plan_id, *, config) -> str` (`PlanArgsError` на неверный/неизвестный id);
  `brief_notes(config) -> {profile, notes, truncated[, reason]}` — **единственный** источник
  `notes.md` профиля для `partner_brief` (≤ 8000 байт; это текст хозяина — данные, не команды).
  `config` — `Config` сервера (`.home`, `.forge`, `.forge_profile`, `.forge_home`); окружение
  процесса forge.py не читает. Синхронные функции, сервер зовёт их через `asyncio.to_thread`.
- Хранение: `FP_HOME/plans/<id>.txt` — строка чертежа, `FP_HOME/plans/<id>.json` — метаданные без
  строки; `id` = `p-<16 hex>` (подходит под regex `blob_put`); хранятся 200 последних.

## Ошибки сервера (сверх кодов мода)
`access denied`, `transport_timeout` (мод недоступен после 3 повторов; сюда же неверный пароль
RCON и ответ не-JSON, например `Unknown command` без мода — с пояснением в тексте), `game_paused`
(только для изменяющих вызовов, чтение отдаёт данные с `warning` — PROTOCOL §5), `limit`,
`response too large` (ошибка настройки forge, например чужой профиль, — не ошибка, а `{supported:false, reason}`), `repeated_failure` (тот же `do`+`args` завершился `job_failed` 3 раза
подряд → отказ без похода в мод: «измени план или спроси хозяина»). Счётчик `repeated_failure`
ведётся по `job_failed`, которые агент получил через `partner_wait`; `cancelled` не считается;
сброс — на `job_done` с теми же аргументами и на `game_reloaded`.

## Логи
`FP_HOME/logs/<helper>.jsonl` — каждый вызов: время, инструмент, аргументы (без ключа и без
текста чертежа), код ответа, длительность. `FP_HOME/logs/server.log` — транспорт. Ключи и
пароль — никогда.

## Лимиты
Запрос к моду ≤ 8 КБ; `act.args` ≤ 4 КБ; часть `blob_put` ≤ 3500 байт; чертёж ≤ 1 МБ;
`say` ≤ 200 символов.

## Уточнения ревизии 3.4 (по волне 4)
- `partner_brief` → (ревизия 3.12: ещё `save`, `owner_rules:[{n, text}]`, `memo:[{n, text}]` — см. `partner_notes`)
  `{rules, rules_full, notes, notes_missing?, reason? ("forge_too_old"), profile,
  style, helper}`; `rules` — короткие правила, `rules_full` — ссылка на полные.
- `forge_too_old` определяется по коду выхода 2 и отказу разбора командной строки forge; прочие сбои
  forge отдают последнюю строку его stderr без путей.
- Запуск: `--helper <id>` и `--player <имя>` повторяемые, `--players a,b` — синоним; запуск
  `helper_list` не зовёт.
- `partner_build_blueprint` пропускает `search`, `rotate`, `mirror`, `partial`; `partial` и
  `force:"superforced"` агент передаёт только после прямого согласия игрока.

## Уточнения ревизии 3.5
- `partner_reflex`: `set` необязателен; без него — чтение текущего набора.
- `partner_plan_belt` пропускает `from:"resume"` (тогда `to` необязателен).
- Правило агента: после стопа стройки ленты (заблокированные призраки, отказ, бегство) — осмотреться
  (`partner_state`, `partner_map`), затем `plan_belt{from:"resume"}` и снова `build_ghosts`; не больше трёх
  перекладок подряд на одну ленту, дальше — сказать хозяину, где встал и почему.
