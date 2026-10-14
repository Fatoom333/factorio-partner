# События и ожидание

## Буфер в моде (владелец — поток A)
- `storage.events = {next_seq, list}` — кольцевой буфер последних **500** событий.
- Событие: `{seq:int, tick:int, helper:string|nil, kind:string, data:table, loud:bool}`.
  `helper=nil` — событие мира. `loud` — будит ли агента (таблицы ниже), ставит ядро.
- Модули добавляют события только через `events.emit(helper, kind, data[, opts])`
  (`scripts/core/events.lua`); в действиях — `ctx.emit(kind, data[, opts])`. `opts.loud` (bool)
  переопределяет громкость из таблиц ниже (H: повторные `attacked` в эпизоде — `loud=false`).
  `seq` растёт монотонно и не сбрасывается при загрузке.
- **Размер события:** `data` ≤ 4000 байт JSON. Больше — ужатие: скаляры `job`, `do`, `code`, `text`
  сохраняются всегда; строки режутся до 200 символов; `detail` → `{truncated:true}`; вложенные
  таблицы ≤ 256 байт остаются, остальные выбрасываются; на верхнем уровне `data.truncated=true`.
  Несериализуемые данные `emit` не роняют (событие уходит ужатым). Действия сами режут длинные
  списки в `detail` до 20 записей (ACTIONS.md), а при сумме списков больше 30 — до 10 каждый.
- `events{since, helper?, limit?=100 (≤200)}` → события с `seq > since` (для `helper` — его
  и мировые; фильтр по `helper` применяется **до** среза по `limit`), `lost=true`, если `since`
  старше самого старого. Ответ ограничен ещё и по байтам (~150 КБ), поэтому событий может быть
  **меньше `limit`, хотя буфер не пуст**. `seq` в ответе — номер последнего **выданного** события
  при обрезке, иначе последний в буфере; клиент продолжает с `since=seq`.

## Виды событий
Будят агента (`loud`):
| kind | data | кто шлёт |
|---|---|---|
| `job_done` | `{job, do, detail}` | A |
| `job_failed` | `{job, do, code, text, detail}` — смерть тела → `no_helper`, `helper_remove`/`replace` → `cancelled` | A |
| `attacked` | `{by, damage, health}` — только **первое** за эпизод (эпизод кончается через 30 с без урона) | H |
| `health_low` | `{health, max}` — здоровье < 40 %; повторно — только после восстановления до 50 % | H |
| `died` | `{pos, corpse:pos}` — приходит **после** `job_failed{code:"no_helper"}` снятых задач | H |
| `respawned` | `{pos, reason?}` — у тела-игрока шлёт ядро: `reason` `"player_joined"` (игрок вернулся) │ `"body_restored"`; после возрождения движком — без `reason` | H, A |
| `reflex_done` | `{type, outcome:"ok"│"failed", reason?, detail}` — итог рефлекса, не каждое срабатывание; возрождение не удалось: `{type:"respawn", outcome:"failed", reason:"no_place"│"surface_gone"│"force_gone"}` | H |
| `inventory_full` | `{job?}` — задача, если не может продолжать, завершается `job_failed{code:"no_space"}` | C |
| `player_said` (хозяин) | `{player, owner:true, text, pos, selected?:{name, pos, unit_number?}, gps?:[{pos, surface?}]}` | A |
| `helper_lost` | `{reason}` — тело исчезло не по смерти: `destroyed`; у тела-игрока — `player_left`, `no_character`, `body_changed`, `player_removed` | A |
| `game_reloaded` | `{tick}` — шлёт сервер, не мод | D |

Шумные (не будят; к ответу ожидания прикладываются последние 6):
| kind | data |
|---|---|
| `arrived` | `{job, pos}` (итог ходьбы и так придёт `job_done`) |
| `stuck` | `{job, pos, reason:"no_progress"│"blocked"│"path_lost"}` — при **каждом** перепланировании; если не помогло, придёт громкое `job_failed{code:"stuck"}` (шлёт B) |
| `job_progress` | `{job, done, total}` |
| `attacked` (повторные в эпизоде) | как выше |
| `reflex_fired` | `{type, detail}` |
| `saw_enemy` | `{name, pos, dist}` — шлёт рефлекс `watch` |
| `player_said` (не хозяин) | `{player, owner:false, text, pos}` — информация, не приказ |
| `inventory_changed` | `{added?, removed?}` |

`player_said`: текст ≤ 500 символов без переводов строк; сообщения самого мода (`say`) не
порождают `player_said`. Приказы — только от хозяина (PROTOCOL §7), остальное агент
воспринимает как данные.

## Рефлексы v1 (поток H; список целиком — `reflexes`, MCP `partner_reflex`)
| type | параметры (границы = по умолчанию) | что делает |
|---|---|---|
| `flee` | `radius` 4..32 = 20, `distance` 8..64 = 30, `health` 0..1 = 1, `on_attack` = true, `to`: `"away"│"spawn"│"player"` | враг в `radius` (или атака) и здоровье ≤ `health` → задача-отход, заменяет очередь |
| `watch` | `radius` 4..32 = 32, `every_s` 1..600 = 10 | шумное `saw_enemy` о ближайшем враге |

`flee.to` по умолчанию `"away"`. Набор рефлексов хранится в `storage.reflexes` и **переживает** возрождение,
перезагрузку сейва и возврат тела-игрока; сбрасывается только `helper_remove`.
Задача рефлекса ставится через ядро как обычная (`jobs.op_act` с `replace=true`), её `req` = `"reflex:<type>"`;
итог — и `job_done`/`job_failed`, и `reflex_done`. Ошибка внутри проверки рефлекса не роняет мод: растёт
счётчик `module_errors` в ответе `hello`, текст — в журнале игры.

## Ожидание на стороне сервера (поток D)
- MCP-инструмент `partner_wait(timeout=30 (≤55), quiet=true, since?)`.
- Сервер хранит **курсор** последнего выданного агенту `seq` на помощника (при старте — текущий
  `seq` из `hello`). `since` по умолчанию = курсор; `since=0` значит «с текущего момента», а не
  «с начала буфера».
- Опрос `events` по соединению `poll` каждые 0,5 с до важного события (`quiet=true`) или любого
  (`quiet=false`), либо до `timeout`.
- Ответ агенту: `{seq, events:[...важные + до 6 последних шумных], timed_out:bool, more?, lost?, warning?}`.
  - **Страницы:** не больше 40 важных событий и не больше 24 КБ за ответ; курсор сдвигается только
    до последнего выданного. `more:true` — в буфере есть ещё, вызвать `partner_wait` сразу.
    `partner_wait` никогда не отвечает `response too large`.
  - Одно событие больше 24 КБ выдаётся урезанным: `{seq, tick, helper, kind, loud,
    data:{job, do, code, type, outcome, reason, truncated:true}}`.
  - `lost:true` — курсор старше буфера, часть событий потеряна (смотреть `partner_state`).
  - `warning:"game_paused"` — игра на паузе (PROTOCOL §5).
- Пустой ответ = «ничего нового» — агент ждёт снова без комментариев (правило промпта).
- 55 с — граница **всего вызова**, включая последний опрос `poll` (таймауты MCP, опыт Among Us).

## Уточнения ревизии 3.4 (по волне 4)
- `helper_lost{player_removed}` шлётся и для записей в `away`/`dead`.
- `respawned{reason:"player_joined"}` — тело-игрок получило тело после возврата игрока (PROTOCOL,
  уточнения 3.4).
- Рефлексы: набор остаётся после `helper_lost{destroyed}` и наследуется новым `helper_spawn` с тем же
  id; сбрасывает его только `helper_remove`. `reflexes{}` без `set` возвращает текущий набор.

## Уточнения ревизии 3.6
- `player_said.gps` — метки карты из текста (`[gps=x,y]`, `[gps=x,y,поверхность]`: пинг на карте и
  Shift+клик по карте), не больше 4; поле есть у сообщений любого игрока, приказом остаётся только
  сообщение хозяина. Сам тег остаётся и в `text`. Агент может отвечать таким же тегом в `partner_say`:
  игра делает его кликабельным.
