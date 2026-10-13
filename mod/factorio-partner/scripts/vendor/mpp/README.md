# Код раскладок Mining Patch Planner

Источник: мод **Mining Patch Planner** версии **1.7.19** (последняя под Factorio 2.0),
автор **Rimbas**, <https://github.com/rimbas/mining-patch-planner>, коммит `95be67cf`.
Лицензия — MIT, текст в файле [LICENSE](LICENSE) (Copyright (c) 2021 Rimbas).

Зачем: действие `plan_mining` (docs/ACTIONS.md) размечает рудное пятно призраками так же, как это
сделал бы игрок рамкой MPP. Сам мод вызвать нельзя — он работает только от рамки в руках игрока,
поэтому алгоритмы раскладок взяты в исходниках, а всё, что связано с игроком, заменено.

## Что взято

| Файл | Что это |
|---|---|
| `layouts/base.lua`, `simple.lua`, `compact.lua`, `super_compact.lua`, `sparse.lua`, `logistics.lua`, `compact_logistics.lua`, `sparse_logistics.lua` | автоматы состояний семи раскладок |
| `layouts/common.lua` | эвристики, раскладка лент и труб |
| `mpp/grid_mt.lua`, `mpp/pole_grid_mt.lua` | сетка пятна и сетка столбов |
| `mpp/mpp_util.lua` | размеры буров, столбов, лент; повороты координат |
| `mpp/cliffs.lua`, `mpp/list.lua`, `mpp/global_extends.lua` | мелкие помощники |

У каждого файла сохранена шапка с автором, версией и ссылкой.

## Что не взято

Окно настроек (`gui/`), рамка выделения и её события (`control.lua`, `algorithm.lua`), подсказки
поверх карты (`mpp/render_util.lua`, `mpp/drawing.lua`, `mpp/color.lua`), планировщик лент в руках
игрока (`mpp/belt_planner.lua`), раскладки из чертежей (`layouts/blueprints*.lua`,
`mpp/blueprintmeta.lua`), настройки игрока и мода, миграции, раскладка `pipe`, списки `enums`,
`blacklist`, `compatibility` (Space Exploration и др.).

## Что написано заново (не код MPP)

- `mpp/builder.lua` — тот же интерфейс `create_entity_builder`, но призраки ставятся от **силы**
  хозяина, после проверки `can_place_entity{build_check_type = manual_ghost}`, всегда качества
  `normal`; режим `dry_run` (только счёт); вместо планировщика сноса игрока — пометка деревьев и
  камней; поставленные ленты запоминаются, чтобы адаптер нашёл концы выходных лент
  (`summary.outputs` → `storage.mining_last`, их читает `plan_belt`).
- `partner/adapter.lua` — собирает таблицу состояния MPP из аргументов действия (вместо игрока и его
  настроек), выбирает постройки по умолчанию из открытого исследованиями, шагает автомат, собирает итог.
- `partner/noop.lua` — пустышка на месте модулей отрисовки, которые не взяты.

## Правки во взятых файлах

Все помечены в коде словом `[partner]`.

1. `require("mpp.x")` / `require("layouts.x")` → `require("scripts.vendor.mpp....")`; модули
   отрисовки и планировщика лент → `partner/noop.lua`.
2. `mpp/list.lua`, `mpp/grid_mt.lua`, `mpp/pole_grid_mt.lua` — метатаблицы регистрируются через
   `script.register_metatable` (имена `fp_mpp_*`): состояние раскладки лежит в `storage` задачи и
   должно пережить сохранение. В оригинале метатаблицы сетки возвращает `script.on_load`, а он здесь
   принадлежит ядру мода.
3. `mpp/global_extends.lua` — добавлен `table.deepcopy` (в оригинале приходит из `util` игры).
4. `mpp/mpp_util.lua` — качество всегда `normal`; убраны функции окна, настроек игрока, чертежей и
   списки качеств; добавлена `mpp_util.report(state, message)` — сообщения, которые оригинал
   печатает игроку в чат, копятся в состоянии и становятся `warnings`.
5. `layouts/common.lua` — убраны отрисовка загрузки лент, выгрузка состояния в файл и выдача
   чертежа ленты в руки; бонус продуктивности берётся у силы, а не у игрока.
6. `layouts/base.lua` — убран снос призраков предыдущей разметки того же игрока (отмена).
7. `layouts/simple.lua` — плитки, на которых буру стоять нельзя, ищутся по правилам игры
   (`mpp_util.unsupported_tiles(state, area)`: маска столкновений плитки против маски выбранного бура;
   оригинал знает только слой воды). Имён плиток, слоёв и планет в коде нет — лава Вулкануса и планеты
   из модов работают без правок; `expensive_deconstruct` помечает только деревья и камни
   (`builder.mark_obstacles`); призраки отсыпки ставит `builder.create_tile_ghost`; `finish` без
   печати в чат и отрисовки.
8. `layouts/logistics.lua` — `finish` без печати в чат.

## Как обновить

Скопировать те же файлы новой версии, заменить пути `require`, повторить правки 2–8 (они короткие и
помечены), прогнать `python tools/run_lua_tests.py mining`. Версия для Factorio 2.1 (1.7.20+) сюда
не подходит, пока игра на 2.0.
