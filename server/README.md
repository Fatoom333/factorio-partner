# factorio_partner — MCP-сервер

Контракт — [docs/MCP.md](../docs/MCP.md), протокол — [docs/PROTOCOL.md](../docs/PROTOCOL.md).

| файл | что |
|---|---|
| `rcon.py` | RCON на `factorio-rcon-py` (UTF-8 с заменой, предел длины пакета); шлёт **только** `/partner <JSON>` |
| `bridge.py` | конверт v1, два соединения `cmd`/`poll`, повтор тем же `id` (3 попытки), `game_paused`, `game_reloaded` |
| `validate.py` | белые списки `do` и полей (ACTIONS.md, включая `plan_belt` и `search`/`rotate`/`partial` у `build_blueprint`), лимиты |
| `core.py` | `op_*`: ключ помощника, логи, курсоры событий и ожидание, `repeated_failure`, загрузка чертежа через `blob_put`; `op_supply` — ответ мода отдаётся как есть, не влез в лимит ответа — `response too large` с подсказкой уменьшить `depth`; `op_lookup` — так же, подсказка — уменьшить `limit`, подсказки имён из текста `not_found` — ещё и в `detail.suggest` |
| `brief.py` | `partner_brief`: короткие правила честности (полные — в промпте агента `.claude/agents/partner.md`) + `notes.md` профиля forge + `FP_HOME/style.md` |
| `server.py` | инструменты MCP (FastMCP, stdio), `--admin` — служебные; `partner_supply` — «что из чего и где это взять» (`item`, `count` 1..10000, `depth` 1..5); `partner_lookup` — справка как в Факториопедии (`name`, `kind` из пяти видов, `limit` 1..50) |
| `cli.py` | JSON из stdin → JSON в stdout теми же `op_*`; флаги запуска `--helpers`, `--body` |
| `forge.py` | `partner_plan` и заметки профиля; старый forge без нужных команд → `forge_too_old`, его сырой вывод агенту не уходит |

## Запуск
```powershell
python -m venv $env:TEMP\fp-venv
& $env:TEMP\fp-venv\Scripts\python -m pip install -e "server[dev]"
$env:FP_RCON_PORT = "27015"; $env:FP_RCON_PASSWORD_FILE = "<папка вне репозитория>\rcon.pw"
& $env:TEMP\fp-venv\Scripts\python -m factorio_partner.server          # MCP по stdio
'{"tool":"admin_hello"}' | & $env:TEMP\fp-venv\Scripts\python -m factorio_partner.cli --admin
```
Ключи помощников — `FP_HOME/helpers.json` (`{"h1": "<32+ символа>"}`), по умолчанию
`FP_HOME=%LOCALAPPDATA%\factorio-partner`. Логи — `FP_HOME/logs/`.

## Запуск напарника: сколько помощников и какое тело
Скрипт запуска спрашивает игрока «сколько помощников?» и передаёт ответ моду (PROTOCOL §4
`helper_limit`, по умолчанию помощник один). Флаги запуска `cli.py` ничего не читают из stdin:
```powershell
$cli = "$env:TEMP\fp-venv\Scripts\python"
& $cli -m factorio_partner.cli --helpers 2                                   # helper_limit {max: 2}
& $cli -m factorio_partner.cli --helpers 2 --body character --helper h1 --helper h2   # и тела: helper_spawn
& $cli -m factorio_partner.cli --body player --helper h1 --player Second     # тело — персонаж второго клиента
```
- `--helpers N` — 1..16; ниже числа уже живых мод не опустит (`limit`).
- `--body character` (по умолчанию у мода) — тело без игрока рядом с хозяином (`helper_spawn`).
- `--body player` — тело подключённого второго клиента игры: `helper_attach {player}`, по одному
  `--player` на каждый `--helper` (PROTOCOL §7 «Два вида тела»).
- Первый отказ мода останавливает остальные шаги; в ответе `done` — что уже сделано.
- То же для оркестра через MCP с `--admin`: `admin_limit(max)`, `admin_attach(helper, player)`.
- `agents/launch.py` (ключи, тела, конфигурация MCP для агентов) ходит в мод теми же функциями
  `Core.admin_*`, а не мимо них.

## Тесты
```powershell
cd server; python -m pytest -q
```
Фейковый RCON-сервер — `tests/fake_rcon.py` (терять ответ, задержка, вразнобой, мусор, битый UTF-8).
