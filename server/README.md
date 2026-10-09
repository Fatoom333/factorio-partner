# factorio_partner — MCP-сервер (поток D)

Контракт — [docs/MCP.md](../docs/MCP.md), протокол — [docs/PROTOCOL.md](../docs/PROTOCOL.md).

| файл | что |
|---|---|
| `rcon.py` | RCON на `factorio-rcon-py` (UTF-8 с заменой, предел длины пакета); шлёт **только** `/partner <JSON>` |
| `bridge.py` | конверт v1, два соединения `cmd`/`poll`, повтор тем же `id` (3 попытки), `game_paused`, `game_reloaded` |
| `validate.py` | белые списки `do` и полей (ACTIONS.md), лимиты |
| `core.py` | `op_*`: ключ помощника, логи, курсоры событий и ожидание, `repeated_failure`, загрузка чертежа через `blob_put` |
| `brief.py` | `partner_brief`: правила + `notes.md` профиля forge + `FP_HOME/style.md` |
| `server.py` | инструменты MCP (FastMCP, stdio), `--admin` — служебные |
| `cli.py` | JSON из stdin → JSON в stdout теми же `op_*` |
| `forge.py` | поток I (`partner_plan`) |

## Запуск
```powershell
python -m venv $env:TEMP\fp-venv
& $env:TEMP\fp-venv\Scripts\python -m pip install -e "server[dev]"
$env:FP_RCON_PORT = "27015"; $env:FP_RCON_PASSWORD_FILE = "D:\Temp\partner-rcon\rcon.pw"
& $env:TEMP\fp-venv\Scripts\python -m factorio_partner.server          # MCP по stdio
'{"tool":"admin_hello"}' | & $env:TEMP\fp-venv\Scripts\python -m factorio_partner.cli --admin
```
Ключи помощников — `FP_HOME/helpers.json` (`{"h1": "<32+ символа>"}`), по умолчанию
`FP_HOME=%LOCALAPPDATA%\factorio-partner`. Логи — `FP_HOME/logs/`.

## Тесты
```powershell
cd server; python -m pytest -q
```
Фейковый RCON-сервер — `tests/fake_rcon.py` (терять ответ, задержка, вразнобой, мусор, битый UTF-8).
