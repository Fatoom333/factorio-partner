# Протокол мод ↔ сервер (v1)

Главный контракт проекта. Мод `factorio-partner` (Lua, Factorio 2.0.77, Space Age) и
MCP-сервер `factorio_partner` (Python) общаются **только** так, как описано здесь.
Связанные контракты: [ACTIONS.md](ACTIONS.md), [EVENTS.md](EVENTS.md), [STATE.md](STATE.md),
[MCP.md](MCP.md), [TESTING.md](TESTING.md), [PLAN.md](PLAN.md). Менять контракты может только
координатор (главная сессия); потоку нужна правка — пишет её в отчёт `contract_issues`.
Ревизия 2: после ревью-панели 2026-10-08 (3 ревьюера Fable).
Ревизия 3.2 (2026-10-13): по `contract_issues` волны 2b (стройка, рефлексы).
Ревизия 3.1 (2026-10-09): по `contract_issues` волны 2a.
Ревизия 3 (2026-10-08): по `contract_issues` волны 1 и живым замерам ([research/live-e-2026-10-08.md](../research/live-e-2026-10-08.md)).

## 1. Транспорт
- RCON на `127.0.0.1` (хост мультиплеера из меню: `local-rcon-socket` /
  `local-rcon-password`; выделенный сервер: `--rcon-bind` / `--rcon-password`).
- Каждый вызов — **команда мода** `/partner <JSON>`. Никогда `/c`, `/sc`,
  `/silent-command`: они навсегда отключают достижения. Команды мода по RCON достижения
  не трогают — проверено 2026-10-08 ([research/achievements-2026-10-08.md](../research/achievements-2026-10-08.md)).
- Ответ — ровно одна строка JSON через `rcon.print`. Больше мод в RCON ничего не печатает.
- `/partner` из чата игрока (`cmd.player_index ~= nil`) отклоняется: ответ
  `game.get_player(cmd.player_index).print("[partner] только для RCON")`, в RCON — ничего.
- JSON: `helpers.json_to_table` (вернул `nil` → `bad_request`) и `helpers.table_to_json`.
  Правила сериализации ответа:
  - в `data`/`detail` только числа, строки, bool и таблицы из них — **никаких LuaEntity/LuaObject**
    (вместо них `unit_number`, `name`, `pos`);
  - без таблиц со смешанными ключами;
  - пустая таблица уходит как `{}`, сервер считает `{}` и `[]` одинаковыми;
  - координаты округляются до 0.1.

## 2. Конверт
Запрос:
```json
{"v": 1, "id": "r-000123", "op": "act", "helper": "h1", "args": {"do": "walk", "args": {"to": {"x": 10, "y": -4}}}}
```
- `v` — версия протокола (`1`); иная → `version_mismatch`.
- `id` — 1–40 символов `[A-Za-z0-9_.:-]`, уникален **и между перезапусками сервера** (кольцо
  `recent` лежит в сейве): сервер делает `s` + 8 случайных hex + `-` + счётчик.
- `op` — из §4. `helper` — `^[a-z0-9_-]{1,16}$`, обязателен для операций «h».
- `args` — объект по схеме операции.
- Других полей в конверте нет: лишнее поле (например, ключ помощника) → `bad_request`.
  Ключ помощника живёт только на сервере (MCP.md) и в мод не уходит.

Ответ:
```json
{"v": 1, "id": "r-000123", "ok": true, "tick": 4109766, "seq": 812, "data": {"job": 57}}
{"v": 1, "id": "r-000124", "ok": false, "tick": 4109767, "seq": 812, "error": {"code": "not_reachable", "text": "..."}}
```
- `tick` — `game.tick`, `seq` — номер последнего события в буфере.
- **Идемпотентность:** мод хранит `storage.recent` — кольцо последних 128 ответов по `id`.
  Повторный запрос с тем же `id` возвращает сохранённый ответ и **не** исполняет операцию.
  Поэтому сервер после обрыва соединения может безопасно повторить любой запрос с тем же `id`.
  Исключения (чтобы не раздувать сейв): ответы **операций только для чтения** длиннее 16 КБ
  (`map`, `stock`, `state`…) не сохраняются — повтор исполнится заново (безопасно, `tick` новый);
  ответ `limit` на запрос > 8 КБ тоже не сохраняется. Ответы операций с последствиями
  (`act`, `cancel`, `helper_*`, `reflexes`, `vision`, `say`, `blob_put`) сохраняются всегда.
- Ответ ≤ 200 000 байт (RCON 2.0.77 отдаёт 300 КБ целиком — проверено 06.10); больше →
  `too_large`. Операции, которые могут вырасти, ограничены аргументами (радиус, `limit`, `top`).
- Размер **запроса** (параметр команды) ≤ 8 КБ, больше → `limit` (с `id`, если он разбирается).
  RCON сам пропускает и 1 МБ (замер 08.10), так что 8 КБ — наш выбор: большое (чертежи) — только
  частями через `blob_put` (§4).

## 3. Коды ошибок мода
| code | когда |
|---|---|
| `bad_request` | не JSON, нет `v`/`id`/`op`, неверные типы конверта |
| `version_mismatch` | `v` ≠ версии мода |
| `unknown_op` | нет такой операции |
| `bad_args` | аргументы не прошли схему (текст называет поле) |
| `no_helper` | помощника нет, либо он мёртв (`state ~= "alive"`) |
| `helper_exists` | `helper_spawn` при живом теле с этим id |
| `cooldown` | `helper_spawn` раньше, чем через 5 мин после `helper_remove`/смерти |
| `no_player` | нужен игрок онлайн с телом (`player.character`), а его нет / он на другой поверхности |
| `limit` | превышен лимит: помощников, очереди, размера запроса/blob, **верхняя граница** числового аргумента (радиус, `limit`, `top`, сторона `area`, число имён). Нижняя граница, неверный тип, лишнее поле → `bad_args` |
| `not_found` | цель не найдена или не своей/нейтральной силы |
| `not_reachable` | цель на другой поверхности (ходить между поверхностями нельзя) |
| `no_items` | не хватает предметов |
| `cannot_place` | постановка невозможна (`can_place_entity` = false) |
| `not_charted` | цель или область в неоткрытых чанках |
| `not_visible` | живые данные (враги, содержимое) запрошены вне видимых чанков |
| `reserved` | предметы/область заняты другим помощником |
| `path_failed` | поиск пути не нашёл маршрут |
| `stuck` | застрял, не смог выбраться, или задача без прогресса 60 с |
| `no_space` | в инвентаре помощника нет места (задача не может продолжать) |
| `cancelled` | задача отменена |
| `too_large` | ответ больше лимита |
| `internal` | ошибка Lua внутри мода (текст — без путей; не резать UTF-8 посреди символа) |

Задача (`act`) возвращает ошибку, только если не принята. Итог принятой задачи —
событие `job_done` / `job_failed` с кодом из этой таблицы ([EVENTS.md](EVENTS.md)).
Ошибки транспорта (`transport_timeout`, `game_paused`, `repeated_failure`) — у сервера, см. MCP.md.

## 4. Операции
«h» — нужен `helper`. Все операции синхронные; долгая работа — только `act` + очередь.
Позиция игрока везде — `player.physical_position` / `physical_surface` (в 2.0 у игрока есть
удалённый вид, `position` показывает камеру), игрок «есть», если `connected` и `character ~= nil`.

| op | h | args | data | владелец |
|---|---|---|---|---|
| `hello` | | `{}` | `{proto:1, mod, tick, seq, owner, players_online, players:[{index,name,online,surface,pos}], helpers:[id], module_errors:int}` (`helpers` — все не удалённые, живые и мёртвые; `module_errors` — сколько раз модуль или рефлекс упал под `pcall` с загрузки) | A |
| `helper_spawn` | h | `{}` | `{helper, unit_number, surface, pos}` — только рядом с игроком-хозяином (≤ 10 клеток, его поверхность) | A |
| `helper_remove` | h | `{}` | `{corpse?:pos}` — тело `die()`, вещи в трупе; для мёртвого помощника тоже можно (без трупа) | A |
| `helper_list` | | `{}` | `{helpers:[{id, state, surface, pos, job, cooldown_s, corpse?}]}` (у мёртвых `pos` — место смерти) | A |
| `act` | h | `{do, args, replace?=false}` | `{job, queued_before}` | A |
| `cancel` | h | `{job?│all?:true}` | `{cancelled:[job]}` | A |
| `jobs` | h | `{}` | `{active?:{job,do,since,progress,req}, queue:[{job,do,req}]}` (`req` — `id` запроса, поставившего задачу) | A |
| `events` | | `{since, helper?, limit?=100 (≤200)}` | `{seq, events:[...], lost}` — правила страниц в EVENTS.md | A |
| `reflexes` | h | `{set:[{type,...}]}` | `{set:[...]}` — полная замена | A (типы — H) |
| `vision` | h | `{on:bool}` | `{on}` | G |
| `say` | h | `{text}` | `{}` — сообщение в чат: `<helper>: текст` | A |
| `blob_put` | | `{blob, part, total, data}` | `{blob, received, total}` | A |
| `state` | h | `{}` | STATE.md | G |
| `map` | h? | `{center?│near?:"player", radius?=16 (≤32), types?, names?}` | STATE.md | G |
| `resources` | h? | `{center?│near?:"player", radius≤128, name?}` | STATE.md | G |
| `stock` | h? | `{center?│near?:"player", radius?=64 (≤128), items?, limit?=50 (≤200)}` | STATE.md | G |
| `ghosts` | h? | `{area?│radius?=64, center?│near?}` | STATE.md | G |
| `recipes` | h | `{filter?}` | STATE.md | G |
| `rates` | h? | `{scope?="surface"│"area", area?, surface?, period?="1m"│"10m"│"1h", items? (≤100), top?=20 (≤100)}` | STATE.md | L |

Правила:
- `act`: по умолчанию `replace=false` — задача встаёт в конец очереди. `replace=true` отменяет
  текущую и очередь (`job_failed{code:"cancelled"}` каждой). Очередь ≤ 32 ждущих задач (без
  активной). `act{do:"wait", replace:true}` → `bad_args` (`wait` никогда не заменяет очередь).
- Помощников: живых и ждущих возрождения ≤ `max_helpers` (иначе `limit`), записей в `storage.helpers` ≤ 32.
  `max_helpers` задаёт игрок при запуске напарника («сколько помощников?»): запускающий скрипт
  шлёт админскую операцию `helper_limit {max:1..16}` → `{max, alive}`; значение лежит в
  `storage.proto.max_helpers`, по умолчанию 1. Уменьшить ниже числа уже живых нельзя (`limit`).
- **h? без помощника** (операции чтения): поверхность, сила и центр берутся у хозяина
  (`physical_surface/position`); хозяина нет онлайн → `no_player`. `near:"player"` при хозяине на
  другой поверхности, чем помощник → `no_player`.
- `helper_spawn`: нет живого тела с этим id, прошло ≥ 5 мин после `helper_remove` / смерти
  (иначе `cooldown`), хозяин онлайн с телом (иначе `no_player`). Пустой инвентарь, без брони.
  Исключение (ревизия 3, для сервера без окна в тестах): хозяин есть в сейве, но **офлайн** —
  спавн рядом с его последней `physical_position` на `physical_surface` (тот же поиск места ≤ 10
  клеток); хозяина нет в сейве → `no_player`.
  Пара remove→spawn не может служить телепортом: перезарядка 5 мин и только рядом с хозяином.
- `blob_put`: `blob` — id `^[a-z0-9-]{1,32}$`, `data` ≤ 3500 байт, части 1..`total`, любой порядок,
  повтор части безопасен. `storage.blobs` — живут 10 мин с последней части, всего ≤ 1 МБ (`limit`).
  Используется `build_blueprint{blob}`.
- `say` и сообщения игроку: убрать `\n`, вырезать rich-text теги `[...]`, обрезать до 200 символов,
  всегда префикс `<helper>: ` (без квадратных скобок: имя помощника не должно совпасть с тегом
  rich-text вроде `[color]`).

## 5. Порядок, таймауты, повторы
- Сервер держит два RCON-соединения: `cmd` (операции агента) и `poll` (опрос `events`).
- На соединении — строго одна команда за раз, ответ сверяется по `id` (при игроке онлайн
  RCON-ответы могут приходить вразнобой — опыт linsyking). Ответ **без `id`** (не JSON, плохой `id`,
  запрос > 8 КБ) считается ответом на единственную команду в полёте и не повторяется.
- Таймаут ответа: `cmd` 10 с, `poll` 5 с. После таймаута сервер переподключается и
  **повторяет тот же `id`** (мод вернёт сохранённый ответ, действие не задвоится).
  Не удалось за 3 попытки → агенту `transport_timeout`.
- `tick` не растёт 3 с подряд → пауза (хост в меню/пауза). Изменяющие вызовы (`act`, `cancel`,
  `reflexes`, `say`, `blob_put`) → ошибка `game_paused` без отправки в мод; чтение (`state`, `map`,
  `resources`, `stock`, `ghosts`, `rates`, `recipes`, `wait`) → данные с полем `warning:"game_paused"`.
  Если пауза стала видна только в ответе на уже исполненный изменяющий вызов — результат с тем же
  `warning` (задача уже принята, скрывать её нельзя).
- `tick` уменьшился → игра перезагружена: событие `game_reloaded`, задачи считаются потерянными.

## 6. Честность (обязательно для всего мода)
1. **Без телепорта.** Перемещение — только `walking_state` / вождение. `teleport` в моде запрещён.
2. **Без предметов из воздуха.** Предметы — только из инвентаря помощника, из
   контейнеров/машин/земли/трупа в пределах досягаемости. `insert` в помощника — только как
   вторая половина честного переноса (остаток возвращается источнику).
3. **Досягаемость** — значения персонажа (`reach_distance`, `build_distance`,
   `resource_reach_distance`, `item_pickup_distance`) с бонусами силы. Все действия сами подходят
   к цели (ACTIONS.md «Подход»).
4. **Крафт** — только `begin_crafting` (движок тратит время и ингредиенты).
5. **Стройка руками:** `LuaControl.can_place_entity` (досягаемость + коллизии) →
   `surface.create_entity{..., force, raise_built=true, quality="normal"}` → списать 1 предмет
   `remove_item{name, count=1, quality="normal"}`; не списалось → `destroy()` и `no_items`.
   **Призрак руками:** тело в `build_distance` от призрака + `ghost_revive` = true →
   `ghost.revive{raise_revive=true}` (событие `script_raised_revive`) → списать предмет; не списалось →
   постройку убрать, призрак вернуть, `no_items`. `LuaControl.can_place_entity` здесь не зовётся
   (он считает сам призрак помехой).
   **Постановка призрака:** `surface.can_place_entity{name=<inner>, position, direction, force,
   build_check_type=defines.build_check_type.manual_ghost}`. **Призрак «заблокирован»**
   (ловушка 06.10: дроны висят вечно), если `surface.can_place_entity{name=ghost.ghost_name, ...,
   build_check_type=defines.build_check_type.ghost_revive}` = false.
   **Разбор** — `selected` + `mining_state` с ожиданием (движок тратит `mining_time`);
   `mine_entity` и `destroy`+`insert` запрещены.
6. **Чужое не трогаем.** Цели действий — только сущности силы помощника или `neutral`
   (ресурсы, деревья, камни); иначе `not_found`.
7. **Обзор, два уровня.** *Статичное* (тайлы, постройки своей силы, ресурсы, призраки) —
   в открытых чанках (`force.is_chunk_charted`). *Живое* (враги, содержимое контейнеров и машин,
   предметы на земле, прогресс машин) — только в видимых чанках (`force.is_chunk_visible`):
   рядом с игроком или радаром (`is_chunk_visible`), **либо в радиусе 32 клеток от живого тела
   помощника** (его собственные глаза; без игроков онлайн `is_chunk_visible` от `force.chart` не
   включается). Проверка одна на всех — `require("scripts.core.vis").visible(helper_id, surface, pos)`
   (поток A); G, C, F, H зовут её, а не `is_chunk_visible` напрямую. Иначе `not_visible`
   (для `map` — просто не показывать). Путь и цели `walk`/`approach` — только в открытых
   чанках (`not_charted`).
8. **Обзор помощника** — `force.chart(surface, area)` вокруг **живого** тела раз в 60 тиков,
   радиус 64 клетки (2 чанка, как у игрока; окно 5×5 чанков открывается кругом — углы не гарантированы). Порядок см. STATE.md «vision». Не идёт при
   смерти/удалении; `vision{on:false}` выключает обзор **для текущего тела** — после
   `helper_spawn` и возрождения обзор снова включён. `map{center}` никогда не вызывает `chart`.
   Помощник всегда в силе хозяина: без игроков онлайн `force.chart` открывает карту силе игрока,
   но **не** силе, созданной `game.create_force` (замер 08.10) — отдельных сил для помощников не заводить.
9. **Появление тела.** Только `helper_spawn` рядом с хозяином (пустой инвентарь) и
   возрождение после смерти: через 600 тиков у `force.get_spawn_position(surface)` той же
   поверхности, пустой инвентарь, событие `respawned` (как у игрока). Вещи остаются в трупе.
   Нет свободного места у точки появления — повтор каждые 5 с, до 12 раз, потом
   `reflex_done{type:"respawn", outcome:"failed"}` (помощник остаётся `dead`, его можно `helper_remove`).
   Мёртвый помощник, ждущий возрождения, **занимает место** в лимите `max_helpers` (§4): `helper_spawn`
   считает `alive` + `dead`, поэтому возрождение лимит не превышает.
10. **Никакого произвольного Lua** ни в моде, ни в сервере, ни в тестовом стенде.
11. **Качество (Space Age):** в v1 только `normal`. Все вызовы API с предметами и
    сущностями явно передают `quality="normal"`; предметы другого качества не видны и не трогаются.

## 7. Хозяин, помощники, хранилище
- **Хозяин** — игрок из настройки мода `partner-owner` (runtime-global, строка; пусто → игрок
  с индексом 1). Приказы агент принимает только от хозяина (EVENTS.md `player_said.owner`).
- `storage.helpers[id] = {entity, unit_number, state="alive"│"dead"│"removed", died_tick, died_pos,
  corpse_pos, removed_tick}`. Ядро ставит `state="removed"` **до** `die()`, поэтому рефлекс смерти
  такие события игнорирует. Исчезновение тела не по смерти — `script.register_on_object_destroyed`
  → событие `helper_lost`.
- **Смерть** (ядро, `on_entity_died`/`on_post_entity_died`): `state="dead"`, `died_tick`, `died_pos`,
  `corpse_pos`; задачи снимаются `job_failed{code:"no_helper"}` (`stop` зовётся при ещё живом теле).
  Обработчик ядра идёт **после** модулей: рефлекс H видит `state="alive"`. Событие `died` и
  возрождение — поток H; новое тело H отдаёт ядру через `require("scripts.core.registry").set_body(id,
  entity)`, сам в `storage.helpers` не пишет. При `helper_remove` и `replace` задачи — `cancelled`.
- Хука «помощник появился/удалён» для модулей нет: G и H смотрят `storage.helpers[id]`
  (`state`, `died_tick`, `unit_number`) сами (только чтение).
- Резерв (для нескольких помощников): `storage.reservations = {items={[helper]={[name]=count}},
  areas={[helper]=area}}`. `collect`/`extract` не берут чужой резерв, `build_*` держат область на
  время задачи (пересечение → `reserved`). В v1 с одним помощником реализация может быть пустой,
  но поля и код — есть. Область держат `build_ghosts`, `build_blueprint`, `deconstruct{area}`;
  `place` и `deconstruct{target}` чужой резерв только проверяют.
- Доступ модулей к ядру (кроме `ctx`): чтение — `jobs.active`, `jobs.queue_len`, `jobs.queue_of(helper)`,
  `events.query`; постановка задачи рефлексом — `jobs.op_act` (только H). В `storage.jobs` никто, кроме
  ядра, не пишет.
- Ключи верхнего уровня `storage`: `proto`, `helpers`, `jobs`, `events`, `recent`, `blobs`,
  `reservations`, `vision`, `reflexes`, `reflex_state`, `path_requests`. Модуль пишет только под своим ключом;
  миграции — `scripts/core/migrate.lua` (A).
- В `storage` можно хранить LuaEntity (API это позволяет), но рядом — `unit_number`, и перед
  использованием проверять `valid`. Функции в `storage` не класть.
