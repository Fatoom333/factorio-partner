#!/usr/bin/env python3
"""Юнит-тесты Lua мода factorio-partner под lupa (docs/TESTING.md §1).

Запуск из корня репозитория (lupa — только в venv, см. tools/requirements-dev.txt):
    python tools/run_lua_tests.py                 # все mod/tests/*.lua (кроме stubs*.lua)
    python tools/run_lua_tests.py core_jobs       # только файлы, где в имени есть подстрока
    python tools/run_lua_tests.py -v              # печатать вывод и журнал (log) и у прошедших

Каждый тест-файл исполняется в свежем LuaRuntime (Lua 5.2, как в Factorio; если в сборке
lupa нет lua52 — lua53). Тест — файл, который бросает error() при провале.
Помимо тестов раннер делает статическую проверку исходников мода (`lint`): запрещённые
вызовы (teleport, mine_entity, load/loadstring, /c, /sc, /silent-command) и конструкции,
зависящие от целочисленного подтипа Lua 5.3 (math.type, math.tointeger, //).
Lint — best-effort, а не гарантия: строки ищутся построчно и грубо (содержимое строковых
литералов, не начинающихся с «/», затирается), поэтому "foo /c", "/" .. "c", string.char и
т.п. он не поймает. Главная защита — ревью и правило PROTOCOL §1 (только /partner <JSON>).
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import re
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "mod" / "factorio-partner"
TESTS = ROOT / "mod" / "tests"
MOD_NAME = "factorio-partner"


def pick_lua(force=None):
    if force == "5.3":
        import lupa.lua53 as lua_mod  # type: ignore
        return lua_mod, "5.3"
    try:
        import lupa.lua52 as lua_mod  # type: ignore
        return lua_mod, "5.2"
    except ImportError:
        import lupa.lua53 as lua_mod  # type: ignore
        return lua_mod, "5.3"


# ---------------------------------------------------------------- JSON-мост (helpers.*_json)

class JsonBridge:
    """helpers.table_to_json / json_to_table через Python json, по правилам Factorio:
    пустая таблица -> {}, массив = ключи 1..n без дыр, числовые ключи иначе -> строки,
    целые числа без '.0'. LuaObject (таблица-заглушка с метатаблицей __lua_object) и
    функции сериализовать нельзя — ошибка, как в игре."""

    def __init__(self, lua_mod, runtime):
        self.lua_mod = lua_mod
        self.rt = runtime
        self.getmetatable = runtime.eval("getmetatable")
        self.rawget = runtime.eval("rawget")

    def _is_lua_object(self, t) -> bool:
        mt = self.getmetatable(t)
        if mt is None:
            return False
        return bool(self.rawget(mt, "__lua_object"))

    def to_py(self, v, depth=0):
        if depth > 64:
            raise ValueError("table_to_json: слишком глубокая вложенность")
        lt = self.lua_mod.lua_type(v)
        if lt == "table":
            if self._is_lua_object(v):
                raise ValueError("table_to_json: LuaObject в данных (PROTOCOL §1)")
            keys = list(v.keys())
            if not keys:
                return {}
            nums = [k for k in keys if isinstance(k, (int, float)) and not isinstance(k, bool)]
            if len(nums) == len(keys) and all(float(k).is_integer() for k in nums):
                ints = sorted(int(k) for k in nums)
                if ints == list(range(1, len(ints) + 1)):
                    return [self.to_py(v[i], depth + 1) for i in ints]
            out = {}
            for k in keys:
                if isinstance(k, float) and k.is_integer():
                    sk = str(int(k))
                elif isinstance(k, bytes):
                    sk = k.decode("utf-8", "replace")
                else:
                    sk = str(k)
                out[sk] = self.to_py(v[k], depth + 1)
            return out
        if lt is not None:  # function, userdata, thread
            raise ValueError(f"table_to_json: нельзя сериализовать {lt}")
        if isinstance(v, bool) or v is None:
            return v
        if isinstance(v, float):
            if math.isnan(v) or math.isinf(v):
                raise ValueError("table_to_json: nan/inf")
            if v.is_integer() and abs(v) < 2 ** 53:
                return int(v)
            return v
        if isinstance(v, bytes):
            return v.decode("utf-8", "replace")
        return v

    def table_to_json(self, t):
        return json.dumps(self.to_py(t), ensure_ascii=False, separators=(",", ":"))

    def json_to_table(self, s):
        if isinstance(s, bytes):
            s = s.decode("utf-8", "replace")
        if not isinstance(s, str):
            return None
        try:
            obj = json.loads(s)
        except (ValueError, RecursionError):
            return None
        return self._to_lua(obj)

    def _to_lua(self, obj):
        if isinstance(obj, dict):
            t = self.rt.table()
            for k, val in obj.items():
                if val is not None:
                    t[k] = self._to_lua(val)
            return t
        if isinstance(obj, list):
            t = self.rt.table()
            for i, val in enumerate(obj, 1):
                if val is not None:
                    t[i] = self._to_lua(val)
            return t
        return obj


# ---------------------------------------------------------------- загрузка файлов

def make_reader():
    allowed = [MOD.resolve(), TESTS.resolve()]

    def read(path):
        if isinstance(path, bytes):
            path = path.decode("utf-8")
        p = pathlib.Path(path).resolve()
        if not any(p == a or a in p.parents for a in allowed):
            return None
        if not p.is_file():
            return None
        return p.read_text(encoding="utf-8")

    return read


BOOT = r"""
local mod_dir, tests_dir, read, mod_name = ...
-- Загрузчик как в Factorio: require("scripts.core.err") -> <mod>/scripts/core/err.lua,
-- имя чанка "__factorio-partner__/scripts/core/err.lua" (так пути видны в ошибках игры).
local function searcher(name)
  local rel = name:gsub("%.", "/")
  local tried = {}
  for _, base in ipairs({ mod_dir, tests_dir }) do
    for _, pat in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
      local full = base .. "/" .. pat
      local src = read(full)
      if src then
        local chunkname = (base == mod_dir) and ("@__" .. mod_name .. "__/" .. pat) or ("@tests/" .. pat)
        local fn, err = load(src, chunkname, "t")
        if not fn then error(err, 0) end
        return fn, full
      end
      tried[#tried + 1] = "\n\tno file '" .. full .. "'"
    end
  end
  return table.concat(tried)
end
package.path = mod_dir .. "/?.lua;" .. mod_dir .. "/?/init.lua;" .. tests_dir .. "/?.lua"
local searchers = package.searchers or package.loaders
for i = #searchers, 2, -1 do table.remove(searchers, i) end
searchers[2] = searcher
__fp_test_env = { mod_dir = mod_dir, tests_dir = tests_dir, read = read, mod_name = mod_name }
"""

RUN = r"""
local name, src = ...
local fn, err = load(src, "@tests/" .. name, "t")
if not fn then return false, err end
local ok, msg = xpcall(fn, debug.traceback)
return ok, msg
"""


def run_file(lua_mod, path: pathlib.Path, verbose: bool):
    rt = lua_mod.LuaRuntime(unpack_returned_tuples=True)
    bridge = JsonBridge(lua_mod, rt)
    g = rt.globals()
    g.__py_table_to_json = bridge.table_to_json
    g.__py_json_to_table = bridge.json_to_table
    g.__fp_verbose = bool(verbose)
    g.print = lambda *a: print(" ".join(str(x) for x in a), flush=True)
    rt.execute(BOOT, MOD.as_posix(), TESTS.as_posix(), make_reader(), MOD_NAME)
    src = path.read_text(encoding="utf-8")
    t0 = time.perf_counter()
    try:
        ok, msg = rt.execute(RUN, path.name, src)
    except Exception as exc:  # ошибка вне xpcall (lupa)
        ok, msg = False, f"{type(exc).__name__}: {exc}"
    dt = (time.perf_counter() - t0) * 1000
    return bool(ok), (msg if not ok else None), dt


# ---------------------------------------------------------------- статическая проверка

FORBIDDEN = [
    (re.compile(r"\.teleport\s*\("), "teleport запрещён (PROTOCOL §6.1)"),
    (re.compile(r"\bmine_entity\s*\("), "mine_entity запрещён (PROTOCOL §6.5)"),
    (re.compile(r"\bloadstring\s*\("), "произвольный Lua запрещён (PROTOCOL §6.10)"),
    (re.compile(r"(?<![\w.:])load\s*\("), "произвольный Lua запрещён (PROTOCOL §6.10)"),
    (re.compile(r"(?<![\w.:])dofile\s*\("), "dofile запрещён"),
    (re.compile(r"""["']\s*/(c|sc|silent-command|command)\b"""), "/c, /sc, /silent-command запрещены (PROTOCOL §1)"),
    (re.compile(r"\bmath\.type\b"), "math.type нет в Lua 5.2 (Factorio)"),
    (re.compile(r"\bmath\.tointeger\b"), "math.tointeger нет в Lua 5.2 (Factorio)"),
    (re.compile(r"//"), "целочисленное деление // нет в Lua 5.2 (Factorio)"),
    (re.compile(r"\butf8\."), "библиотеки utf8 нет в Lua 5.2 (Factorio)"),
]

_LONG = re.compile(r"\[(=*)\[.*?\]\1\]", re.S)


def strip_lua(src: str) -> str:
    """Грубо убирает комментарии и содержимое строк (оставляет кавычки), чтобы lint
    смотрел только на код. Содержимое коротких строк заменяется на 'x' — кроме первых
    символов, по которым ловим "/c"."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = _LONG.match(src, i + 2)
            if m:
                i = m.end()
                continue
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "[":
            m = _LONG.match(src, i)
            if m:
                out.append('""')
                i = m.end()
                continue
        if c in "\"'":
            j = i + 1
            buf = []
            while j < n and src[j] != c:
                if src[j] == "\\":
                    buf.append("x")
                    j += 2
                    continue
                if src[j] == "\n":
                    break
                buf.append(src[j])
                j += 1
            s = "".join(buf)
            keep = s if s.lstrip().startswith("/") else re.sub(r"[^\s]", "x", s)
            out.append(c + keep + c)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def lint() -> list[str]:
    problems = []
    for p in sorted(MOD.rglob("*.lua")):
        code = strip_lua(p.read_text(encoding="utf-8"))
        for lineno, line in enumerate(code.splitlines(), 1):
            for rx, why in FORBIDDEN:
                if rx.search(line):
                    problems.append(f"{p.relative_to(ROOT).as_posix()}:{lineno}: {why}")
    return problems


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="подстроки имён тест-файлов")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--no-lint", action="store_true", help="не делать статическую проверку")
    ap.add_argument("--lua", choices=["5.2", "5.3"], help="5.3 — проверить и под lua53 (по умолчанию 5.2)")
    args = ap.parse_args(argv)

    try:
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)  # type: ignore[attr-defined]
    except Exception:
        pass

    # Классы %a/%c/%s/%w в шаблонах Lua зависят от локали процесса; в игре локаль "C",
    # а Python при старте ставит локаль пользователя (на Windows — cp1251 и т.п.).
    import locale
    try:
        locale.setlocale(locale.LC_ALL, "C")
    except locale.Error:
        pass

    lua_mod, ver = pick_lua(args.lua)
    print(f"Lua {ver} (lupa {getattr(__import__('lupa'), '__version__', '?')})")
    if ver != "5.2":
        print("ВНИМАНИЕ: тесты идут под Lua 5.3 (в игре 5.2); lint следит за math.type, math.tointeger и //")

    failed = 0
    total = 0
    if not args.no_lint and not args.names:
        total += 1
        problems = lint()
        if problems:
            failed += 1
            print("FAIL lint")
            for pr in problems:
                print("   ", pr)
        else:
            print("PASS lint")

    files = sorted(p for p in TESTS.glob("*.lua") if not p.name.startswith("stubs"))
    if args.names:
        files = [p for p in files if any(n in p.name for n in args.names)]
    for p in files:
        total += 1
        ok, msg, dt = run_file(lua_mod, p, args.verbose)
        if ok:
            print(f"PASS {p.name} ({dt:.0f} ms)")
        else:
            failed += 1
            print(f"FAIL {p.name} ({dt:.0f} ms)\n{msg}")
    print(f"\n{total - failed}/{total} ok" + ("" if not failed else f", провалено: {failed}"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
