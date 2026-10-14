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
`mine` (ресурс, **а также деревья и камни** — и в `deconstruct`, замер волны 3) — `resource_reach_distance` (2.7); `mine`/`deconstruct` (постройка),
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
| `mine` | `target│resource:string│item:string, near?:pos, count:int` | `{mined: items}` | C |
| `craft` | `recipe, count:int, wait?=true` | `{crafted: items}` (опрос очереди: событий крафта нет); `wait:false` — `{queued: items, crafts}` сразу | C |
| `insert` | `target, items` | `{inserted: items}` | C |
| `extract` | `target, items?` (нет → всё), `equip?:bool` | `{extracted: items}` | C |
| `rotate` | `target, direction:0│4│8│12` | `{name, pos, direction, was}` | C |
| `collect` | `items, center?│near?:"player", radius?=64` | `{collected: items, missing: items, from:[unit]}` | C |
| `pickup` | `target?` (труп: `{name:"character-corpse", pos}`) │ `area?` (предметы на земле) | `{picked: items}` | C |
| `place` | `item, pos, direction?:0..15, recipe?` | `{unit_number, name, pos}` | F |
| `build_blueprint` | `blob, anchor:pos, direction?:0│4│8│12, mode?="auto", force?="forced", search?=16, rotate?=false, mirror?=false, partial?=false, dry_run?:bool` | `{ghosts:int, tiles:int, skipped:[...], skipped_total, tiles_skipped, on_liquid:int, liquids?, fit?, to_remove?, to_remove_total?, missing: items}` + поля `build_ghosts` | F |
| `build_ghosts` | `area?│radius?=64, mode?="auto"` | `{built:int, tiles_built:int, left:int, removed:int, not_removed:int, blocked:[...], blocked_total, missing: items}` | F |
| `deconstruct` | `target│area, filter?:[name]` | `{removed:int, got: items}` (`removed` — только разобранное самим помощником) | F |
| `plan_mining` | `resource?:string, area│near:pos, layout?="simple", direction?="north", miner?, belt?, pole?, pipe?, options?:object, dry_run?:bool` | `{ghosts:int, drills:int, tiles:int, skipped:int, area, need: items, layout, chosen:{miner, belt│chest, pole, pipe?}, warnings:[...], dry_run?}` | M |
| `plan_belt` | `from:pos│"patch", to:pos, belt?, lanes?=1 (1..4), underground?="auto", start_direction?, dry_run?:bool` | `{ghosts:int, length:int, undergrounds:int, turns:int, need: items, area, path:[pos…] (углы, ≤ 40), warnings:[...]}` | N |
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
`{ghosts, skipped, missing}`.
**Режим постановки `force`** — те же три режима, что у игрока (`defines.build_mode`); поведение
сверено живьём на 2.0.77 (волна 3, Вулканус), кроме отмеченного:
- `"normal"` (клик) — любая помеха (дерево, камень, своя постройка, жидкость) → клетка в `skipped`,
  ничего не помечается.
- `"forced"` (Shift, **по умолчанию**) — деревья и камни (и соседний камень, задетый местом постройки)
  помечаются к сносу; свои постройки не трогаются, призрак над ними не ставится.
- `"superforced"` (Ctrl+Shift) — то же и пометка к сносу **построек своей силы** на пути. Чужая сила
  не трогается ни в одном режиме. Подземные конвейеры при пересечении лент — не проверено.
- **Плитки без опоры (вода, лава, мазут, аммиак, плитки планет из модов)** — правила берутся из
  игры (PROTOCOL §6.12), имён плиток в коде нет. Подложку под постройку ставит сам движок в
  `forced`/`superforced`, если она **возможна**: у плитки есть `default_cover_tile`, и предмет этой
  подложки открыт силе. Тогда подложка — обычный призрак плитки, помощник кладёт её из инвентаря.
- **Подложка невозможна хотя бы под одной клеткой** (обычный случай: фундамент открывается в конце
  игры) → чертёж **не ставится вовсе**: `failed{cannot_place}`, `detail.on_liquid` — число таких клеток,
  `detail.liquids:{[tile]=n}`, и `detail.fit` — ближайший сдвиг, при котором чертёж встаёт целиком:
  `{anchor, shift:{dx,dy}, direction?, mirror?}` либо `null`. Поиск сдвига — по спирали в пределах `search` клеток
  (`search?=16`, 0..32; 0 — не искать), в несколько тиков; с `rotate:true` перебираются ещё четыре
  поворота и зеркало (агент разрешает это сам, когда направление входа и выхода чертежа не важно). `dry_run` отдаёт то же без ошибки. Дальше
  решает агент: поставить по `fit`, взять другое место или спросить хозяина. Обрезанный чертёж
  ставится только с `partial:true` — по прямому согласию хозяина (тогда клетки идут в `skipped` с
  `reason:"liquid"`). Вода с отсыпкой живьём не проверена (в тестовом сейве воды нет).
`"superforced"` агент выбирает только по прямой просьбе хозяина или
после `dry_run`, показав ему, что будет снесено (`detail.to_remove:[{name,pos}]` ≤ 20, `to_remove_total`).
Помеченное к сносу в области чертежа помощник разбирает сам (как `deconstruct`) **до** стройки,
плитки кладёт до построек. **Пометки, которые поставила сама задача**, она снимает при `failed`,
`cancel` и `stuck` (`cancel_deconstruction`): иначе дроны хозяина снесут помеченное без замены.
Список `to_remove` в `dry_run` для `superforced` — оценка (движок решает при постановке).
Уточнения v1: `direction` — только 0/4/8/12 (иначе `bad_args`); чертёж ≤ 1000 сущностей, ≤ 4000 плиток и сторона ≤ 128
(`limit`); чертёж только из плиток допустим; уже стоящая такая же постройка — `skipped` с `reason:"exists"`; **плитки** (отсыпка, бетон, фундамент) ставятся призраками плиток и строятся **раньше**
сущностей (иначе постройки на воде не встанут); `tiles_skipped` — сколько плиток поставить нельзя; `import_stack` = -1 (часть сущностей
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
принадлежит задаче и возвращается в `stop`. **Призраки плиток** (`tile-ghost`) строятся так же, как
призраки сущностей (предмет плитки из инвентаря, `revive`), и всегда первыми; сущность, чей призрак
ждёт плитку под собой, не считается `blocked`, пока плитка не построена. Сущности своей силы и
`neutral`, **помеченные к сносу** (`to_be_deconstructed`) и мешающие призраку области, задача разбирает
сама перед стройкой (игрок поставил чертёж с Shift / Ctrl+Shift); остальные помеченные не трогает
(`removed` — сколько разобрала, `not_removed` — сколько не смогла). Причины в `blocked`: `obstacle`
(мешает непомеченное), `tile` (нет плитки под призраком), `liquid` (под призраком плитка без опоры и без подложки).
Режим `robots` с настоящими дронами живьём не проверен (финал с игроком).

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

**`plan_mining`** — разметка рудного пятна призраками по алгоритму мода Mining Patch Planner (MIT,
автор rimbas; код раскладок берётся из мода с сохранением лицензии — `scripts/vendor/mpp/`, а не
пишется заново). Сам мод MPP вызвать нельзя: он работает только от рамки в руках игрока.
- Пятно: `area` либо `near` (всё связное пятно руды `resource` вокруг точки); итоговая область с
  полями ≤ 128×128, иначе `limit` (размечать частями через `area`); только открытые чанки
  (`not_charted`). `near` берёт пятно целиком, даже если `resources` показал его обрезанным.
- `layout` — режимы MPP: `simple`, `compact`, `super_compact`, `sparse`, `logistics`,
  `compact_logistics`, `sparse_logistics`; `direction` — куда выходит лента; `miner`, `belt`, `pole`,
  `pipe` — имена построек; по умолчанию — лучшее из **открытого исследованиями** (склады не
  учитываются: что выбрано, видно в `chosen`, а хватает ли предметов — агент сверяет `need` со `stock`
  и при нехватке задаёт имена сам). `options` — плоский объект флагов MPP: `lamps`, `coverage`,
  `landfill`, `avoid_water`, `avoid_cliffs`, `deconstruct`, `force_pipes`, `belt_merge`, `chest`;
  неизвестный флаг → `bad_args`. `avoid_water` (по умолчанию **true**) означает любую плитку без опоры
  (PROTOCOL §6.12): буры и ленты на неё не ставятся. Модули в буры в v1 не кладутся.
- Итог — **призраки силы хозяина** (то же, что сделал бы игрок рамкой MPP) и список нужных предметов
  `need`; стройка — отдельно, `build_ghosts` по `area`. `dry_run=true` — только посчитать (`ghosts`,
  `need`), ничего не ставить. Призраки ставятся с проверкой `manual_ghost` (PROTOCOL §6.5).
- Ошибки: руды нет → `not_found`; раскладка не подходит буру/руде (например `super_compact` для
  большого бура, или сундук для `logistics` не исследован) → `bad_args` с текстом от MPP; пятно больше
  лимита → `limit`; ни один призрак не встал (например, участок уже размечен) → `cannot_place`.
- `warnings`: `marked_for_deconstruction:N` (деревья и камни помечены к сносу — их уберёт `build_ghosts`),
  `on_liquid:N` (клеток пятна под жидкостью, пропущены), `narrow_access` / `enclosed` (по операции
  `access`, STATE.md: у участка узкий выход или его нет; разметка при этом **ставится**, решение —
  за агентом и хозяином), `access_side:<сторона>` — с какой стороны широкий выход (туда и вести ленту,
  если `direction` не задан явно хозяином).
- Живьём проверены `simple`, `compact`, `super_compact`, `sparse`; три `logistics`-режима, трубы, лампы
  и буры 5×5 — только юнит-тестами.

**`plan_belt`** — прокладка конвейера призраками от точки до точки с обходом препятствий (поток N).
Нужна, чтобы добыча не заканчивалась лентой в никуда: у MPP свой «планировщик лент» умеет только
прямые и углы без обхода и подземных, не дальше 100 клеток.
- `from` — клетка начала (конец существующей ленты или выход разметки) либо `"patch"`: взять выходы
  последней разметки `plan_mining` этого помощника (сведение нескольких лент в пачку — как в MPP);
  `to` — клетка конца (например, у ленты или сундука базы). Обе — в открытых чанках, расстояние
  по прямой ≤ 512 клеток (`limit`).
- Поиск пути — A* по клеткам с ценой поворотов, в несколько тиков (бюджет работы; исчерпан →
  `failed{path_failed}` с `detail.reached` — докуда дошёл). Основа кода — маршрутизатор из мода
  Wuastbude Belt & Pipe Router (MIT, с сохранением лицензии в `scripts/vendor/`), если он подойдёт под
  2.0.77 и отделяется от рук игрока; иначе свой A*. Auto Belt (GPLv3) — только как идея, код не брать.
- Правила мира — из игры (PROTOCOL §6.12): клетка годна, если там можно поставить ленту
  (`can_place_entity`, проверка `manual_ghost`); плитки без опоры обходятся; подземный участок
  разрешён, только если ни одна клетка под ним не запрещена `underground_collision_mask` (под лавой
  нельзя), длина — `max_distance` прототипа. `underground`: `"auto"` — подземные только через помехи
  (чужие ленты, трубы, постройки), `"never"`, `"prefer"`.
- Свои постройки и чужие ленты не сносит и не помечает; деревья и камни на пути помечает к сносу
  (их уберёт `build_ghosts`).
- Итог — призраки силы хозяина и `need`; стройка — отдельным `build_ghosts` по `area` (если длинная
  лента не влезает в 128 — `areas:[...]` кусками). `dry_run` — только посчитать.
- `warnings`: `long_detour` (путь длиннее прямой больше чем вдвое), `narrow` (проходит через место
  шириной 1–2 клетки), `near_enemy` (ближе 32 клеток к видимому врагу).

Прогресс долгих задач — шумное `job_progress{job, done, total}` не чаще раза в 5 с.

## Уточнения ревизии 3.4 (по волне 4)
**`build_blueprint`**
- `mirror?:bool=false` — поставить зеркально (то, что вернул `fit.mirror`). Чертежи с рельсами,
  станциями и баками не зеркалятся (`bad_args`); `rotate:true` для них перебирает только повороты.
- Сдвиг не найден → `detail.fit = null`; служебные поля `fit_checked:int` (сколько мест проверено) и
  `fit_limit:true` (поиск оборван бюджетом работы).
- Режим `normal` и клетка на плитке без опоры (решение автора 13.10): как в `forced` — чертёж не
  ставится, `failed{cannot_place}` с `on_liquid`, `liquids` и поиском сдвига `fit`. Подложку `normal`
  не ставит никогда, поэтому для него любая плитка без опоры (и вода) — «без возможной подложки».
  Обрезанный чертёж — только `partial:true` с согласия хозяина, в любом режиме.
- Плитки самого чертежа (бетон, отсыпка) на клетке без опоры считаются клетками без опоры.
- «Подложка доступна» = предмет подложки есть у помощника или в логистической сети силы **и** рецепт
  или предмет открыт. Оценка оптимистична (хватает одной штуки на весь чертёж): нехватка всплывёт в
  `need` и в `build_ghosts{no_items}`.
- `detail.tiles` — число. У `build_ghosts`: `not_removed` — число, список — `not_removed_list` (≤ 20).
- Свои пометки к сносу задача снимает при `failed`, `cancel` и `stuck`; число снятых — `detail.unmarked`.
  После `failed{no_items}` призраки остаются, пометки сняты — повторный `build_ghosts` поставит их снова.
- `pickup` трупа: цель `{name:"character-corpse", pos}`, поиск по типу в радиусе 3 клеток от `pos`.

**`plan_mining`**
- `avoid_water` по умолчанию `true`; явное `landfill:true` без `avoid_water` его выключает. «Плитка без
  опоры» определяется по маске бура. `direction` без умолчания в таблице: по умолчанию — сторона
  лучшего выхода (`access`), `north` только на открытом со всех сторон месте.
- `access_side:<сторона>` — сторона лучшего выхода (даже `medium`/`narrow`); не пишется, если участок
  открыт со всех сторон. `limit` и `cannot_place` приходят до первого призрака. Раскладка считается
  дважды (сухой прогон и настоящий) — это известная цена, не ошибка.

**`plan_belt`**
- `start_direction`: `"north"│"east"│"south"│"west"`. Клетки `from` и `to`: свободная получает ленту,
  занятая — нет (лента стыкуется с тем, что там стоит). При `from:"patch"` лента начинается от последней
  ленты разметки; эта клетка в `ghosts` не входит.
- Ответ сверх таблицы: `lanes` (сколько лент дошло), `chosen:{belt, underground?}`, `areas` (куски
  ≤ 128, только если `area` больше), `path_total` (если углов больше 40), `skipped`, `merged`,
  `dry_run`. `length`, `turns`, `path` — по первой ленте; `undergrounds` — число пар по всем лентам.
- `failed{path_failed}`: `detail:{reached, left, expanded, lane, reason:"unreachable"│"budget"}`.
  На мелком замкнутом острове возможен `budget` вместо `unreachable` — агент трактует оба одинаково.
- `warnings` сверх списка: `not_bundled` (пачка не сложилась, ленты найдены по одной),
  `unmerged_outputs:N`, `marked_for_deconstruction:N`, `skipped:N`, `not_researched:<имя>`
  (`underground:"prefer"` с неисследованным подземным ставит призраки с этим предупреждением).
- `long_detour` сравнивает с манхэттенским расстоянием. В режиме `auto` подземный ставится только
  вплотную к помехе и только исследованный. Призраки и ленты на пути — помеха; вторая лента той же
  задачи клетки первой не занимает.
- `lanes > 1` от точки: пачка вдоль пути; не сложилась — ленты по одной справа от первой; занятая
  клетка справа от цели → `cannot_place`.
- Рамка поиска: охват концов + 48 + дальность/4 клеток; бюджет 4×(20000 + 100×дальность) раскрытий;
  задача дольше 2 минут → `failed{path_failed, reason:"budget"}`.
- Подземные под плитками: PROTOCOL §6.12 (маски из стадии данных, иначе осторожное правило).

## Уточнения ревизии 3.5
**`plan_belt`: перекладка остатка (`from:"resume"`)**
Зачем: лента размечена издалека по карте; помощник дошёл, а впереди то, чего на карте не было (или
призрак оказался невыполним). Агент не бросает задачу, а перекладывает остаток.
- `from:"resume"` — взять последний план этого помощника (`storage.belt_last`): та же цель `to`, та же
  лента и число лент (аргументы `to`, `belt`, `lanes` можно не передавать; переданные должны совпасть,
  иначе `bad_args`). Плана нет, он на другой поверхности или не запомнен → `bad_args`.
- Что делает: по каждой ленте плана находит последнюю клетку, где уже стоит настоящая лента (построена),
  — это новое начало (ничего не построено — прежнее начало); все **свои ещё не построенные призраки**
  этого плана убирает (только призраки лент и подземных на клетках плана, силы хозяина; чужие призраки и
  постройки не трогает; пометки к сносу, поставленные планом на убранном участке, снимает); затем
  ищет путь заново по обычным правилам — уже с тем, что видно сейчас.
- Ответ — как у обычного `plan_belt`, плюс `resumed:{built:int (клеток уже построено), removed:int
  (убрано призраков)}`. `dry_run:true` ничего не убирает и не ставит. Путь не найден →
  `failed{path_failed}`; старые призраки при этом уже убраны (иначе дроны достроят ленту в тупик),
  в `detail.removed` — сколько.
- Новое предупреждение у любого `plan_belt`: `unseen:N` — N клеток пути лежат в открытых чанках без
  текущего обзора (`force.is_chunk_visible` = false): план там сделан «по карте», на подходе возможны
  сюрпризы.
- Отказ по времени: `detail:{reason:"budget", expanded, lane}` (`reached` и `left` есть только у отказа
  поиска). Призраки лент, уже поставленные этой задачей до отказа, она убирает сама (`detail.removed`).

**`build_ghosts` над лентой**: отдельного режима нет. Признак «пора перекладывать» для агента —
`blocked_total > 0` у призраков ленты, `job_failed`, либо сработавший рефлекс `flee` во время стройки.

**`build_blueprint`**
- На уровне мода поля `fit` нет, когда сдвиг не найден (в JSON из Lua нет null): признак — есть
  `fit_checked` и нет `fit`; `fit:null` дописывает сервер (в `partner_wait` и в `admin_events`).
  `fit_checked` есть и при `search:0` (значение 0).
- `detail.unmarked` есть, только если задача дошла до постановки чертежа (тогда и при 0).

### `plan_belt{from:"resume"}` — как вышло в коде (поток R)
- «Построенная часть» ленты = непрерывный ряд построенных клеток от начала; построенное дальше разрыва
  остаётся помехой, предупреждение `built_apart:N`.
- Подземная пара с построенным входом: призрак выхода есть — пара достраивается, путь идёт от выхода;
  нет — путь от клетки перед парой, предупреждение `dangling_underground:N`.
- Планировщик построенную ленту не трогает: если новый путь должен уйти вбок прямо от неё, в ответе
  `resumed.rotate:[{pos, direction}]` и предупреждение `rotate_needed:N` — агент поворачивает её сам
  действием `rotate` (решение автора 14.10) и называет клетку хозяину.
- **`rotate`** — повернуть постройку своей силы, как клавишей R: помощник подходит на `reach_distance`,
  цель должна поддерживать поворот (`supports_direction`, `rotatable`). Чужая сила и нейтральные —
  `bad_args`/`not_found`; игра не дала повернуть — `failed{cannot_place}`; уже смотрит туда — `done`.
- `detail.removed` — старые призраки плюс поставленные этой задачей; есть у любого отказа после старта.
  Нечего достраивать → `job_done` с `ghosts:0` без `area`. У `resume` можно передать `underground`.
- `unseen:N` считается по `force.is_chunk_visible`; на сервере без игроков почти весь путь будет `unseen`
  (открытый вопрос: учитывать ли радиус обзора тела из PROTOCOL §6.7).
- Отдельного инструмента `partner_plan_belt` нет: действие идёт через `partner_act` (MCP.md, уточнения
  3.5 читать так же).

## Уточнения ревизии 3.9
- **`mine{item, count, near?}`** — «набери `count` этого предмета» (живая игра 14.10: вольфрам из камней —
  агент копал камень за камнем и после каждого стоял, пока думал). Источники — всё, что рукой даёт
  предмет: сущности типов `simple-entity`, `tree`, `fish` силы `neutral` и руда, которую можно копать
  руками (не `required_fluid`, категория руды есть у персонажа). Что копается и что даёт — из
  прототипов игры (`mineable_properties.products`: `amount` или среднее `amount_min`/`amount_max`, с
  `probability`). Мод сам идёт от источника к источнику без остановок, выбирая **выгодный, а не
  ближний**: ожидаемый выход предмета / (время пути + время добычи). Радиус поиска — 64 от `near`
  (или от места старта), только открытые чанки. Готово — предмет вырос на `count`; источники
  кончились — `failed{not_found}` с `detail.mined`. `mined` — весь прирост инвентаря (камень даёт и
  попутное). Неизвестный предмет или ничего рукой его не даёт — `bad_args`. Свои постройки `item` не
  разбирает. Ровно одно из `target`, `resource`, `item`.

## Уточнения ревизии 3.10
- **`craft{wait:false}`** — как у игрока: крафт брошен в очередь крафта персонажа, задача сразу
  `done{queued, crafts}`, и очередь задач идёт дальше (ходьба, добыча, стройка — параллельно с крафтом).
  Готовность — громкое событие `craft_done` (EVENTS.md). Отмена задач (`cancel`, `replace`) фоновый
  крафт не снимает: он уже в очереди крафта персонажа. По умолчанию `wait:true` — задача ждёт продукта.

## Уточнения ревизии 3.11
- **Подход с дальней от врага стороны.** Враг (сила `enemy`, опасные типы как у `flee`) ближе 40 клеток
  к цели подхода вида `reach` (`insert`, `extract`, `collect`, разбор своей постройки) — помощник идёт к
  точке за целью, если смотреть от врага, на той же дистанции, и «на месте» засчитывается, только когда
  тело в секторе ±45° за целью. Свободного места там нет или пути туда нет — обычный подход.
