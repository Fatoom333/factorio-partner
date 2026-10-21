"""Роли напарника для других агентских клиентов: Codex CLI, Gemini CLI, OpenCode, Cursor.

    python agents/roles_export.py            # записать файлы в репозиторий
    python agents/roles_export.py --check    # код выхода 1, если файлы устарели (его зовёт lint.py)

Единственный источник — ``.claude/agents/partner*.md`` (формат подагента Claude Code: frontmatter + тело).
Тело — правила роли — переносится без изменений; frontmatter переводится в формат клиента:
имена инструментов ``mcp__partner__*`` и названия моделей Claude у других клиентов не годятся, поэтому
список инструментов не пишется (инструменты роли ограничивает сервер по ключу), а модель наследуется
от основной сессии клиента.

Куда пишутся файлы:

    Codex CLI   .codex/agents/<имя>.toml    (name, description, developer_instructions)
    Gemini CLI  .gemini/agents/<имя>.md     (name, description, max_turns, timeout_mins)
    OpenCode    .opencode/agents/<имя>.md   (description, mode: subagent, permission)
    Cursor      .cursor/agents/<имя>.md     (name, description, model, readonly, is_background)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / ".claude" / "agents"
SOURCES = ("partner-voice.md", "partner-pilot.md", "partner-strategist.md", "partner.md")
CLIENTS = ("codex", "gemini", "opencode", "cursor")
OUT_DIRS = {"codex": ".codex/agents", "gemini": ".gemini/agents",
            "opencode": ".opencode/agents", "cursor": ".cursor/agents"}
EXT = {"codex": ".toml", "gemini": ".md", "opencode": ".md", "cursor": ".md"}
# роли — долгие петли «ждать событие → ответить»: лимиты шагов и времени у Gemini CLI берём большими
GEMINI_MAX_TURNS = 500
GEMINI_TIMEOUT_MINS = 720


def parse_source(text: str) -> tuple[dict[str, str], str]:
    """Frontmatter (простые ``ключ: значение``) и тело исходного файла агента Claude Code."""
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        raise ValueError("файл агента должен начинаться с frontmatter (---)")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise ValueError("frontmatter не закрыт (---)")
    meta: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition(":")
        if not sep or not key.strip():
            raise ValueError(f"строка frontmatter не вида «ключ: значение»: {line[:40]!r}")
        meta[key.strip()] = value.strip()
    return meta, text[end + 5:]


def _note(source: str) -> str:
    return f"generated from .claude/agents/{source} by agents/roles_export.py, do not edit"


def _q(value: str) -> str:
    """Строка в двойных кавычках: годится и как YAML-скаляр, и как базовая строка TOML."""
    return json.dumps(value, ensure_ascii=False)


def _toml_text(body: str) -> str:
    if "'''" not in body:
        return "'''\n" + body + "'''"          # литеральная строка: без экранирования
    escaped = body.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    return '"""\n' + escaped + '"""'


def render(client: str, source: str, text: str) -> str:
    """Файл агента для ``client`` из исходного файла ``source`` (имя в .claude/agents) с текстом ``text``."""
    meta, body = parse_source(text)
    name, description = meta["name"], meta["description"]
    if not body.endswith("\n"):
        body += "\n"
    note = _note(source)
    if client == "codex":
        return (f"# {note}\n"
                f"name = {_q(name)}\n"
                f"description = {_q(description)}\n"
                f"developer_instructions = {_toml_text(body)}\n")
    if client == "gemini":
        head = [f"name: {_q(name)}", f"description: {_q(description)}",
                f"max_turns: {GEMINI_MAX_TURNS}", f"timeout_mins: {GEMINI_TIMEOUT_MINS}"]
    elif client == "opencode":
        head = [f"description: {_q(description)}", "mode: subagent",
                "permission:", "  edit: deny", "  bash: deny"]
    elif client == "cursor":
        head = [f"name: {_q(name)}", f"description: {_q(description)}", "model: inherit",
                "readonly: true", "is_background: true"]
    else:
        raise ValueError(f"неизвестный клиент: {client}")
    return "---\n" + "\n".join(head) + f"\n---\n<!-- {note} -->\n" + body


def expected(source_dir: Path = SOURCE_DIR) -> dict[str, str]:
    """Все нужные файлы: путь от корня репозитория (через ``/``) -> текст."""
    files: dict[str, str] = {}
    for source in SOURCES:
        text = (source_dir / source).read_text(encoding="utf-8")
        name = parse_source(text)[0]["name"]
        for client in CLIENTS:
            files[f"{OUT_DIRS[client]}/{name}{EXT[client]}"] = render(client, source, text)
    return files


def check(root: Path = ROOT, source_dir: Path | None = None) -> list[str]:
    """Расхождения между файлами в репозитории и тем, что дал бы экспорт; пусто — всё свежо."""
    problems: list[str] = []
    want = expected(source_dir or root / ".claude" / "agents")
    for rel, text in want.items():
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel}: нет файла (python agents/roles_export.py)")
        elif path.read_text(encoding="utf-8").replace("\r\n", "\n") != text:
            problems.append(f"{rel}: устарел, пересобери (python agents/roles_export.py)")
    for client in CLIENTS:
        directory = root / OUT_DIRS[client]
        if directory.is_dir():
            for path in sorted(directory.glob("partner*" + EXT[client])):
                rel = f"{OUT_DIRS[client]}/{path.name}"
                if rel not in want:
                    problems.append(f"{rel}: нет исходного файла в .claude/agents")
    return problems


def write(root: Path = ROOT, source_dir: Path | None = None) -> list[str]:
    """Записать файлы; вернуть пути, которые изменились."""
    changed: list[str] = []
    for rel, text in expected(source_dir or root / ".claude" / "agents").items():
        path = root / rel
        if path.is_file() and path.read_text(encoding="utf-8").replace("\r\n", "\n") == text:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        changed.append(rel)
    return changed


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(prog="roles_export.py", description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="только проверить, что файлы свежие")
    ns = ap.parse_args(argv)
    if ns.check:
        problems = check()
        for p in problems:
            print("-", p)
        print("roles export:", "свежо" if not problems else f"замечаний: {len(problems)}")
        return 1 if problems else 0
    changed = write()
    for rel in changed:
        print("записан", rel)
    print("roles export:", f"изменено файлов: {len(changed)}" if changed else "всё уже свежо")
    return 0


if __name__ == "__main__":
    sys.exit(main())
