"""Сборка для живых тестов (поток E): zip мода и пакет стенда для ПК.

    python tools/pc/pack.py mod --src mod/factorio-partner --out DIR        -> печатает путь zip
    python tools/pc/pack.py scenario-mods --name e_chart                    -> печатает JSON-список модов
    python tools/pc/pack.py payload --slot N --scenario NAME --out FILE.zip [--mods a,b] [--save ...] ...

Zip мода — как ждёт Factorio: одна папка `<name>_<version>/` внутри, пути через `/`.
Пакет стенда: `stand/live_client.py`, `stand/stand.ps1`, `stand/scenarios/*.py`,
`stand/mods/<name>_<version>.zip`, `stand/stand.json` (настройки запуска, без секретов).
Пути ПК по умолчанию — в DEFAULTS; свои (другой диск, обновился Steam) — в необязательном
`tools/pc/pc.local.json` (в git не идёт): {"factorio_exe": ..., "factorio_data": ..., "pc_python": ..., "save": ...}.
Порядок: DEFAULTS < pc.local.json < ключи командной строки.
Только стандартная библиотека.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
import zipfile
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))

# Какие моды стенд умеет собирать и откуда.
MOD_SOURCES: Dict[str, str] = {
    "factorio-partner": os.path.join("mod", "factorio-partner"),
    "partner-test": os.path.join("mod", "partner-test"),
}
DEFAULT_MODS = ["factorio-partner"]

SCENARIO_RE = re.compile(r"^[a-z0-9_]{1,64}$")
SAVE_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}\.zip$")
MOD_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
VERSION_RE = re.compile(r"^\d{1,5}\.\d{1,5}\.\d{1,5}$")
SKIP_DIRS = {"__pycache__", ".git", "tests"}
SKIP_EXT = {".zip", ".pyc"}
FIXED_TIME = (2026, 1, 1, 0, 0, 0)

DEFAULTS = {
    "save": "Vulkan-Start-test.zip",
    "factorio_exe": r"D:\Program Files (x86)\Steam\steamapps\common\Factorio\bin\x64\factorio.exe",
    "factorio_data": r"C:\FactorioData",  # заглушка: свой путь к данным Factorio — в tools/pc/pc.local.json
    "pc_python": r"D:\Temp\partner-rcon\venv\Scripts\python.exe",
    "timeout_sec": 600,
    "ready_timeout_sec": 240,
}

LOCAL_CONFIG = os.path.join(HERE, "pc.local.json")
LOCAL_KEYS = ("save", "factorio_exe", "factorio_data", "pc_python")


class PackError(Exception):
    pass


def read_info(src: str) -> Dict[str, str]:
    path = os.path.join(src, "info.json")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            info = json.load(f)
    except (OSError, ValueError) as e:
        raise PackError(f"не прочитать {path}: {e}") from None
    name, version = info.get("name"), info.get("version")
    if not isinstance(name, str) or not MOD_NAME_RE.match(name):
        raise PackError(f"{path}: плохое name")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        raise PackError(f"{path}: плохая version")
    return {"name": name, "version": version}


def _mod_files(src: str) -> List[str]:
    files = []
    for root, dirs, names in os.walk(src):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
        for n in sorted(names):
            if n.startswith(".") or os.path.splitext(n)[1].lower() in SKIP_EXT:
                continue
            full = os.path.join(root, n)
            if os.path.islink(full):
                continue
            files.append(os.path.relpath(full, src))
    return files


def build_mod(src: str, out_dir: str) -> str:
    info = read_info(src)
    top = f"{info['name']}_{info['version']}"
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, top + ".zip")
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for rel in _mod_files(src):
            arc = top + "/" + rel.replace(os.sep, "/")
            zi = zipfile.ZipInfo(arc, date_time=FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            with open(os.path.join(src, rel), "rb") as f:
                z.writestr(zi, f.read())
    return out


def scenario_mods(name: str, scenarios_dir: Optional[str] = None) -> List[str]:
    """Читает `MODS = [...]` из сценария без его выполнения (ast). Нет — DEFAULT_MODS."""
    if not SCENARIO_RE.match(name or ""):
        raise PackError("имя сценария: [a-z0-9_]{1,64}")
    path = os.path.join(scenarios_dir or os.path.join(HERE, "scenarios"), name + ".py")
    try:
        with open(path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=path)
    except OSError:
        raise PackError(f"нет сценария {name}") from None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "MODS" for t in node.targets):
            value = ast.literal_eval(node.value)
            return validate_mods(value)
    return list(DEFAULT_MODS)


def validate_mods(mods) -> List[str]:
    if not isinstance(mods, (list, tuple)) or not mods:
        raise PackError("список модов пуст")
    out = []
    for m in mods:
        if m not in MOD_SOURCES:
            raise PackError(f"неизвестный мод {m!r}; можно: {sorted(MOD_SOURCES)}")
        if m not in out:
            out.append(m)
    return out


def load_local_config(path: Optional[str]) -> Dict:
    """Необязательные локальные пути ПК. Нет файла — {}. Значения проверяет build_payload."""
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise PackError(f"не прочитать {path}: {e}") from None
    if not isinstance(data, dict):
        raise PackError(f"{path}: нужен объект JSON")
    extra = sorted(set(data) - set(LOCAL_KEYS))
    if extra:
        raise PackError(f"{path}: неизвестные ключи {extra}; можно: {list(LOCAL_KEYS)}")
    return data


def build_payload(slot: int, scenario: str, out_file: str, mods: Optional[List[str]] = None,
                  repo: str = REPO, local_config: Optional[str] = None, **overrides) -> Dict:
    if not isinstance(slot, int) or not (0 <= slot <= 9):
        raise PackError("слот 0..9")
    scen_dir = os.path.join(repo, "tools", "pc", "scenarios")
    mods = validate_mods(mods) if mods else scenario_mods(scenario, scen_dir)
    config = dict(DEFAULTS)
    config.update(load_local_config(local_config))
    for k, v in overrides.items():
        if v is not None:
            if k not in DEFAULTS:
                raise PackError(f"неизвестная настройка {k}")
            config[k] = v
    if not SAVE_RE.match(str(config["save"])):
        raise PackError("имя сейва: [A-Za-z0-9._-]{1,64}.zip")
    for k in ("timeout_sec", "ready_timeout_sec"):
        if not isinstance(config[k], int) or not (10 <= config[k] <= 7200):
            raise PackError(f"{k}: 10..7200")
    for k in ("factorio_exe", "factorio_data", "pc_python"):
        v = config[k]
        if not isinstance(v, str) or not re.match(r"^[A-Za-z]:\\[^\"'`$;&|<>\r\n]*$", v):
            raise PackError(f"{k}: нужен абсолютный путь Windows без кавычек и спецсимволов")
    config.update({"slot": slot, "scenario": scenario, "mods": [], "rcon_port": 27100 + slot,
                   "game_port": 34200 + slot})
    tmp_mods = out_file + ".mods"
    os.makedirs(tmp_mods, exist_ok=True)
    try:
        mod_zips = []
        for m in mods:
            path = build_mod(os.path.join(repo, MOD_SOURCES[m]), tmp_mods)
            info = read_info(os.path.join(repo, MOD_SOURCES[m]))
            config["mods"].append({"name": info["name"], "version": info["version"],
                                   "file": os.path.basename(path)})
            mod_zips.append(path)
        if not os.path.isfile(os.path.join(scen_dir, scenario + ".py")):
            raise PackError(f"нет сценария {scenario}")
        with zipfile.ZipFile(out_file, "w", compression=zipfile.ZIP_DEFLATED) as z:
            z.write(os.path.join(repo, "tools", "pc", "live_client.py"), "stand/live_client.py")
            z.write(os.path.join(repo, "tools", "pc", "remote", "stand.ps1"), "stand/stand.ps1")
            for n in sorted(os.listdir(scen_dir)):
                if n.endswith(".py") and SCENARIO_RE.match(n[:-3]):
                    z.write(os.path.join(scen_dir, n), "stand/scenarios/" + n)
            for p in mod_zips:
                z.write(p, "stand/mods/" + os.path.basename(p))
            z.writestr("stand/stand.json", json.dumps(config, ensure_ascii=False, indent=2))
    finally:
        for n in os.listdir(tmp_mods):
            os.remove(os.path.join(tmp_mods, n))
        os.rmdir(tmp_mods)
    return config


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Сборка мода и пакета стенда")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("mod")
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("scenario-mods")
    p.add_argument("--name", required=True)
    p.add_argument("--plain", action="store_true", help="через запятую, для PowerShell")
    p = sub.add_parser("payload")
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--scenario", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--mods", default="")
    p.add_argument("--save")
    p.add_argument("--factorio-exe")
    p.add_argument("--factorio-data")
    p.add_argument("--pc-python")
    p.add_argument("--timeout-sec", type=int)
    p.add_argument("--ready-timeout-sec", type=int)
    p.add_argument("--local-config", default=LOCAL_CONFIG, help="пути ПК (по умолчанию tools/pc/pc.local.json, если есть)")
    ns = ap.parse_args(argv)
    try:
        if ns.cmd == "mod":
            print(build_mod(ns.src, ns.out))
        elif ns.cmd == "scenario-mods":
            mods = scenario_mods(ns.name)
            print(",".join(mods) if ns.plain else json.dumps(mods))
        else:
            mods = [m.strip() for m in ns.mods.split(",") if m.strip()] or None
            cfg = build_payload(ns.slot, ns.scenario, ns.out, mods, local_config=ns.local_config, save=ns.save, factorio_exe=ns.factorio_exe,
                                factorio_data=ns.factorio_data, pc_python=ns.pc_python,
                                timeout_sec=ns.timeout_sec, ready_timeout_sec=ns.ready_timeout_sec)
            print(json.dumps({"mods": [m["file"] for m in cfg["mods"]], "scenario": cfg["scenario"]}))
    except PackError as e:
        print(f"pack: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
