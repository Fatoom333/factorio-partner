# Макрокоманды (`act`)

Задача ставится `act {do, args, replace?=false}` и исполняется модом сама много тиков.
Ответ `act` = «принято» (`{job, queued_before}`), итог — событие `job_done` / `job_failed`
([EVENTS.md](EVENTS.md)). Все действия соблюдают честность ([PROTOCOL.md §6](PROTOCOL.md)).

## Общие типы аргументов
- `pos` = `{x:number, y:number}`; `area` = `{left_top:pos, right_bottom:pos}`, сторона ≤ 128.
- `target` = `{unit_number:int, pos:pos}` │ `{name:string, pos:pos}` — сущность на поверхности помощника
  (поиск: `game.get_entity_by_unit_number`, а если nil — `find_entities_filtered{position=pos, radius=2}`
  с тем же `unit_number`: в 2.0 первый находит только сущности с флагом `get-by-unit-number`),
  **своей силы или `neutral`**, иначе `not_found`. `unit_number` — целое ≥ 1. `pos` обязателен в форме
  `{name, pos}` и желателен в форме `{unit_number, pos}`: без него сущность, которую движок не отдаёт по
  номеру, — `not_found`. Сущность на другой поверхности — тоже `not_found` (номер не раскрывает чужую
  поверхность). Призрак как `target` — `bad_args` (для призраков есть `build_ghosts`).
- `items` = `{[item_name]: count}`, count — целое 1..100000; качество всегда `normal`.
- Нарушение схемы: верхняя граница (`max`, длина, число имён) → `limit`, всё остальное → `bad_args`
  (PROTOCOL §3). Взаимоисключающие аргументы (`target│to`) — ровно один, иначе `bad_args` в `start`.
- Предметы с данными (`is_item_with_entity_data`, броня, чертежи) и портящиеся — только целым стаком
  (`transfer_stack`/`swap_stack`); вставка такого предмета в машину — `bad_args` (в v1). Если заявка
  меньше неделимого стака, `insert`/`extract`/`collect` его не берут: остаток в `detail`, а при итоге
  `failed{no_items}` — `detail.reason = "whole_stacks_only"`.
- **Нет места** (`no_space`): инвентарь помощника или цели полон. Итог — `job_failed{code:"no_space"}`
  даже при частичном успехе; `detail` несёт сделанное (те же поля, что у `done.detail`) и
  `reason = "inventory_full"`.
- **Границы чисел v1:** `walk.radius` 0..64; `follow.distance` 1..32, `duration_s` 1..3600;
  `craft.count` 1..10000; `collect.radius` 1..128; `build_ghosts.radius` 1..64; `wait.seconds` 1..600.
- **Списки в `detail`** (`skipped`, `blocked`, `from`) обрезаются до 20 записей, рядом — полное число
  (`skipped_total`, `blocked_total`), иначе событие не влезает в 4000 байт (EVENTS.md).

## Подход (единое правило)
Все действия, которым нужна цель рядом, **сами подходят** к ней через `ctx.approach`
(до нужной дистанции), а не падают `not_reachable`. Дистанции:
`mine` (ресурс) — `resource_reach_distance` (2.7); `mine`/`deconstruct` (постройка),
`insert`, `extract`, `collect` — `reach_distance` (10); `place`, ручная стройка — `build_distance` (10);
`pickup` — `item_pickup_distance` / труп — `reach_distance`. Цель на другой поверхности →
`not_reachable`; путь не найден → `path_failed`; в неоткрытых чанках → `not_charted`.
Отдельное действие `approach` — «встань рядом и жди».

## Интерфейс модуля действия (Lua)
Файл `mod/factorio-partner/scripts/actions/<name>.lua`:
```lua
local M = {}
M.name = "walk"
M.schema = { to = {type="pos", required=true}, radius = {type="number", min=0, max=64, default=1} }
-- ctx: { helper_id, entity (LuaEntity character, valid), tick,
--        emit(kind, data),                       -- события, EVENTS.md
--        approach(task, goal_pos, distance)      -- = path.step: nil (иду) | true (на месте) | result (ошибка)
--        cancel_approach(task) }                 -- = path.cancel
function M.start(task, ctx) end   -- первый тик; может сразу вернуть result
function M.tick(task, ctx) end    -- каждый тик; nil = ещё работаю, result = готово
function M.stop(task, ctx) end    -- отмена/сбой: ОБЯЗАН вызвать ctx.cancel_approach(task)
return M                          --   и снять своё: mining_state, crafting и т.п.
-- result = { status = "done"|"failed", code = "<PROTOCOL §3>", text = "...", detail = {...} }
-- task   = { job, helper, ["do"], args (провалидированы, с default), req, started_tick, ...своё }
```
- Ядро (`scripts/core/jobs.lua`) валидирует `args` по `M.schema` до постановки (`bad_args`),
  зовёт `start/tick/stop` под `pcall` (`internal`), шлёт `job_done{job, do, detail}` /
  `job_failed{job, do, code, text, detail}`.
- Типы схемы: `pos`, `area`, `items`, `target`, `string` (+`max`, `pattern`), `number`/`int`
  (+`min`,`max`), `bool`, `enum` (+`values`), `list` (+`of`, `max`), `object` (+`fields`), `any`;
  **объединение** — `type = {"pos", "string"}` с `values = {"player"}` (для `pos│"player"`);
  поле `required`, `default`.
- Своё состояние задачи — в `task` (переживает сохранение). Не хранить в `task` функции.
- Задача без прогресса 60 с → ядро снимает её с `stuck`. Прогрессом считается: сдвиг тела ≥ 0.1,
  изменение числа предметов в основном инвентаре, изменение очереди крафта, изменение
  `task.progress = {done, total}` (ядро шлёт шумное `job_progress` раз в 5 с) и **«пульс»
  `task.progress_tick = ctx.tick`** — его ставят действия, которые законно стоят на месте
  (`follow` рядом с хозяином, ожидание дронов в `build_ghosts`).
- Чтобы узнать задачу помощника, другие модули (G `state`) зовут `jobs.active(helper)` и
  `jobs.queue_len(helper)` из `scripts.core.jobs` (только чтение), а не разбирают `storage.jobs`.

## Модуль пути `scripts/lib/path.lua` (поток B)
Ядро подставляет `ctx.approach = path.step`, `ctx.cancel_approach = path.cancel`.
- `path.step(task, ctx, goal_pos, distance) -> nil|true|result` — всё состояние в
  `task.approach = {state, path_id, waypoints, i, retries, best_dist, last_move_tick}`.
- Запросы пути: `surface.request_path{... entity_to_ignore = entity}`, учёт в
  `storage.path_requests[id] = {helper, job}`; ответ ловит `path.on_path_finished(e)`
  (модуль B экспортирует `M.events[defines.events.on_script_path_request_finished]`).
- `try_again_later` → повтор через 60 тиков, до 10 раз → `path_failed`.
- Не сдвинулся на 0.1 за 60 тиков → перепланирование (1 раз), потом `stuck`. Игрок на пути
  («шагает на месте») — обход: перепланирование с небольшим смещением цели.
- `path.cancel(task, ctx)` — `walking_state={walking=false}`, забыть `path_requests` задачи.

## Список v1
| do | args | done.detail | Поток |
|---|---|---|---|
| `walk` | `to:pos│"player", radius?=1` | `{pos, walked}` | B |
| `approach` | `target│to:pos│"player", distance?` (по умолчанию reach; к постройке — не меньше половины её `bounding_box` + 0.6) | `{pos}` | B |
| `follow` | `distance?=3, duration_s?=600` (за хозяином, та же поверхность) | `{}` | B |
| `mine` | `target│resource:string, near?:pos, count:int` | `{mined: items}` | C |
| `craft` | `recipe, count:int` | `{crafted: items}` (опрос очереди: событий крафта нет) | C |
| `insert` | `target, items` | `{inserted: items}` | C |
| `extract` | `target, items?` (нет → всё), `equip?:bool` | `{extracted: items}` | C |
| `collect` | `items, center?│near?:"player", radius?=64` | `{collected: items, missing: items, from:[unit]}` | C |
| `pickup` | `target?` (труп) │ `area?` (предметы на земле) | `{picked: items}` | C |
| `place` | `item, pos, direction?:0..15, recipe?` | `{unit_number, name, pos}` | F |
| `build_blueprint` | `blob, anchor:pos, direction?:0│4│8│12, mode?="auto", dry_run?:bool` | `{ghosts:int, skipped:[...], skipped_total, tiles_skipped, missing: items}` + поля `build_ghosts` | F |
| `build_ghosts` | `area?│radius?=64, mode?="auto"` | `{built:int, left:int, blocked:[...], blocked_total, missing: items}` | F |
| `deconstruct` | `target│area, filter?:[name]` | `{removed:int, got: items}` (`removed` — только разобранное самим помощником) | F |
| `wait` | `seconds:1..600` | `{}` — пауза в очереди, никогда не заменяет её | A |

Отдельных подробностей требуют:

**`build_blueprint`** — мод склеивает `storage.blobs[blob]` → `game.create_inventory(1)` →
`inv[1].import_stack(str)` (0 — ок, 1 — провал → `bad_args`; книги, планировщики
деконструкции/апгрейда → `bad_args`) → для каждой сущности чертежа проверка
`manual_ghost` (§6.5) → `inv[1].build_blueprint{surface, force, position=anchor,
direction, build_mode=defines.build_mode.normal, skip_fog_of_war=false}` создаёт **призраки**
→ `inv.destroy()` → дальше работает как `build_ghosts` по площади чертежа.
`anchor` — **центр чертежа** (как `position` у `LuaItemStack.build_blueprint`), `direction` —
`defines.direction` (0..15). `dry_run=true` — только проверки, без призраков: вернуть
`{ghosts, skipped, missing}`. `build_mode` `forced`/`superforced` запрещены.
Уточнения v1: `direction` — только 0/4/8/12 (иначе `bad_args`); чертёж ≤ 1000 сущностей и сторона ≤ 128
(`limit`); **плитки не ставятся** (`tiles_skipped` — их число); `import_stack` = -1 (часть сущностей
отброшена, например мод выключен) принимается, отброшенное попадает в `skipped` с `reason:"unknown"`;
ни одного призрака не встало → `failed{cannot_place}` с `skipped`. Проверка `manual_ghost` решает только,
что попадёт в `skipped` (и ответ `dry_run`), сами призраки ставит `build_blueprint` движка.

**`place`** — `recipe` только для `assembling-machine` (иначе `bad_args`); предмет с данными — `bad_args`;
если на месте уже стоит такой же призрак, он **не** оживляется — `cannot_place` (для призраков —
`build_ghosts`).

**`build_ghosts`** — строит призраки силы в области (поставленные игроком через MPP,
P.U.M.P., чертёж, или `build_blueprint`). Перед стартом: список призраков, нужные предметы,
`blocked` (ghost_revive = false — не строить, вернуть в detail). `mode`:
`"robots"` — только личные дроны помощника (предметы из его инвентаря); `"hand"` — только
руками; `"auto"` — дроны на то, на что есть предметы и дроны, остальное руками. Готово (`done`) —
в области не осталось строимых призраков; `failed{code:"stuck"}` — 60 с без прогресса
(`detail: {left, blocked, missing}`); `failed{code:"no_items"}` — кончились предметы и
`collect` не вызывался (сбор — решение агента). Прогресс — `job_progress{built, left}`.
Уточнения v1: `"robots"` без личных дронов или робопорта в броне → `no_items` сразу; в `"auto"` дронам
даётся 30 с без единой постройки, потом задача строит руками; ожидание дронов держит «пульс», но
не дольше 58 с без построек (дальше — правило 60 с ядра). Призрак руками — `ghost.revive{raise_revive=true}`
и списание предмета (PROTOCOL §6.5). При откате (предмет не списался) призрак возвращается **без
настроек** (рецепт, фильтры). Переключатель личных дронов (`allow_dispatching_robots`) на время задачи
принадлежит задаче и возвращается в `stop`.

**`extract` / перенос предметов с данными** — броня (`is_armor`, сетка), чертежи и книги,
`is_item_with_entity_data` переносятся только целым стаком `LuaItemStack.transfer_stack` /
`swap_stack`, никогда `remove_item`+`insert`. `equip=true` — броню сразу в
`get_inventory(defines.inventory.character_armor)[1]`.

**`deconstruct`** — `selected = e; mining_state = {mining=true, position=e.position}` до
исчезновения сущности (`on_object_destroyed` или `valid=false`), предметы падают в инвентарь
движком. `mine_entity`, `destroy` запрещены.
Режим `area`: только сущности своей силы; `neutral` (деревья, камни) — только если названы в `filter`;
никогда — персонажи, призраки, руда, техника с водителем; не больше 500 сущностей (`limit`). Имя в
`filter`, которого нет в прототипах, — `bad_args`.

Прогресс долгих задач — шумное `job_progress{job, done, total}` не чаще раза в 5 с.
