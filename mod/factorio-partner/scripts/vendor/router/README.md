# Решатель пути из Wuastbude Belt & Pipe Router

Источник: мод **Wuastbude Belt & Pipe Router** версии **0.19.3**, автор **wuast94**,
<https://git.wuastbude.de/Wuast94/wuastbude-pack> (папка `wuastbude-router`), коммит `ad626eff`.
Лицензия — MIT, текст в файле [LICENSE](LICENSE) (Copyright (c) 2026 wuast94).

Зачем: действие `plan_belt` (docs/ACTIONS.md) прокладывает ленту призраками в обход преград. Сам мод
вызвать нельзя: он работает от инструмента в руках игрока и заявлен под Factorio 2.1 (версии под 2.0 в
его истории нет). Но поиск пути у него отделён от игры — он и взят.

## Что взято

| Файл | Что это | Обращения к игре |
|---|---|---|
| `solver.lua` | A* по состояниям «клетка + направление»: цена поворотов, подземные участки, работа порциями (`solver.step(state, callbacks, budget)`), состояние — простая таблица | нет |
| `underground_network.lua` | учёт подземных конвейеров на линии: существующие пары и одиночные концы, с которыми новый участок спарился бы не так | были 2 — убраны |
| `entity_policy.lua` | «помеха, помеченная к сносу, не считается» (нужен `underground_network.lua`) | нет |

У каждого файла шапка: автор, версия, коммит, что изменено.

## Что не взято

`placement.lua`, `queue.lua`, `undo_group.lua`, `constraint_queue.lua`, `route_placement.lua`,
`belt_path.lua`, `belt_path_runtime.lua`, `occupancy.lua`, `frontier_cache.lua`, `collision.lua`,
`collision_mask.lua`, `profiles.lua`, `control.lua`, `data.lua`, настройки, горячие клавиши — всё, что
ставит постройки от имени игрока, ведёт его очередь и отмену или читает мир. Слой игры написан заново:
`scripts/lib/beltpath.lua` (занятость клеток, правила подземных участков, постановка призраков) и
`scripts/actions/plan_belt.lua` (задача по тикам, пачки лент, слияние выходов разметки).

## Правки во взятых файлах

Помечены в коде словом `[partner]`.

1. `underground_network.lua`: путь `require` (`scripts.vendor.router.entity_policy`); убраны функции
   `live_conflict` и `live_external_input` — они сами опрашивают поверхность.
2. `solver.lua` и `entity_policy.lua` — без правок.

## Сверка с API Factorio 2.0.77

- `solver.lua` игру не трогает. Его «быстрый путь» (прямая, угол, зигзаг до A*) хранит таблицы с
  ключами-`bool`; состояние поиска у нас лежит в `storage`, поэтому слой игры сразу выставляет
  `state.fast_path_attempted = true` — файл при этом не меняется.
- `underground_network.add_entities` читает у сущности `underground_belt_neighbour`. В 2.0.77 такого
  поля у `LuaEntity` нет (пара подземного конвейера — `LuaEntity.neighbours`). Поэтому сети отдаются не
  сущности, а простые таблицы с теми же полями — их собирает `beltpath.lua` (`proxy`).
- `underground_collision_mask` прототипа подземного конвейера в 2.0.77 во время игры не читается
  (свойство есть только на стадии данных). Как слой игры обходится без него — в шапке
  `scripts/lib/beltpath.lua` (`MASKS_MOD_DATA`).
