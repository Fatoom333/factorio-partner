# План разработки v1 и владение файлами

Цель v1 — **поручение целиком**: хозяин говорит «поставь добычу на этой руде», Claude смотрит
пятна руды/склады/производство, берёт план (призраки хозяина из MPP/P.U.M.P./чертежа или чертёж
из forge через `partner_plan`), собирает предметы, идёт и строит, докладывает. Один помощник,
протокол — под нескольких.

## Модульный интерфейс Lua (для всех потоков)
Модуль в `scripts/{actions,perception,reflexes,lib}/` возвращает таблицу `M`:
- `M.name`, `M.schema`, `M.start/tick/stop` — действия ([ACTIONS.md](ACTIONS.md));
- `M.ops = { <op> = function(args, ctx) -> data }` — операции чтения; ошибки —
  `require("scripts.core.err").raise(code, text)`;
- `M.reflexes = { <type> = { schema = {...}, check = function(helper_id, entity, params, tick) end } }` —
  ядро зовёт `check` раз в 10 тиков для каждого живого помощника под `pcall`; быстрые реакции на
  урон — через `M.events[on_entity_damaged]`;
- `M.events = { [defines.events.X] = { handler = fn(e), filter = EventFilter│nil } }` — ядро
  объединяет: для одного события вызывает обработчики всех модулей по очереди под `pcall`;
  фильтры склеивает (массивы конкатенирует; если у кого-то `filter=nil` — регистрирует без
  фильтра). Для `on_entity_damaged` / `on_entity_died` фильтр `{{filter="type", type="character"}}`
  обязателен. Фильтры только «или» (`mode="and"` запрещён — ядро падает с понятной ошибкой);
  обработчик может получить сущность, отфильтрованную для другого модуля, — проверять самому.
- `M.on_nth = { [n] = fn(e) }` — ядро склеивает в один `script.on_nth_tick` на каждое `n`;
- `M.on_init()`, `M.on_configuration_changed(data)` — ядро вызывает у всех.
Модули **не** вызывают `script.on_event`/`on_nth_tick`/`commands.add_command` сами.
`require` — только при загрузке файла. Своё — только под своим ключом `storage` (PROTOCOL §7).

## Волны и владение
| Волна | Поток | Владеет файлами |
|---|---|---|
| 1 | **A. Ядро мода** | `mod/factorio-partner/{control.lua,info.json,settings.lua}`, `scripts/core/**` (диспетчер `/partner`, конверт, идемпотентность `recent`, `blob_put`, помощники + `helper_*` + хозяин, очередь задач и ctx, буфер событий + `player_said`, `reflexes` op (вызов `M.reflexes`), `say`, `wait`, миграции), `mod/tests/stubs.lua`, `mod/tests/core_*.lua`, `tools/run_lua_tests.py`, `tools/requirements-dev.txt` |
| 1 | **D. MCP-сервер** | `server/**` кроме `server/factorio_partner/forge.py` и `server/tests/test_forge*.py` |
| 1 | **E. Стенд на ПК** | `tools/pc/**` (кроме `scenarios/*` других потоков), `mod/partner-test/**` |
| 1 | **G. Восприятие** | `scripts/perception/{state,map,resources,stock,ghosts,recipes,vision}.lua` (общие помощники — `state.lua` `M.common`), `mod/tests/perception_*.lua`, `mod/tests/stubs_g.lua` |
| 1 | **L. Производство** | `scripts/perception/rates.lua`, `mod/tests/rates_*.lua`, `mod/tests/stubs_l.lua` |
| 1 | **I. Связка с forge** | `server/factorio_partner/forge.py`, `server/tests/test_forge*.py` |
| 2 | **B. Движение** | `scripts/lib/path.lua`, `scripts/actions/{walk,approach,follow}.lua`, `mod/tests/move_*.lua`, `tools/pc/scenarios/move_*.py` |
| 2 | **C. Руки** | `scripts/actions/{mine,craft,insert,extract,collect,pickup}.lua`, `scripts/lib/inventory.lua`, тесты/сценарии `hands_*` |
| 2 | **F. Стройка** | `scripts/actions/{place,build_blueprint,build_ghosts,deconstruct}.lua`, `scripts/lib/build.lua`, тесты/сценарии `build_*` |
| 2 | **H. Рефлексы** | `scripts/reflexes/**` (атака, здоровье, смерть, возрождение — PROTOCOL §6.9, отступление), тесты/сценарии `reflex_*` |
| 3 | **J. Агентский слой** | `agents/**`, `.claude/agents/partner.md` |
| 3 | **K. Сквозной сценарий** | `tools/pc/scenarios/e2e_*.py`, `docs/E2E.md` |

Почему так: B/C/F/H нужна очередь задач ядра и живой стенд (A, E). G, L, I — синхронные
операции и Python, проверяются без очереди; их живые сценарии прогоняются после слияния волны 1.
Скелет этапа 0 содержит файлы-заглушки всех модулей с нужным интерфейсом, поэтому список
`require` в `control.lua` потоки не меняют.

## Конвейер потока (Workflow `partner-wave-N`)
сборка (Opus 5.5, worktree, ветка `wave-N/<поток>`) → юнит-тесты (Sonnet) →
ревью (Fable 5.1, отдельный раздел безопасности и честности) → правки (Opus) →
живой сценарий на ПК (Sonnet, слот = номер потока). Контракты в `docs/` меняет только
координатор; нужна правка — `contract_issues` в отчёте.

## Правки кода волны 1 под ревизию 3 (идут вместе с волной 2, владельцы — те же потоки)
- **A:** префикс `say` → `<helper>: текст`; `players_online` в `hello`.
- **D:** инструмент `partner_recipes`; `surface?` и `near?` в `partner_rates`/`partner_map`; вызов forge
  только по Python-контракту MCP.md (`plan(..., config=)`, `load_plan(id, config=)`) — убрать подбор
  сигнатуры и запасной загрузчик плана; `partner_brief` берёт заметки только из `forge.brief_notes`
  (убрать угадывание профиля в `brief.py`); фейковый forge в `test_core.py` — под ту же сигнатуру.
- **I:** `forge.py` — ровно сигнатуры MCP.md (без режима `args`-словаря и чтения окружения),
  `brief_notes(config)`.
- **E:** сейв по умолчанию `Vulkan-Start-test.zip`; `e_chart` — на силе игрока (как `e_chart_probe`).
- **L:** замечания ревью: предел `maximum_productivity`, `rocket-silo` среди машин, ошибка
  `get_flow_count` не превращается молча в пустой ответ, хозяин — через общую функцию ядра.

## Правки кода под ревизию 3.1 (поток X, волна 2b)
- **A:** `scripts/core/vis.lua` — `visible(helper_id, surface, pos) -> bool` (`is_chunk_visible` или ≤ 32 клеток от
  живого тела помощника); `scripts/core/target.lua` — `resolve(surface, target) -> LuaEntity|nil` (ACTIONS «target»);
  верхние границы схем действий → `limit`.
- **B, C, G, L:** перейти на `vis.visible` и `target.resolve`; тесты `move_*`/`hands_*` — ждать `limit`; `stuck` — шумное;
  `no_space`; `whole_stacks_only` по ACTIONS. **DI:** `near?/center?` у resources/stock/ghosts, `top`/`items` ≤ 100.

## Правки кода под ревизию 3.2 (поток Y, идёт с волной 3)
- **A:** `migrate.ensure_shape` — ключ `reflex_state`; `helper_spawn` считает `alive` + `dead` (лимит 4);
  `hello.module_errors` (счётчик ошибок под `pcall` в модулях и рефлексах); `unit_number` ≥ 1;
  операция `helper_limit` и `max_helpers` вместо константы `MAX_ALIVE` (PROTOCOL §4). **D, J:** запуск
  спрашивает у игрока число помощников и шлёт `helper_limit`.
- **D:** границы как в ACTIONS «Границы чисел v1» (`unit_number` ≥ 1, `collect.radius` 1..128 и др.).
- **B:** не слать два шумных `stuck` подряд на одно перепланирование при `path_lost`.
- **F:** убрать из `lib/build.lua` запасные `optional()`/`fallback_vis`/`fallback_target` и их тесты; цель
  в сценариях — `{unit_number, pos}`; **плитки** в `build_blueprint`/`build_ghosts` (ACTIONS; проверить
  живьём, ставит ли движок призраки построек над водой вместе с призраками отсыпки); живьём — постройки 2×2, повороты 8/12, режимы `robots`/`auto`.
- **G, H:** `vis.visible` вместо прямого `is_chunk_visible` (`reflexes/common.lua`, perception).
- **H:** `flee` пересчитывает кандидатов после `path_failed`. Тесты `core_helpers`/`core_jobs`, которые H
  поправил под смерть и возрождение, остаются за A.
- **E:** стенд читает вынесенный журнал и проваливает сценарий по `log_must_not_match`.
- Смерть от урона без консольных команд на стенде не воспроизвести — проверяется на финале с игроком.

## Готово для потока
Юнит-тесты зелёные + ревью без блокеров + (если есть) живой сценарий на ПК прошёл.
