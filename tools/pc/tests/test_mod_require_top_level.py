"""Factorio разрешает require только при загрузке control.lua: require внутри функции падает в игре
("Require can't be used outside of control.lua parsing"), а заглушки Lua в тестах этого не ловят."""
from __future__ import annotations

import re
from pathlib import Path

# control.lua и файлы стадии данных выполняются целиком при загрузке — там require можно и в цикле.
MOD = Path(__file__).resolve().parents[3] / "mod" / "factorio-partner"


def test_require_only_at_top_level():
    bad = []
    for path in MOD.rglob("*.lua"):
        if "vendor" in path.parts or path.name in ("control.lua", "data.lua", "data-final-fixes.lua", "settings.lua"):
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]
            if re.search(r"\brequire\s*\(", code) and line[:1] in (" ", "\t"):
                bad.append(f"{path.relative_to(MOD)}:{n}: {line.strip()}")
    assert not bad, "require внутри функции (игра это запрещает):\n" + "\n".join(bad)
