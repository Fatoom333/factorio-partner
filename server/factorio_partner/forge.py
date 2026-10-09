"""Связка с factorio-forge: `partner_plan` и заметки профиля для `partner_brief` (поток I).

Модуль самодостаточен: только стандартная библиотека; из пакета `factorio_partner` берёт
лишь `PartnerError` (если пакет есть), чтобы `PlanArgsError` сервер отдал как `bad_args`.
Python-контракт (MCP.md, единственный; сервер зовёт только так, через `asyncio.to_thread`):
`plan(task, resource=None, patch=None, options=None, *, config)`, `load_plan(plan_id, *, config)`,
`brief_notes(config)`. `config` — `Config` сервера (`.home`, `.forge`, `.forge_profile`,
`.forge_home`); окружение процесса модуль не читает (в дочерний процесс forge уходит только
минимум системных переменных и `FACTORIO_FORGE_HOME` из `config.forge_home`). Чертёж лежит
в `FP_HOME/plans/<id>.txt`, метаданные — в `<id>.json`.

Что умеет forge и как мы его зовём
----------------------------------
forge проектирует ряды станков (`build` с блоками `rows`) и проверяет любой набор
сущностей; раскладки добычи у него нет. Поэтому для `task="mining"` раскладку буров
считает этот модуль (пары буров лицом к ленте, столбы — как у MPP, по прямоугольнику
пятна), а forge получает её как план из одних `entities` и делает то, что умеет сам:
проверяет по данным профиля сейва (неизвестные прототипы, разрыв электросети, ...),
соединяет столбы проводами и кодирует строку чертежа. Из CLI forge вызываются только
  - `list-profiles` — какой профиль активен (данные draftsman — общие на весь venv forge);
  - `build <plan.json> -o <папка> --no-render` — строка чертежа и отчёт `*.report.json`;
  - `notes [профиль]` — где лежит `notes.md` профиля.
Профили мы не активируем (`activate-profile` меняет общее состояние forge — это решение
хозяина): если нужный профиль не активен, ответ `{supported: false, reason}`.

Вызов — `subprocess.run` без shell, аргументы списком, `python -I -X utf8 -m
factorio_forge.cli`, таймаут; рабочая папка — временная в системном TEMP.
Строка чертежа хранится в `FP_HOME/plans/<id>.txt` и агенту не отдаётся: он получает только
id, якорь, размеры, список предметов и сводку.
"""

from __future__ import annotations

import json
import math
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "PlanArgsError",
    "plan",
    "brief_notes",
    "load_plan",
    "mining_layout",
    "DRILLS",
]

# --- лимиты и константы -------------------------------------------------------------

BUILD_TIMEOUT_S = 120          # forge build: ~2 с на малом плане, запас на холодный старт
QUERY_TIMEOUT_S = 60           # list-profiles / notes
MAX_AREA_SIDE = 256            # тайлов по стороне пятна
MAX_DRILLS = 300
MAX_BLUEPRINT_BYTES = 1_000_000  # MCP.md «Лимиты»: чертёж ≤ 1 МБ
MAX_NOTES_BYTES = 8_000          # notes.md в partner_brief (ответ агенту ≤ 24 КБ)
MAX_STDOUT_BYTES = 1_000_000
MAX_KEPT_PLANS = 200
STALE_WORK_S = 3600            # недописанные .tmp-* и старые work-* в plans — мусор после падения
MAX_COORD = 1_000_000          # граница карты Factorio — ±1 000 000 тайлов

PLAN_ID_RE = re.compile(r"^p-[0-9a-f]{16}$")   # подходит и под blob id `^[a-z0-9-]{1,32}$`
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
PROFILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

DIRECTIONS = {"north": 0, "east": 4, "south": 8, "west": 12}
DIRECTION_NAMES = {v: k for k, v in DIRECTIONS.items()}
RU_DIRECTION = {0: "север", 4: "восток", 8: "юг", 12: "запад"}


try:  # в составе пакета ошибка — PartnerError, и сервер отдаёт её агенту как bad_args
    from factorio_partner.errors import PartnerError as _PartnerError
except ImportError:  # forge.py загружен отдельно (тесты, ручной запуск)
    _PartnerError = None


if _PartnerError is not None:
    class PlanArgsError(_PartnerError, ValueError):
        """Аргументы `partner_plan` не прошли проверку (сервер отдаёт как `bad_args`)."""

        def __init__(self, text: str):
            _PartnerError.__init__(self, "bad_args", text)
else:
    class PlanArgsError(ValueError):  # type: ignore[no-redef]
        """Аргументы `partner_plan` не прошли проверку (сервер отдаёт как `bad_args`)."""

        code = "bad_args"

        def __init__(self, text: str):
            super().__init__(text)
            self.text = text


@dataclass(frozen=True)
class Drill:
    size: int                   # квадрат size×size тайлов
    powered: bool               # нужно электричество (столбы)
    categories: frozenset[str]  # resource_categories бура


DRILLS: dict[str, Drill] = {
    "burner-mining-drill": Drill(2, False, frozenset({"basic-solid"})),
    "electric-mining-drill": Drill(3, True, frozenset({"basic-solid"})),
    "big-mining-drill": Drill(5, True, frozenset({"basic-solid", "hard-solid"})),
}

# wire reach / supply radius ванильных столбов (для раскладки; forge всё равно проверяет сеть)
POLES: dict[str, tuple[float, float]] = {
    "small-electric-pole": (7.5, 2.5),
    "medium-electric-pole": (9.0, 3.5),
}
POLE_STEP = 6  # шаг столбов вдоль колонки: ≤ reach обоих столбов

HARD_SOLID = {"tungsten-ore"}
NEEDS_FLUID = {"uranium-ore"}
FLUID_RESOURCES = {"crude-oil", "lithium-brine", "sulfuric-acid-geyser", "fluorine-vent"}

OPTION_KEYS = {"drill", "belt", "direction", "pole"}


def _unsupported(reason: str) -> dict:
    return {"supported": False, "reason": reason}


# --- проверка аргументов --------------------------------------------------------------

def _num(value, what: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PlanArgsError(f"{what}: нужно число")
    value = float(value)
    if not math.isfinite(value) or abs(value) > MAX_COORD:
        raise PlanArgsError(f"{what}: число вне карты")
    return value


def _area(raw, what: str) -> tuple[int, int, int, int]:
    """area {left_top:{x,y}, right_bottom:{x,y}} → тайлы (left, top, width, height)."""
    if not isinstance(raw, dict):
        raise PlanArgsError(f"{what}: нужен объект {{left_top, right_bottom}}")
    lt, rb = raw.get("left_top"), raw.get("right_bottom")
    if not isinstance(lt, dict) or not isinstance(rb, dict):
        raise PlanArgsError(f"{what}: нужны left_top и right_bottom с x, y")
    x1, y1 = _num(lt.get("x"), f"{what}.left_top.x"), _num(lt.get("y"), f"{what}.left_top.y")
    x2, y2 = _num(rb.get("x"), f"{what}.right_bottom.x"), _num(rb.get("y"), f"{what}.right_bottom.y")
    left, top = math.floor(x1), math.floor(y1)
    right, bottom = math.ceil(x2), math.ceil(y2)
    width, height = right - left, bottom - top
    if width < 1 or height < 1:
        raise PlanArgsError(f"{what}: пустая область")
    if width > MAX_AREA_SIDE or height > MAX_AREA_SIDE:
        raise PlanArgsError(
            f"{what}: {width}×{height} тайлов, больше {MAX_AREA_SIDE} по стороне — возьми часть пятна"
        )
    return left, top, width, height


def _name(value, what: str) -> str:
    if not isinstance(value, str) or not NAME_RE.match(value):
        raise PlanArgsError(f"{what}: имя прототипа вида 'iron-ore'")
    return value


def _direction(value) -> int:
    if value is None:
        return 0
    if isinstance(value, str) and value.lower() in DIRECTIONS:
        return DIRECTIONS[value.lower()]
    if isinstance(value, int) and not isinstance(value, bool) and value in DIRECTION_NAMES:
        return value
    raise PlanArgsError("options.direction: north|east|south|west или 0|4|8|12 (куда лента выносит руду)")


@dataclass(frozen=True)
class MiningRequest:
    resource: str
    left: int
    top: int
    width: int
    height: int
    drill: str
    belt: str
    pole: str
    direction: int


def parse_args(args) -> MiningRequest | dict:
    """Проверить вход `partner_plan`. Ошибка формы → PlanArgsError; не умеем → {supported:false}."""
    if not isinstance(args, dict):
        raise PlanArgsError("аргументы — объект {task, resource|patch, options?}")
    unknown = set(args) - {"task", "resource", "patch", "options"}
    if unknown:
        raise PlanArgsError(f"лишние поля: {', '.join(sorted(map(str, unknown)))}")
    task = args.get("task")
    if not isinstance(task, str):
        raise PlanArgsError("task: строка, сейчас есть только 'mining'")
    if task != "mining":
        return _unsupported(f"forge-связка умеет только task='mining', не {task[:32]!r}")

    has_res, has_patch = args.get("resource") is not None, args.get("patch") is not None
    if has_res == has_patch:
        raise PlanArgsError("нужно ровно одно из resource {name, area} или patch (из partner_resources)")
    field = "resource" if has_res else "patch"
    src = args[field]
    if not isinstance(src, dict):
        raise PlanArgsError(f"{field}: объект с name и area")
    resource = _name(src.get("name"), f"{field}.name")
    left, top, width, height = _area(src.get("area"), f"{field}.area")

    options = args.get("options") or {}
    if not isinstance(options, dict):
        raise PlanArgsError("options: объект {drill?, belt?, direction?, pole?}")
    unknown = set(options) - OPTION_KEYS
    if unknown:
        raise PlanArgsError(f"options: лишние поля {', '.join(sorted(map(str, unknown)))}")

    if resource in FLUID_RESOURCES:
        return _unsupported(
            f"{resource} — жидкость: насосы forge не раскладывает; попроси хозяина поставить призраки "
            "(P.U.M.P.) и строй build_ghosts"
        )
    if resource in NEEDS_FLUID:
        return _unsupported(
            f"{resource} добывается с кислотой, трубы к бурам forge не раскладывает; попроси хозяина "
            "поставить призраки (MPP) и строй build_ghosts"
        )
    category = "hard-solid" if resource in HARD_SOLID else "basic-solid"

    if options.get("drill") is None:
        drill = "big-mining-drill" if category == "hard-solid" else "electric-mining-drill"
    else:
        drill = _name(options["drill"], "options.drill")
    if drill not in DRILLS:
        return _unsupported(
            f"бур {drill} раскладка не знает (есть: {', '.join(sorted(DRILLS))}); попроси хозяина "
            "поставить призраки (MPP) и строй build_ghosts"
        )
    if category not in DRILLS[drill].categories:
        return _unsupported(f"{drill} не добывает {resource}; нужен big-mining-drill")

    belt = _name(options.get("belt") or "transport-belt", "options.belt")
    pole = _name(options.get("pole") or "small-electric-pole", "options.pole")
    if DRILLS[drill].powered and pole not in POLES:
        return _unsupported(f"столб {pole} раскладка не знает (есть: {', '.join(sorted(POLES))})")

    return MiningRequest(resource, left, top, width, height, drill, belt, pole, _direction(options.get("direction")))


# --- раскладка буров ------------------------------------------------------------------

@dataclass(frozen=True)
class Placed:
    name: str
    x: int            # левый верхний тайл (как `position` в плане forge)
    y: int
    direction: int | None = None


@dataclass(frozen=True)
class Layout:
    entities: list[Placed]
    left: int
    top: int
    width: int
    height: int
    drills: int
    exits: list[tuple[int, int]]   # тайлы, куда лента выносит руду (за краем раскладки)

    @property
    def anchor(self) -> dict:
        """Центр раскладки — `position` для `LuaItemStack.build_blueprint` (ACTIONS.md).

        Игра ставит чертёж центром рамки его сущностей, а здесь центр прямоугольника
        раскладки. Они совпадают, потому что сущности заполняют все четыре края
        (крайние колонки столбов/буров и ряд-перемычка) — `mining_layout` это проверяет.
        """
        return {"x": self.left + self.width / 2, "y": self.top + self.height / 2}


def mining_layout(req: MiningRequest) -> Layout:
    """Пары буров лицом к ленте, лента течёт в `req.direction`, столбы между парами.

    Считается в «канонической» ориентации (лента течёт на север), затем поворачивается
    на `direction` сама — в мод чертёж уходит уже повёрнутым, `direction` = 0.
    Каноника (электрический бур s=3): столб-колонка | бур→ | лента ↑ | ←бур | столб-колонка | ...
    Ряд столбов-перемычек — под буровыми рядами (выше по течению ленты), чтобы не закрыть выходы.
    """
    drill = DRILLS[req.drill]
    s = drill.size
    turns = req.direction // 4
    # канонические размеры, которые надо покрыть (поворот на 90° меняет стороны)
    need_w, need_h = (req.width, req.height) if turns % 2 == 0 else (req.height, req.width)

    pad = 1 if drill.powered else 0
    stride = 2 * s + 1 + pad
    units = max(1, math.ceil((need_w - pad) / stride))
    rows = max(1, math.ceil((need_h - pad) / s))
    drills = 2 * units * rows
    if drills > MAX_DRILLS:
        raise PlanArgsError(
            f"на эту область нужно {drills} буров (> {MAX_DRILLS}) — возьми часть пятна поменьше"
        )
    cw, ch = pad + units * stride, rows * s + pad

    # (name, центр x, центр y, размер, направление) в канонических координатах
    canon: list[tuple[str, float, float, int, int | None]] = []
    belt_cols = []
    for u in range(units):
        x0 = pad + u * stride
        xb = x0 + s
        belt_cols.append(xb)
        for r in range(rows):
            y0 = r * s
            canon.append((req.drill, x0 + s / 2, y0 + s / 2, s, 4))           # лицом на восток
            canon.append((req.drill, xb + 1 + s / 2, y0 + s / 2, s, 12))      # лицом на запад
        for y in range(rows * s):
            canon.append((req.belt, xb + 0.5, y + 0.5, 1, 0))
    if drill.powered:
        reach = POLES[req.pole][0]  # supply (второе число) нужен тестам покрытия буров
        cols = [u * stride for u in range(units + 1)]
        for x in cols:
            for y in range(1, rows * s, POLE_STEP):
                canon.append((req.pole, x + 0.5, y + 0.5, 1, None))
        bridge = sorted(set(cols) | (set(belt_cols) if stride > reach else set()))
        for x in bridge:
            canon.append((req.pole, x + 0.5, rows * s + 0.5, 1, None))

    if turns % 2 == 0:
        width, height = cw, ch
    else:
        width, height = ch, cw

    def rotate(cx: float, cy: float) -> tuple[float, float]:
        if turns == 0:
            return cx, cy
        if turns == 1:
            return ch - cy, cx
        if turns == 2:
            return cw - cx, ch - cy
        return cy, cw - cx

    placed = []
    bbox = [math.inf, math.inf, -math.inf, -math.inf]
    for name, cx, cy, size, d in canon:
        rx, ry = rotate(cx, cy)
        tx, ty = rx - size / 2, ry - size / 2
        bbox = [min(bbox[0], tx), min(bbox[1], ty), max(bbox[2], tx + size), max(bbox[3], ty + size)]
        placed.append(Placed(
            name,
            req.left + int(round(tx)),
            req.top + int(round(ty)),
            None if d is None else (d + req.direction) % 16,
        ))

    # якорь (Layout.anchor) верен, только если рамка сущностей = прямоугольник раскладки;
    # не assert — тот выключается при python -O, а сдвиг на полтайла ломает стройку молча
    if bbox != [0, 0, width, height]:
        raise RuntimeError(f"раскладка: рамка сущностей {bbox} не совпала с {width}×{height}")

    exits = []
    for xb in belt_cols:
        ex, ey = rotate(xb + 0.5, -0.5)
        exits.append((req.left + math.floor(ex), req.top + math.floor(ey)))
    return Layout(placed, req.left, req.top, width, height, drills, exits)


def layout_to_forge_plan(layout: Layout, label: str) -> dict:
    entities = []
    for e in layout.entities:
        item = {"name": e.name, "position": [e.x, e.y]}
        if e.direction is not None:
            item["direction"] = e.direction
        entities.append(item)
    return {"label": label, "entities": entities}


# --- вызов forge ----------------------------------------------------------------------

class ForgeUnavailable(Exception):
    """forge не найден, упал или не ответил вовремя — уходит агенту как {supported:false}."""


def _forge_python(forge_path) -> Path:
    if not forge_path:
        raise ForgeUnavailable("FP_FORGE не задан — путь к checkout factorio-forge")
    root = Path(forge_path)
    for candidate in (root / ".venv" / "Scripts" / "python.exe", root / ".venv" / "bin" / "python"):
        if candidate.is_file():
            return candidate
    raise ForgeUnavailable(f"в {root} нет .venv с forge (ожидался .venv/Scripts/python.exe)")


# Только то, без чего процесс Python на Windows/Linux не стартует; остальное окружение
# сервера (пароль RCON, пути FP_*) в forge не передаётся.
_SYSTEM_ENV = ("SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "TEMP", "TMP", "TMPDIR", "PATH", "PATHEXT",
               "COMSPEC", "USERPROFILE", "HOME", "APPDATA", "LOCALAPPDATA", "LANG", "LC_ALL")


def _child_env(forge_home) -> dict:
    env = {k: os.environ[k] for k in _SYSTEM_ENV if k in os.environ}
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    if forge_home:
        env["FACTORIO_FORGE_HOME"] = str(forge_home)
    return env


def _run_forge(forge_path, argv: list[str], cwd: Path, timeout: float, *,
               forge_home=None) -> subprocess.CompletedProcess:
    """`python -I -X utf8 -m factorio_forge.cli <argv>`: без shell, аргументы списком."""
    if not all(isinstance(a, str) for a in argv):
        raise TypeError("argv: только строки")
    python = _forge_python(forge_path)
    env = _child_env(forge_home)
    kwargs = {}
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        proc = subprocess.run(
            [str(python), "-I", "-X", "utf8", "-m", "factorio_forge.cli", *argv],
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            shell=False,
            check=False,
            **kwargs,
        )
    except subprocess.TimeoutExpired as exc:
        raise ForgeUnavailable(f"forge {argv[0]} не ответил за {int(timeout)} с") from exc
    except OSError as exc:
        raise ForgeUnavailable(f"forge не запустился: {exc.__class__.__name__}") from exc
    return proc


def _text(raw: bytes | None) -> str:
    return (raw or b"")[:MAX_STDOUT_BYTES].decode("utf-8", errors="replace")


def _short(text: str, limit: int = 300) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


# абсолютные пути (C:\..., C:/..., \\share\..., /home/... и т.п.) — локальные папки хозяина
_ABS_PATH_RE = re.compile(r"(?:[A-Za-z]:[\\/]|\\\\|/(?:home|Users|mnt|tmp|var|opt|root)/)[^\s'\"<>|]*")


def _stderr_reason(raw: bytes | None, limit: int = 200) -> str:
    """Причина отказа из stderr forge для агента: последняя непустая строка (у трейсбека это
    само исключение), локальные пути хозяина заменены на `<путь>`, не длиннее `limit`."""
    lines = [ln.strip() for ln in _text(raw).splitlines() if ln.strip()]
    if not lines:
        return ""
    return _short(_ABS_PATH_RE.sub("<путь>", lines[-1]), limit)


class ProfileNameUnreadable(Exception):
    """Активный профиль forge есть, но имя не проходит PROFILE_RE (пробел, кириллица, ...)."""


def active_profile(forge_path, cwd: Path | None = None, forge_home=None) -> str | None:
    """Имя активного профиля forge (строка `* имя` в `list-profiles`); None — активного нет.

    Имя, которое не проходит PROFILE_RE, — `ProfileNameUnreadable`: профиль есть, но такое
    имя мы не пускаем ни в аргументы forge, ни в ответ агенту.
    """
    with tempfile.TemporaryDirectory(prefix="fp-forge-") as tmp:
        proc = _run_forge(forge_path, ["list-profiles"], Path(cwd or tmp), QUERY_TIMEOUT_S,
                          forge_home=forge_home)
    if proc.returncode != 0:
        raise ForgeUnavailable(f"forge list-profiles: {_stderr_reason(proc.stderr) or 'ошибка'}")
    for line in _text(proc.stdout).splitlines():
        if line.startswith("* "):
            name = line[2:].split(" ", 1)[0].strip()
            if not PROFILE_RE.match(name):
                raise ProfileNameUnreadable()
            return name
    return None


def _check_profile(profile) -> str | None:
    if profile in (None, ""):
        return None
    if not isinstance(profile, str) or not PROFILE_RE.match(profile):
        raise PlanArgsError("профиль forge: латиница, цифры, '.', '_', '-'")
    return profile


def _config_home(config) -> Path:
    home = getattr(config, "home", None)
    if not home:
        raise PlanArgsError("config.home: папка данных сервера не задана")
    return Path(home)


def _plans_dir(config) -> Path:
    d = _config_home(config) / "plans"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + f".tmp-{secrets.token_hex(4)}")
    tmp.write_text(text, encoding="utf-8", newline="")
    os.replace(tmp, path)


def _prune(plans: Path, keep: int = MAX_KEPT_PLANS) -> None:
    """Оставить `keep` свежих планов и убрать мусор после жёсткого падения процесса:
    недописанные `p-*.tmp-*` и рабочие папки `work-p-*` прежней версии старше STALE_WORK_S."""
    now = time.time()
    files = []
    for p in plans.iterdir():
        try:
            if p.suffix == ".txt" and PLAN_ID_RE.match(p.stem) and p.is_file():
                files.append(p)
            elif p.name.startswith("p-") and ".tmp-" in p.name and p.is_file():
                if now - p.stat().st_mtime > STALE_WORK_S:
                    p.unlink()
            elif p.name.startswith("work-p-") and p.is_dir() and not p.is_symlink():
                if now - p.stat().st_mtime > STALE_WORK_S:
                    shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass
    if len(files) <= keep:
        return
    files.sort(key=lambda p: p.stat().st_mtime)
    for p in files[: len(files) - keep]:
        for victim in (p, p.with_suffix(".json")):
            try:
                victim.unlink()
            except OSError:
                pass


def _problems(report: dict) -> list[str]:
    out = []
    for f in report.get("findings") or []:
        if isinstance(f, dict) and f.get("severity") == "problem":
            summary, code = f.get("summary"), f.get("code")
            text = str(summary or code or "problem")
            # код finding'а (`unknown-prototypes`, `pole-isolated`, ...) стабильнее текста
            if summary and isinstance(code, str) and code:
                text += f" [{code[:64]}]"
            out.append(text)
    return out


def _summary(req: MiningRequest, layout: Layout, items: Counter, report: dict) -> str:
    exits = layout.exits
    shown = ", ".join(f"({x},{y})" for x, y in exits[:4]) + (" …" if len(exits) > 4 else "")
    parts = [
        f"{layout.drills}× {req.drill} на {req.resource}: прямоугольник {layout.width}×{layout.height} "
        f"от ({layout.left},{layout.top}), лент {len(exits)}, руда течёт на {RU_DIRECTION[req.direction]}, "
        f"выходы лент: {shown}.",
        "Раскладка по прямоугольнику пятна: буры по краям могут стоять без руды — проверь dry_run.",
    ]
    if DRILLS[req.drill].powered:
        parts.append(f"Столбы {req.pole} в одной сети; подвести питание к раскладке — отдельно.")
    else:
        parts.append("Бурам нужно топливо.")
    suspects = [
        str(f.get("summary")) for f in report.get("findings") or []
        if isinstance(f, dict) and f.get("severity") == "suspect"
    ]
    if suspects:
        parts.append("forge сомневается: " + "; ".join(suspects[:3]) + ".")
    return " ".join(parts)


def plan(task, resource=None, patch=None, options=None, *, config) -> dict:
    """`partner_plan`: спроектировать раскладку через forge и сохранить чертёж.

    Возвращает `{plan, anchor, direction, items, size:{w,h}, summary}` или
    `{supported: false, reason}`; на сбоях forge не бросает. Неверная форма аргументов —
    `PlanArgsError` (`.code == "bad_args"`). Путь к forge, профиль, FP_HOME и дом forge берутся
    из `config` (`Config` сервера), окружение процесса не читается.
    """
    req = parse_args({"task": task, "resource": resource, "patch": patch, "options": options})
    if isinstance(req, dict):
        return req

    forge_path = getattr(config, "forge", None)
    forge_home = getattr(config, "forge_home", None)
    profile = _check_profile(getattr(config, "forge_profile", None))
    forge_path = str(forge_path) if forge_path else None
    layout = mining_layout(req)
    plans = _plans_dir(config)

    plan_id = "p-" + secrets.token_hex(8)
    # рабочая папка — в системном TEMP: после жёсткого падения процесса она не копится в FP_HOME
    work = Path(tempfile.mkdtemp(prefix=f"fp-work-{plan_id}-"))
    try:
        try:
            active = active_profile(forge_path, cwd=work, forge_home=forge_home)
        except ProfileNameUnreadable:
            return _unsupported(
                "активный профиль forge есть, но его имя не разобрал (допустимы латиница, цифры, "
                "'.', '_', '-'); попроси хозяина переименовать профиль или поставить призраки (MPP)"
            )
        except ForgeUnavailable as exc:
            return _unsupported(f"forge недоступен: {exc}; попроси хозяина поставить призраки (MPP)")
        if active is None:
            return _unsupported("в forge нет активного профиля сейва; попроси хозяина активировать профиль")
        if profile and profile != active:
            return _unsupported(
                f"нужен профиль forge {profile!r}, а активен {active!r}; активировать профиль — решение хозяина"
            )
        label = f"partner-{plan_id}"
        plan_file = work / "plan.json"
        plan_file.write_text(json.dumps(layout_to_forge_plan(layout, label)), encoding="utf-8")
        out = work / "out"
        try:
            proc = _run_forge(forge_path, ["build", str(plan_file), "-o", str(out), "--no-render"],
                              work, BUILD_TIMEOUT_S, forge_home=forge_home)
        except ForgeUnavailable as exc:
            return _unsupported(f"forge недоступен: {exc}")
        if proc.returncode != 0:
            return _unsupported(f"forge build не собрал раскладку: {_stderr_reason(proc.stderr) or 'ошибка'}")
        try:
            blueprint = (out / f"{label}.txt").read_text(encoding="utf-8").strip()
            report = json.loads((out / f"{label}.report.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            return _unsupported(f"forge build не оставил чертёж и отчёт: {exc.__class__.__name__}")
        if not isinstance(report, dict):
            return _unsupported("forge build: отчёт не объект")
        problems = _problems(report)
        if problems:
            return _unsupported(
                f"forge нашёл проблемы (профиль {active}): " + _short("; ".join(problems[:3]))
                + " — проверь options.drill/belt/pole или попроси хозяина поставить призраки"
            )
        if (not blueprint or len(blueprint.encode("utf-8")) > MAX_BLUEPRINT_BYTES
                or not blueprint.isascii() or not blueprint.startswith("0")):
            return _unsupported("forge вернул чертёж не того вида или больше 1 МБ")

        items = Counter(e.name for e in layout.entities)
        result = {
            "plan": plan_id,
            "anchor": layout.anchor,
            "direction": 0,  # чертёж уже повёрнут под options.direction
            "items": dict(sorted(items.items())),
            "size": {"w": layout.width, "h": layout.height},
            "summary": _summary(req, layout, items, report),
        }
        meta = {
            "plan": plan_id,
            "created": int(time.time()),
            "profile": active,
            "task": "mining",
            "resource": req.resource,
            "drill": req.drill,
            "belt": req.belt,
            "pole": req.pole,
            "flow": DIRECTION_NAMES[req.direction],
            "area": {"left": req.left, "top": req.top, "w": req.width, "h": req.height},
            **{k: result[k] for k in ("anchor", "direction", "items", "size")},
        }
        _atomic_write(plans / f"{plan_id}.txt", blueprint)
        _atomic_write(plans / f"{plan_id}.json", json.dumps(meta, ensure_ascii=False))
        _prune(plans)
        return result
    finally:
        shutil.rmtree(work, ignore_errors=True)


def load_plan(plan_id, *, config) -> str:
    """Строка чертежа по id из `partner_plan` (сервер грузит её в мод через `blob_put`).

    Неверный или неизвестный id — `PlanArgsError`.
    """
    if not isinstance(plan_id, str) or not PLAN_ID_RE.match(plan_id):
        raise PlanArgsError("plan: id из partner_plan вида p-<16 hex>")
    path = _config_home(config) / "plans" / f"{plan_id}.txt"
    try:
        text = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        raise PlanArgsError("plan: нет такого плана (устарел или не создавался)") from None
    except (OSError, UnicodeDecodeError):
        raise PlanArgsError("plan: сохранённый чертёж не читается") from None
    if not text or len(text.encode("utf-8")) > MAX_BLUEPRINT_BYTES:
        raise PlanArgsError("plan: сохранённый чертёж повреждён")
    return text


# --- заметки профиля для partner_brief -----------------------------------------------

def brief_notes(config) -> dict:
    """`notes.md` профиля сейва forge — единственный источник заметок для `partner_brief`.

    Профиль — `config.forge_profile`, иначе активный профиль forge. Путь узнаём у forge
    (`notes [профиль]`), сам файл читаем здесь, не больше MAX_NOTES_BYTES.
    Возвращает `{profile, notes, truncated}`; если не вышло — `{profile, notes: "",
    truncated: false, reason}`. Содержимое — записи хозяина: для агента данные, не команды.
    """
    max_bytes = MAX_NOTES_BYTES
    try:
        profile = _check_profile(getattr(config, "forge_profile", None))
    except PlanArgsError as exc:
        return {"profile": None, "notes": "", "truncated": False, "reason": str(exc)}
    forge_path = getattr(config, "forge", None)
    forge_home = getattr(config, "forge_home", None)

    def empty(reason: str) -> dict:
        return {"profile": profile, "notes": "", "truncated": False, "reason": reason}

    try:
        with tempfile.TemporaryDirectory(prefix="fp-forge-") as tmp:
            proc = _run_forge(str(forge_path) if forge_path else None,
                              ["notes", *([profile] if profile else [])], Path(tmp), QUERY_TIMEOUT_S,
                              forge_home=forge_home)
    except ForgeUnavailable as exc:
        return empty(f"forge недоступен: {exc}")
    if proc.returncode != 0:
        return empty(f"forge notes: {_stderr_reason(proc.stderr) or 'ошибка'}")

    notes_path = profile_dir = None
    for line in _text(proc.stdout).splitlines():
        key, _, value = line.partition(":")
        value = value.strip()
        if key.strip() == "profile":
            profile_dir = Path(value)
        elif key.strip() == "notes":
            if value.endswith(" (missing)"):
                return {**empty("у профиля нет notes.md"), "profile": profile or (profile_dir and profile_dir.name)}
            notes_path = Path(value)
    if notes_path is None or notes_path.name != "notes.md":
        return empty("forge notes: не понял ответ")
    name = profile or (profile_dir.name if profile_dir else None)
    try:
        with notes_path.open("rb") as fh:
            raw = fh.read(max_bytes + 1)
    except OSError as exc:
        return {**empty(f"notes.md не читается: {exc.__class__.__name__}"), "profile": name}
    truncated = len(raw) > max_bytes
    raw = raw[:max_bytes]
    text = raw.decode("utf-8", errors="replace")
    if truncated:
        text = text.rstrip("\ufffd")  # обрезанный посередине последний символ
    if text.startswith("\ufeff"):
        text = text[1:]
    return {"profile": name, "notes": text, "truncated": truncated}
