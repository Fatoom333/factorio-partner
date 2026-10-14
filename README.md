# factorio-partner

Claude играет вторым персонажем в твоём сейве Factorio 2.0 (Space Age): ходит, добывает,
крафтит и строит **по честным правилам игры**, получает поручения («поставь добычу на этой
руде») и работает в живом времени, пока ты играешь.

- `mod/factorio-partner/` — мод (Lua): тело помощника, очередь задач, события.
- `server/` — MCP-сервер (Python): мост RCON ↔ Claude.
- `agents/` — агентский слой: промпты, тип агента, запуск.
- `tools/pc/` — тестовый стенд на ПК (сервер без окна на копии сейва).
- `docs/` — контракты: [PROTOCOL](docs/PROTOCOL.md), [ACTIONS](docs/ACTIONS.md),
  [EVENTS](docs/EVENTS.md), [STATE](docs/STATE.md), [MCP](docs/MCP.md),
  [TESTING](docs/TESTING.md), [PLAN](docs/PLAN.md).
- `research/` — исследование и проверки в игре (2026-10-06/08).

Связь — только команды мода по RCON (`/partner <JSON>`): достижения остаются включёнными.

## Статус
В разработке, не готов к игре. Готовы ядро мода, восприятие (карта, руда, склады, призраки,
производство), движение, руки (добыча, крафт, перенос) и MCP-сервер; впереди стройка, рефлексы
и агентский слой. Подробно — [docs/DECISIONS.md](docs/DECISIONS.md) и [docs/PLAN.md](docs/PLAN.md).

## Лицензия и благодарности
[MIT](LICENSE). Идеи взяты, код написан заново:
- [Rate Calculator](https://github.com/raiguard/RateCalculator) (MIT) — расчёт скоростей машин в `rates`;
- [Mining Patch Planner](https://mods.factorio.com/mod/mining-patch-planner) (MIT) — раскладка буров;
- [Wuastbude Belt & Pipe Router](https://mods.factorio.com/mod/wuastbude-router) (MIT) — прокладка лент в `plan_belt`;
- [Factory Search](https://github.com/tburrows13/FactorySearch) (MIT) — поиск по базе в `find`;
- [linsyking/factorio-mcp](https://github.com/linsyking/factorio-mcp) и
  [Factorio Learning Environment](https://github.com/JackHopkins/factorio-learning-environment) — образцы
  связи агента с игрой.
