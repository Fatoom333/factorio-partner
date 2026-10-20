"""Проверка агентского слоя без игры: формат агента, имена инструментов, вызовы в примерах.

    python agents/lint.py          # код выхода 0 — чисто, 1 — есть замечания

Сверяет с контрактами (docs/MCP.md, ACTIONS.md, EVENTS.md, PROTOCOL.md) и с сервером
(server/factorio_partner/server.py разбирается как текст через ``ast``, без импорта).
Вызовы инструментов в файлах агентов пишутся блоками::

    ```call
    partner_act {"do":"collect","args":{"items":{"transport-belt":120}}}
    ```

``helper`` и ``key`` в блоках не пишутся (агент добавляет их сам).
"""
from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENT_FILE = ROOT / ".claude" / "agents" / "partner.md"
# агенты ролей одного помощника (docs/MCP.md «Роли»): файл -> роль
ROLE_FILES = {"partner-voice.md": "voice", "partner-pilot.md": "pilot", "partner-strategist.md": "strategist"}
# модель агента роли (frontmatter): голос быстрый и дешёвый, пилот — sonnet или haiku (launch.py --pilot-model)
ROLE_MODELS = {"voice": {"haiku"}, "pilot": {"sonnet", "haiku"}, "strategist": {"sonnet"}}
# что обязано быть в правилах роли: поручения, ack, отказы сервера и права
_ROLE_REFUSALS = ("access denied", "transport_timeout", "game_paused", "repeated_failure", "not_allowed", "limit")
ROLE_WORDS = {
    "voice": ("partner_order", "said_seq", "auto_reply", "owner:true", "owner:false", "player_said",
              "owner_stop", "bad_args", "urgent", "large", "small", *_ROLE_REFUSALS),
    "pilot": ("partner_inbox", "ack", "order", "owner_said", "plan_done", "partner_plan", "owner_hold",
              "job_failed", "owner:true", "owner:false", "hold", "inbox", *_ROLE_REFUSALS),
    "strategist": ("partner_inbox", "not_allowed", "order"),
}
# без чего роль не делает свою работу: голос подаёт поручения, пилот и стратег снимают их из входящих
ROLE_NEEDS = {"voice": ("partner_order", "partner_say"), "pilot": ("partner_act", "partner_inbox"),
              "strategist": ("partner_inbox", "partner_plan")}
AGENTS_DIR = ROOT / "agents"
SERVER_FILE = ROOT / "server" / "factorio_partner" / "server.py"
DOCS = ROOT / "docs"

TOOL_PREFIX = "mcp__partner__"
# инструменты из docs/MCP.md, которые сервер ещё не отдаёт (если такие бывают).
# Сейчас пусто: всё, что есть в таблице MCP.md, сервер уже отдаёт.
PENDING_TOOLS: set[str] = set()
# инструменты только для режима нескольких ролей: одиночному агенту partner (ключ старого вида —
# пилот без голоса и стратега) они не нужны — поручений ему никто не кладёт
MULTI_ROLE_TOOLS = {"partner_order", "partner_inbox", "partner_ledger"}
# инструменты диспетчера (ключ host, главный чат), не агентов: ни один агент их не получает
HOST_TOOLS = {"partner_relay", "partner_rescale"}
# аргументы partner_plan описаны в MCP.md отдельным разделом, а не в таблице
PLAN_ARGS = {"task", "resource", "patch", "options"}
# MCP.md: для build_blueprint вместо blob можно plan; mirror — аргумент мода, которым применяется
# ответ `fit.mirror` (ACTIONS.md «Плитки без опоры»: fit = {anchor, shift, direction?, mirror?})
EXTRA_ACT_ARGS = {"build_blueprint": {"plan", "mirror"}}
SERVER_ERRORS = ("access denied", "transport_timeout", "game_paused", "repeated_failure",
                 "response too large")
LAYOUTS = ("simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics",
           "sparse_logistics")
# что обязано быть в промпте ; строка или набор вариантов
REQUIRED = (
    "owner:true", "owner:false", "partner_brief", "partner_state", "partner_map", "partner_find",
    "partner_stock", "partner_rates", "partner_wait", "partner_say", "collect", "timed_out",
    "flee", "watch", "module_errors", "superforced", "dry_run", "to_remove", "build_ghosts",
    "plan_mining", "partner_plan", "build_blueprint", "supported:false", "notes", "style",
    # жидкость и выходы с участка, поиск места для чертежа, лента до базы, заметки смены
    "partner_access", "narrow_access", "enclosed", "on_liquid", "fit", "rotate", "partial", "plan_belt",
    "areas", "need", "chosen", "forge_too_old", "только как факты", "без подтверждения хозяина",
    # стройка ленты встала — осмотреться, переложить остаток, не больше трёх раз подряд
    '"from":"resume"', "resumed", "unseen", "blocked_total", "трёх перекладок подряд",
    # большое поручение начинается с partner_supply; как читать его ответ
    "partner_supply", "summary.short", "stored", "producers", "makers", "recipe.hand", "resource",
    "not_researched", "no_source", "руками не подменяй",
    # справка как в Факториопедии — что это в игре и почему не открыто
    "partner_lookup", "unlocked_by", "missing", "suggest", "ничего не изучаешь",
)
# порядок шагов поручения «добыча с лентой» в примере
MINING_ORDER = ("partner_access", "plan_mining", "plan_belt", "collect", "build_ghosts")
# пример «поставь ещё литейных»: сначала спросить игру, потом идти и брать
SUPPLY_ORDER = ("partner_supply", "partner_say", "collect", "extract", "craft", "insert", "place")
# чем разведку источников в таком примере начинать нельзя — это делает partner_supply одним вызовом
SCOUT_TOOLS = ("partner_find", "partner_stock", "partner_recipes", "partner_resources")
_U = "U" + "sers"
PRIVATE_RE = re.compile(
    r"(?<![\w)\]*])[A-Za-z]:[\\/](?![\\/])\w"  # путь с буквой диска
    r"|[\\/]" + _U + r"[\\/]|[\\/]home[\\/]\w"  # домашние папки
    r"|\b(?!127\.0\.0\.1\b)(?:\d{1,3}\.){3}\d{1,3}\b")  # адреса, кроме локального
CONSOLE_RE = re.compile(r"""["'`]/(?:c|sc|silent-command|command)\b""")
CONSOLE_MD_RE = re.compile(r"`/(?:c|sc|silent-command|command)\b|^/(?:c|sc|silent-command|command)\s", re.M)
TEXT_SUFFIXES = {".md", ".py", ".js", ".json", ".txt"}


# ---------------------------------------------------------------- разбор контрактов
def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _table_rows(text: str, header_first: str) -> list[list[str]]:
    """Строки markdown-таблицы, первая ячейка заголовка которой равна ``header_first``."""
    rows: list[list[str]] = []
    inside = False
    for line in text.splitlines():
        if not line.lstrip().startswith("|"):
            if inside:
                break
            continue
        cells = _cells(line.replace("\\|", "│"))
        if not inside:
            inside = cells[0] == header_first
            continue
        if set(cells[0]) <= set("-: "):
            continue
        rows.append(cells)
    return rows


def _arg_names(cell: str) -> set[str]:
    """Имена аргументов из ячейки вида ``to:pos│"player", radius?=1`` (скобки-пояснения убираются)."""
    cell = re.sub(r"\([^)]*\)", " ", cell.replace("`", ""))
    names: set[str] = set()
    for piece in cell.split(","):
        for alt in piece.split("│"):
            m = re.match(r"\s*([a-z][a-z_]*)\s*(?:[?:=≤]|$)", alt)
            if m:
                names.add(m.group(1))
    return names


def server_tools(path: Path = SERVER_FILE) -> tuple[set[str], set[str]]:
    """(инструменты агента, служебные) — функции с ``@mcp.tool()`` в ``build_server``."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    agent: set[str] = set()
    admin: set[str] = set()

    def is_tool(fn) -> bool:
        return any(isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute)
                   and d.func.attr == "tool" for d in fn.decorator_list)

    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "build_server":
            for stmt in node.body:
                if isinstance(stmt, (ast.AsyncFunctionDef, ast.FunctionDef)) and is_tool(stmt):
                    agent.add(stmt.name)
                elif isinstance(stmt, ast.If):
                    for sub in ast.walk(stmt):
                        if isinstance(sub, (ast.AsyncFunctionDef, ast.FunctionDef)) and is_tool(sub):
                            admin.add(sub.name)
    return agent, admin


def mcp_tools(docs: Path = DOCS) -> dict[str, set[str]]:
    """Инструменты агента из таблицы docs/MCP.md: имя → допустимые аргументы."""
    out: dict[str, set[str]] = {}
    for cells in _table_rows((docs / "MCP.md").read_text(encoding="utf-8"), "tool"):
        name = cells[0].strip("`")
        out[name] = PLAN_ARGS.copy() if name == "partner_plan" else _arg_names(cells[1])
    return out


def actions(docs: Path = DOCS) -> dict[str, set[str]]:
    """Действия из «Список v1» docs/ACTIONS.md: ``do`` → допустимые аргументы."""
    out: dict[str, set[str]] = {}
    for cells in _table_rows((docs / "ACTIONS.md").read_text(encoding="utf-8"), "do"):
        name = cells[0].strip("`")
        out[name] = _arg_names(cells[1]) | EXTRA_ACT_ARGS.get(name, set())
    return out


def error_codes(docs: Path = DOCS) -> list[str]:
    """Коды ошибок мода из PROTOCOL §3."""
    return [c[0].strip("`") for c in _table_rows((docs / "PROTOCOL.md").read_text(encoding="utf-8"), "code")]


def loud_events(docs: Path = DOCS) -> list[str]:
    """Важные (будящие) события из EVENTS.md."""
    rows = _table_rows((docs / "EVENTS.md").read_text(encoding="utf-8"), "kind")
    return [re.match(r"`([a-z_]+)`", c[0]).group(1) for c in rows if re.match(r"`[a-z_]+`", c[0])]


def reflex_types(docs: Path = DOCS) -> dict[str, dict[str, tuple[float, float] | None]]:
    """Рефлексы v1 из EVENTS.md: тип → {параметр: (мин, макс) или None, если границ нет}."""
    out: dict[str, dict[str, tuple[float, float] | None]] = {}
    for cells in _table_rows((docs / "EVENTS.md").read_text(encoding="utf-8"), "type"):
        params: dict[str, tuple[float, float] | None] = {}
        for piece in cells[1].split(", "):
            m = re.match(r"\s*`([a-z_]+)`(?:\s+([\d.]+)\.\.([\d.]+))?", piece)
            if m:
                params[m.group(1)] = (float(m.group(2)), float(m.group(3))) if m.group(2) else None
        out[cells[0].strip("`")] = params
    return out


def role_rights() -> dict[str, frozenset[str]]:
    """Права ролей из server/factorio_partner/roles.py (модуль без зависимостей, кроме errors)."""
    sys.path.insert(0, str(SERVER_FILE.parent.parent))
    try:
        from factorio_partner import roles  # noqa: PLC0415
    finally:
        sys.path.pop(0)
    # права агентов; host — ключ диспетчера (главный чат), не агент
    return {r: v for r, v in roles.ALLOWED.items() if r in roles.ROLES}


def role_allowed(role: str, tool: str, args: dict) -> bool:
    """Разрешён ли роли именно этот вызов (с аргументами): та же проверка, что делает сервер."""
    sys.path.insert(0, str(SERVER_FILE.parent.parent))
    try:
        from factorio_partner import roles  # noqa: PLC0415
    finally:
        sys.path.pop(0)
    return roles.allowed(role, tool, args)


def tool_allowed(name: str, rights: frozenset[str]) -> bool:
    """Роль может вызвать инструмент хотя бы в одной форме (сам инструмент или «инструмент.форма»)."""
    return name in rights or any(c.startswith(name + ".") for c in rights)


# ---------------------------------------------------------------- агент
def parse_agent(text: str) -> tuple[dict[str, str], str]:
    """Frontmatter (простые ``ключ: значение``) и тело. Ошибка формата — ``ValueError``."""
    if not text.startswith("---\n"):
        raise ValueError("файл агента должен начинаться с frontmatter (---)")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise ValueError("frontmatter не закрыт (---)")
    meta: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if not line.strip():
            continue
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not m:
            raise ValueError(f"строка frontmatter не вида «ключ: значение»: {line[:40]!r}")
        if m.group(1) in meta:
            raise ValueError(f"ключ frontmatter повторяется: {m.group(1)}")
        meta[m.group(1)] = m.group(2).strip()
    return meta, text[end + 5:]


def agent_tools(meta: dict[str, str]) -> list[str]:
    return [t.strip() for t in meta.get("tools", "").split(",") if t.strip()]


def call_blocks(text: str) -> list[tuple[str, str]]:
    """Строки ``инструмент {json}`` из блоков ```call."""
    out: list[tuple[str, str]] = []
    for block in re.findall(r"```call\n(.*?)```", text, flags=re.S):
        for line in block.splitlines():
            if line.strip():
                tool, _, rest = line.strip().partition(" ")
                out.append((tool, rest.strip()))
    return out


def check_reflex_set(items, types: dict) -> list[str]:
    problems: list[str] = []
    if not isinstance(items, list) or len(items) > 16:
        return ["partner_reflex: set должен быть списком до 16 записей"]
    for item in items:
        kind = item.get("type") if isinstance(item, dict) else None
        if kind not in types:
            problems.append(f"partner_reflex: неизвестный тип рефлекса {kind!r}")
            continue
        for name, value in item.items():
            if name == "type":
                continue
            if name not in types[kind]:
                problems.append(f"partner_reflex {kind}: нет параметра {name!r} в EVENTS.md")
                continue
            bounds = types[kind][name]
            if bounds and not (isinstance(value, (int, float)) and not isinstance(value, bool)
                               and bounds[0] <= value <= bounds[1]):
                problems.append(f"partner_reflex {kind}.{name}={value!r} вне границ {bounds[0]:g}..{bounds[1]:g}")
    return problems


def check_call(tool: str, raw: str, allowed: set[str], tools: dict, acts: dict, reflexes: dict) -> list[str]:
    if tool not in allowed:
        return [f"вызов {tool}: инструмента нет в белом списке агента"]
    try:
        args = json.loads(raw) if raw else {}
    except ValueError:
        return [f"вызов {tool}: аргументы — не JSON"]
    if not isinstance(args, dict):
        return [f"вызов {tool}: аргументы должны быть объектом"]
    problems = [f"вызов {tool}: аргумента {k!r} нет в docs/MCP.md"
                for k in args if k not in tools.get(tool, set())]
    if {"helper", "key"} & set(args):
        problems.append(f"вызов {tool}: helper и key в примерах не пишутся")
    if tool == "partner_say" and len(str(args.get("text", ""))) > 200:
        problems.append("partner_say: текст длиннее 200 символов")
    if tool == "partner_wait" and not 0 < args.get("timeout", 30) <= 55:
        problems.append("partner_wait: timeout должен быть до 55")
    if tool == "partner_reflex":
        problems += check_reflex_set(args.get("set"), reflexes)
    if tool == "partner_act":
        do = args.get("do")
        if do not in acts:
            problems.append(f"partner_act: действия {do!r} нет в docs/ACTIONS.md")
        else:
            inner = args.get("args", {})
            if not isinstance(inner, dict):
                problems.append(f"partner_act {do}: args должен быть объектом")
            else:
                problems += [f"partner_act {do}: аргумента {k!r} нет в docs/ACTIONS.md"
                             for k in inner if k not in acts[do]]
                if do == "plan_mining" and inner.get("layout", "simple") not in LAYOUTS:
                    problems.append(f"plan_mining: раскладки {inner.get('layout')!r} нет в ACTIONS.md")
                if do == "build_blueprint" and inner.get("partial") is True:
                    problems.append("build_blueprint: partial:true в примерах не пишется — обрезанный чертёж "
                                    "ставится только по прямому согласию хозяина")
    return problems


def call_order(text: str) -> list[str]:
    """Шаги примера по порядку: имена инструментов чтения и ``do`` действий (без пробных прогонов)."""
    steps: list[str] = []
    for tool, raw in call_blocks(text):
        if tool != "partner_act":
            steps.append(tool)
            continue
        try:
            args = json.loads(raw)
        except ValueError:
            continue
        inner = args.get("args") if isinstance(args, dict) else None
        if isinstance(inner, dict) and inner.get("dry_run") is not True:
            steps.append(str(args.get("do")))
    return steps


def check_mining_order(text: str, name: str) -> list[str]:
    """В примере добычи шаги идут так: access → plan_mining → plan_belt → collect → build_ghosts."""
    steps = call_order(text)
    at = -1
    for step in MINING_ORDER:
        try:
            at = steps.index(step, at + 1)
        except ValueError:
            return [f"{name}: порядок поручения нарушен — нет шага {step} после предыдущих "
                    f"({' → '.join(MINING_ORDER)})"]
    return []


def check_supply_order(text: str, name: str) -> list[str]:
    """В примере большого поручения первый шаг разведки — partner_supply, а потом идут план хозяину
    и работа: collect → extract → craft → insert → place."""
    steps = call_order(text)
    problems: list[str] = []
    if "partner_supply" not in steps:
        return [f"{name}: в примере большого поручения нет вызова partner_supply"]
    first = steps.index("partner_supply")
    early = [s for s in steps[:first] if s in SCOUT_TOOLS]
    if early:
        problems.append(f"{name}: разведка источников начата с {early[0]} — первым должен быть partner_supply")
    at = -1
    for step in SUPPLY_ORDER:
        try:
            at = steps.index(step, at + 1)
        except ValueError:
            problems.append(f"{name}: порядок большого поручения нарушен — нет шага {step} после предыдущих "
                            f"({' → '.join(SUPPLY_ORDER)})")
            break
    return problems


def check_lookup_example(text: str, name: str) -> list[str]:
    """Пример справки: сначала partner_lookup, потом строка хозяину; помощник ничего
    не изучает — действий в примере нет."""
    steps = call_order(text)
    if "partner_lookup" not in steps:
        return [f"{name}: в примере справки нет вызова partner_lookup"]
    problems: list[str] = []
    if "partner_say" not in steps or steps.index("partner_say") < steps.index("partner_lookup"):
        problems.append(f"{name}: хозяину говорят после partner_lookup, а не до")
    acts = [t for t, _ in call_blocks(text) if t == "partner_act"]
    if acts:
        problems.append(f"{name}: в примере справки нет действий — помощник сам ничего не изучает")
    return problems


def lint_agent(agent_file: Path = AGENT_FILE, server_file: Path = SERVER_FILE, docs: Path = DOCS,
               extra_md: list[Path] | None = None) -> list[str]:
    problems: list[str] = []
    try:
        meta, body = parse_agent(agent_file.read_text(encoding="utf-8").replace("\r\n", "\n"))
    except (OSError, ValueError) as e:
        return [f"{agent_file.name}: {e}"]

    if meta.get("name") != "partner":
        problems.append("frontmatter: name должен быть partner")
    if meta.get("model") != "sonnet":
        problems.append("frontmatter: model по умолчанию — sonnet")
    if len(meta.get("description", "")) < 20:
        problems.append("frontmatter: нужно описание (description)")
    unknown = set(meta) - {"name", "description", "model", "tools"}
    if unknown:
        problems.append("frontmatter: лишние ключи: " + ", ".join(sorted(unknown)))

    in_server, admin = server_tools(server_file)
    tools = mcp_tools(docs)
    listed = agent_tools(meta)
    if not listed:
        problems.append("frontmatter: пустой белый список tools (без него агент получит все инструменты)")
    if len(set(listed)) != len(listed):
        problems.append("frontmatter: инструмент в tools повторяется")
    short: set[str] = set()
    for full in listed:
        if not full.startswith(TOOL_PREFIX) or "*" in full:
            problems.append(f"tools: {full} — разрешены только явные имена {TOOL_PREFIX}<инструмент>")
            continue
        name = full[len(TOOL_PREFIX):]
        short.add(name)
        if name in admin or not name.startswith("partner_"):
            problems.append(f"tools: {name} — служебный инструмент агенту не выдаётся")
        elif name not in in_server and not (name in PENDING_TOOLS and name in tools):
            problems.append(f"tools: {name} нет ни в сервере, ни среди добавляемых по docs/MCP.md")
        elif name not in tools:
            problems.append(f"tools: {name} нет в таблице инструментов docs/MCP.md")
    for name in sorted(short & HOST_TOOLS):
        problems.append(f"tools: {name} — инструмент диспетчера (ключ host), агенту не выдаётся")
    for name in sorted(set(tools) - short - MULTI_ROLE_TOOLS - HOST_TOOLS):
        problems.append(f"tools: в белом списке нет инструмента {name} из docs/MCP.md")
    for name in sorted(short & MULTI_ROLE_TOOLS):
        problems.append(f"tools: {name} — инструмент режима ролей, одиночному агенту не нужен")
    pilot = role_rights().get("pilot", frozenset())
    for name in sorted(n for n in short if n in tools and not tool_allowed(n, pilot)):
        problems.append(f"tools: {name} вне прав пилота (server/factorio_partner/roles.py)")

    for code in error_codes(docs):
        if f"`{code}`" not in body:
            problems.append(f"промпт: нет разбора кода ошибки {code} (PROTOCOL §3)")
    for text in SERVER_ERRORS:
        if f"`{text}`" not in body:
            problems.append(f"промпт: нет разбора отказа сервера «{text}» (MCP.md)")
    for kind in loud_events(docs):
        if f"`{kind}`" not in body:
            problems.append(f"промпт: нет важного события {kind} (EVENTS.md)")
    for word in REQUIRED:
        if word not in body:
            problems.append(f"промпт: нет обязательного правила или слова «{word}»")
    for layout in LAYOUTS:
        if f"`{layout}`" not in body:
            problems.append(f"промпт: не названа раскладка {layout}")
    acts = actions(docs)
    reflexes = reflex_types(docs)
    if not any(t == "partner_reflex" for t, _ in call_blocks(body)):
        problems.append("промпт: нет блока call с partner_reflex (рефлексы в начале смены)")

    for path in [agent_file, *(extra_md or [])]:
        try:
            text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        except OSError as e:
            problems.append(f"{path.name}: {e}")
            continue
        for tool, raw in call_blocks(text):
            problems += [f"{path.name}: {p}" for p in check_call(tool, raw, short, tools, acts, reflexes)]
    return problems


def lint_role(path: Path, role: str, server_file: Path = SERVER_FILE, docs: Path = DOCS) -> list[str]:
    """Агент роли: frontmatter, белый список — инструменты сервера и docs/MCP.md в правах роли
    (roles.ALLOWED), вызовы в блоках call — только из этого списка."""
    name = path.name
    try:
        meta, body = parse_agent(path.read_text(encoding="utf-8").replace("\r\n", "\n"))
    except (OSError, ValueError) as e:
        return [f"{name}: {e}"]
    problems: list[str] = []
    if meta.get("name") != path.stem:
        problems.append(f"{name}: frontmatter: name должен быть {path.stem}")
    if meta.get("model") not in ROLE_MODELS.get(role, set()):
        problems.append(f"{name}: frontmatter: model роли {role} — одна из "
                        + ", ".join(sorted(ROLE_MODELS.get(role, set()))))
    if len(meta.get("description", "")) < 20:
        problems.append(f"{name}: frontmatter: нужно описание (description)")
    unknown = set(meta) - {"name", "description", "model", "tools"}
    if unknown:
        problems.append(f"{name}: frontmatter: лишние ключи: " + ", ".join(sorted(unknown)))
    in_server, admin = server_tools(server_file)
    tools = mcp_tools(docs)
    rights = role_rights().get(role, frozenset())
    listed = agent_tools(meta)
    if not listed:
        problems.append(f"{name}: frontmatter: пустой белый список tools")
    if len(set(listed)) != len(listed):
        problems.append(f"{name}: frontmatter: инструмент в tools повторяется")
    short: set[str] = set()
    for full in listed:
        if not full.startswith(TOOL_PREFIX) or "*" in full:
            problems.append(f"{name}: tools: {full} — разрешены только явные имена {TOOL_PREFIX}<инструмент>")
            continue
        tool = full[len(TOOL_PREFIX):]
        short.add(tool)
        if tool in admin or not tool.startswith("partner_"):
            problems.append(f"{name}: tools: {tool} — служебный или несуществующий инструмент")
        elif tool not in in_server or tool not in tools:
            problems.append(f"{name}: tools: {tool} нет в сервере или в таблице docs/MCP.md")
        elif not tool_allowed(tool, rights):
            problems.append(f"{name}: tools: {tool} вне прав роли {role} (server/factorio_partner/roles.py)")
    for tool in ("partner_brief", "partner_wait", *ROLE_NEEDS.get(role, ())):
        if tool not in short:
            problems.append(f"{name}: tools: нет {tool} — без него роль {role} не работает")
    acts, reflexes = actions(docs), reflex_types(docs)
    for tool, raw in call_blocks(body):
        problems += [f"{name}: {p}" for p in check_call(tool, raw, short, tools, acts, reflexes)]
        try:
            args = json.loads(raw) if raw else {}
        except ValueError:
            continue
        if isinstance(args, dict) and tool in tools and not role_allowed(role, tool, args):
            problems.append(f"{name}: вызов {tool} {raw[:60]} вне прав роли {role} в этой форме (roles.py)")
    # всё, что названо в тексте: инструменты есть в docs/MCP.md, служебных и консольных команд нет
    for word in sorted(set(re.findall(r"\bpartner_[a-z_]+\b", body))):
        if word not in tools:
            problems.append(f"{name}: в тексте назван {word}, которого нет в таблице docs/MCP.md")
    for word in sorted(set(re.findall(r"\badmin_[a-z_]+\b", body))):
        problems.append(f"{name}: в тексте служебный инструмент {word}: агенту роли он недоступен")
    if CONSOLE_MD_RE.search(body):
        problems.append(f"{name}: в тексте консольная команда игры (/c, /sc, /silent-command): "
                        "разрешён только /partner через мост")
    for word in ROLE_WORDS.get(role, ()):
        if word not in body:
            problems.append(f"{name}: в правилах нет обязательного слова «{word}»")
    return problems


def role_files() -> list[Path]:
    return [AGENT_FILE.parent / f for f in ROLE_FILES]


# ---------------------------------------------------------------- прочее
def lint_files(paths: list[Path]) -> list[str]:
    """Личные пути и адреса; консольные команды в коде; обязательные части сценария запуска."""
    problems: list[str] = []
    for path in paths:
        if path.suffix not in TEXT_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8")
        rel = path.name
        m = PRIVATE_RE.search(text)
        if m:
            problems.append(f"{rel}: похоже на личный путь или адрес: {m.group(0)!r}")
        if path.suffix in {".py", ".js"} and path.name != "lint.py" and CONSOLE_RE.search(text):
            problems.append(f"{rel}: строка похожа на консольную команду игры (разрешён только /partner через мост)")
        if path.suffix == ".js":
            if not re.search(r"^export const meta = \{", text, flags=re.M):
                problems.append(f"{rel}: сценарий должен начинаться с export const meta")
            if not re.search(r"agentType:\s*'partner'", text) and not re.search(
                    r"partner-(?:voice|pilot|strategist)'", text):
                problems.append(f"{rel}: агенты сценария должны быть типа partner (или его ролей)")
            if re.search(r"Date\.now\(|Math\.random\(|new Date\(\)", text):
                problems.append(f"{rel}: в сценарии нельзя Date.now / Math.random / new Date()")
    return problems


def repo_files() -> list[Path]:
    files = [p for p in AGENTS_DIR.rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    return sorted(files) + [AGENT_FILE] + [p for p in role_files() if p.is_file()]


def lint_all() -> list[str]:
    examples = sorted((AGENTS_DIR / "examples").glob("*.md"))
    order: list[str] = []
    mining = AGENTS_DIR / "examples" / "mining-order.md"
    if mining.is_file():
        order = check_mining_order(mining.read_text(encoding="utf-8").replace("\r\n", "\n"), mining.name)
    supply = AGENTS_DIR / "examples" / "supply-order.md"
    if supply.is_file():
        order += check_supply_order(supply.read_text(encoding="utf-8").replace("\r\n", "\n"), supply.name)
    else:
        order.append("examples/supply-order.md: нет примера большого поручения")
    lookup = AGENTS_DIR / "examples" / "lookup-research.md"
    if lookup.is_file():
        order += check_lookup_example(lookup.read_text(encoding="utf-8").replace("\r\n", "\n"), lookup.name)
    else:
        order.append("examples/lookup-research.md: нет примера справки")
    roles = []
    for path in role_files():
        if path.is_file():
            roles += lint_role(path, ROLE_FILES[path.name])
        else:
            roles.append(f"{path.name}: нет файла агента роли")
    return lint_agent(extra_md=examples) + order + roles + lint_files(repo_files())


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    problems = lint_all()
    for p in problems:
        print("-", p)
    print("agents lint:", "чисто" if not problems else f"замечаний: {len(problems)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
