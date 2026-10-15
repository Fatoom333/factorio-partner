# Стенд живых тестов на ПК

Контракт — [docs/TESTING.md §3](../../docs/TESTING.md). Запуск на ноутбуке, из PowerShell (не Git Bash):

```powershell
powershell -File tools/pc/run-live.ps1 -Slot 1 -Scenario e_rcon_maxlen
powershell -File tools/pc/run-live.ps1 -Slot 1 -Scenario e_chart -Keep      # папку слота не удалять
powershell -File tools/pc/run-live.ps1 -Slot 2 -Scenario move_walk -Mods factorio-partner
```

Итог — `%TEMP%\fp-live\<N>-<время>\results-<N>.json` (+ `live-<N>.log`, `factorio-<N>.log`; у сценариев
через сервер ещё `server-<N>.log` и `calls-<N>.jsonl`).
Код выхода: 0 — сценарий ok, 1 — не ok, 2 — сбой стенда.

| Файл | Что делает |
|---|---|
| `run-live.ps1` | ноутбук: сборка → scp → развёртывание → сценарий → `/quit` → проверка журнала игры → забрать итоги → уборка; `-Local` — сценарий исполняется на ноутбуке через SSH-туннель к RCON слота |
| `remote/stand.ps1` | ПК: `deploy` / `run` / `stop` в `D:\Temp\fp-live-<N>` |
| `live_client.py` | единственная точка отправки стенда: только конверт → `/partner <JSON>`, отдельно `quit()`; RCON только `127.0.0.1`; `check-log` — журнал игры по `log_must_not_match` |
| `server_client.py` | сценарий через **настоящий пакет сервера** (`server/factorio_partner`: bridge + core, без stdio): `client.tool("act", ...)` = инструмент `partner_act` |
| `pack.py` | zip мода (`<name>_<version>/…`) и пакет стенда со `stand.json` и копией пакета сервера |
| `scenarios/<имя>.py` | `run(client) -> {"ok": bool, ...}`; `MODS = [...]` — какие наши моды включить (по умолчанию `factorio-partner`); `RUNNER = "server"` — идти через `server_client.py` |

**Сквозные сценарии `e2e_*`** (MCP-сервер с настоящим модом, «поставь добычу» тремя путями, настоящий
forge) и чек-лист финала с игроком — [docs/E2E.md](../../docs/E2E.md). Там же — как один раз завести
на ПК Python для пакета сервера и где задаются пути forge (в git их нет).

**Журнал игры.** Сценарий может вернуть `log_must_not_match` — regex или список regex. После остановки
сервера стенд читает вынесенный журнал, и если в нём есть такая строка (обычно
`[factorio-partner] … failed` — ошибка модуля или рефлекса под `pcall`), сценарий считается
проваленным: в `results` появляется `log_check` с совпавшими строками. Объявил проверку, а журнала
нет или regex кривой — тоже провал.

Слот N: папка `D:\Temp\fp-live-<N>`, RCON `127.0.0.1:27100+N`, игра `127.0.0.1:34200+N`.
Слот 0 — основной, слоты 1..9 — параллельные прогоны. Пароль RCON генерируется на ПК в `<слот>\rcon.pw`
(файл создаётся пустым, права — только владельцу, потом пишется пароль), в git и `results` не попадает.

**Журналы.** Factorio пишет свои аргументы, включая пароль RCON, в `factorio-current.log`
(строка `Program arguments`). Поэтому `stand.ps1` выносит журнал только через `Copy-RedactedLog`
(пароль → `<private>`), хвост при сбое печатает тоже вычищенным, а при `stop` перезаписывает
вычищенными и сами журналы в слоте (на случай `-Keep`). Не заменяйте это на `Copy-Item`/`Get-Content` —
тест `tests/test_stand_logs.py` это ловит.

**Известное ограничение.** У Factorio нет способа передать пароль RCON файлом, поэтому, пока сервер
работает, пароль виден в командной строке `factorio.exe` любому локальному процессу пользователя
(`Get-CimInstance Win32_Process`). Смягчение: пароль одноразовый (новый на каждый запуск), RCON слушает
только `127.0.0.1`, сервер живёт минуты и работает на копии сейва.

**Сейв.** По умолчанию — `Vulkan-Start-test.zip` (копия рабочего сейва игрока, `DEFAULTS` в `pack.py` и `-Save` в `run-live.ps1`); рабочий `Vulkan-Start.zip` стенд не берёт. Сервер работает на копии `data\saves\fp-live.zip` в папке слота и на `/quit` её
пересохраняет. Это должна быть именно копия (`Copy-Item`), а не жёсткая ссылка: со ссылкой
пересохранение испортило бы сейв игрока. (Моды — жёсткие ссылки: сервер их только читает.)

**Пути ПК.** По умолчанию — в `DEFAULTS` в `pack.py`. Если игра или Python на ПК переехали, создайте
`tools/pc/pc.local.json` (в git не идёт) с нужными ключами из `factorio_exe`, `factorio_data`,
`pc_python`, `save`, `server_python` (Python 3.11+ для пакета сервера), `forge`, `forge_home`,
`forge_profile` (forge на ПК — только здесь или в переменных окружения запуска `FP_FORGE`,
`FACTORIO_FORGE_HOME`, `FP_FORGE_PROFILE`); ключи командной строки `pack.py` сильнее файла.

**Ответы RCON.** `live_client.py` собирает ответ из одного RCON-пакета: Factorio 2.0.77 отдаёт
300 КБ одним пакетом (замер 06.10). Сценарий `e_rcon_maxlen` проверяет это заново (`e_big`, ответ
≈200 КБ, поле `big_reply`); пакеты больше 1 МБ клиент не читает.

Сценарию доступно: `client.call(op, args, helper)` → ответ-конверт (dict), `client.call_ok(...)` → `data`
или исключение, `client.poll(fn, timeout, interval)`, `client.sleep(s)`, `client.time_left()`.

Сценарий `e_chart` проверяет обзор на **силе игрока** и далёком сгенерированном неоткрытом чанке.
Операция мода `e_chart` имеет режимы `find` / `chart` / `check`; тело и тестовая сила не создаются.
Для силы из `create_force` обзор без игроков не работает (замер 08.10). Успех: чанк открылся и открыто не меньше 21 из 25 чанков окна 5x5 (радиус 64 даёт «круг» без углов).

Мод `partner-test` регистрирует свой тестовый `/partner` (операции `hello`, `e_*`) только когда
`factorio-partner` выключен. Сценарии `e_*` требуют его (`MODS = ["partner-test"]`).

У сценария через сервер клиент другой: `client.tool("state")`, `client.try_tool(...)`,
`client.admin("spawn", helper=...)` — и всё перечисленное выше для сверки с игрой в обход сервера.

Тесты стенда (без ПК): `python -m pytest tools/pc/tests -q` (нужны `pytest`, для тестов Lua — `lupa`).
Тесты сценариев через сервер (`test_e2e_server.py`) идут на настоящем `Core` и требуют зависимости
пакета сервера (`pip install -e "server[dev]"`); без них этот файл пропускается.
