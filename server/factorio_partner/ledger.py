"""Build packages of the strategist, kept per save (docs/MCP.md «Пакеты стройки»).

A package is a named plan of ``plan`` steps with an anchor, a priority and 1..3 checks. Only the
strategist writes packages (``partner_ledger``); the server itself (orders.py) starts them on an idle
body and checks the result. The file lives next to the save's notes (savenotes.py) and outlives a
restart of the server:

    <FP_NOTES_DIR or <repo>/save-notes>/<save>/packages.json

    {"version": 1, "rev": N, "next": N, "packages": [...], "history": [...]}

``packages`` — open packages (``queued``, ``posting``, ``running``, ``pausing``, ``paused``,
``verifying``);
``history`` — the last finished ones (``verified``, ``unmet``, ``failed``, ``cancelled``), without
steps. Every change goes through ``mutate``: a lock file, a fresh read of the file, the change, an
atomic write — two server processes (two sessions on one save) never lose each other's change.
The bridge of one process at a time drives the packages (``take_lease``).
"""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Callable, Iterator
from contextlib import contextmanager

from . import savenotes
from .bridge import HELPER_RE
from .errors import PartnerError

log = logging.getLogger("factorio_partner.ledger")

FILE = "packages.json"
VERSION = 1
ACTIVE = ("queued", "posting", "running", "pausing", "paused")     # count towards ACTIVE_MAX
OPEN = ACTIVE + ("verifying",)
DONE = ("verified", "unmet", "failed", "cancelled")
ACTIVE_MAX = 2              # active packages per helper
HISTORY_MAX = 10
PRIORITY_RANK = {"now": 0, "next": 1, "later": 2}
LOCK_WAIT = 3.0             # s: how long a change waits for the lock of another process
LOCK_STALE = 10.0           # s: a lock file older than this was left by a dead process
LEASE_TTL = 60.0            # s: the bridge of one process drives the packages of a save (renewed per helper)


def path_for(save: str) -> Path:
    return savenotes.root() / save / FILE


def _empty() -> dict:
    return {"version": VERSION, "rev": 0, "next": 1, "packages": [], "history": []}


def _well_formed(data: Any) -> bool:
    return (isinstance(data, dict) and isinstance(data.get("packages"), list)
            and isinstance(data.get("history"), list) and isinstance(data.get("rev"), int)
            and isinstance(data.get("next"), int))


def compact(p: dict) -> dict:
    """A package without its steps (lists, events, answers): ``steps_n`` instead."""
    out = {k: v for k, v in p.items() if k != "steps"}
    if isinstance(p.get("steps"), list):
        out["steps_n"] = len(p["steps"])
    return out


class Ledger:
    """The packages file of one save. Reads are cached by mtime; changes go through ``mutate``."""

    def __init__(self, save: str):
        self.save = save
        self.path = path_for(save)
        self._lock_path = self.path.with_name(FILE + ".lock")
        self._lease_path = self.path.with_name(FILE + ".lease")
        self._data: dict = _empty()
        self._stamp: tuple[int, int] | None = None

    # ------------------------------------------------------------------ reading
    def _read(self) -> dict:
        try:
            st = self.path.stat()
        except OSError:
            self._data, self._stamp = _empty(), None
            return self._data
        stamp = (st.st_mtime_ns, st.st_size)
        if stamp == self._stamp:
            return self._data
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            log.warning("packages file of save %s is not JSON; keeping the last good copy", self.save)
            return self._data
        if not _well_formed(data):
            log.warning("packages file of save %s has a bad shape; keeping the last good copy", self.save)
            return self._data
        self._data, self._stamp = data, stamp
        return data

    def data(self) -> dict:
        return self._read()

    def open_of(self, helper: str) -> list[dict]:
        return [p for p in self._read()["packages"]
                if isinstance(p, dict) and p.get("helper") == helper and p.get("status") in OPEN
                and isinstance(p.get("id"), str)]

    def get(self, helper: str, pid: str) -> dict | None:
        d = self._read()
        for p in d["packages"] + d["history"]:
            if p.get("id") == pid and p.get("helper") == helper:
                return p
        return None

    def helpers(self) -> set[str]:
        return {p["helper"] for p in self._read()["packages"]
                if isinstance(p, dict) and isinstance(p.get("helper"), str) and HELPER_RE.match(p["helper"])
                and p.get("status") in OPEN}

    # ------------------------------------------------------------------ changing
    @contextmanager
    def _locked(self) -> Iterator[None]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fd = os.open(self._lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode("ascii"))
                os.close(fd)
                break
            except FileExistsError:
                try:
                    if time.time() - self._lock_path.stat().st_mtime > LOCK_STALE:
                        self._lock_path.unlink()
                        continue
                except OSError:
                    continue
                if time.monotonic() > deadline:
                    raise PartnerError("internal", "the packages file is locked by another server process") from None
                time.sleep(0.02)
        try:
            yield
        finally:
            try:
                self._lock_path.unlink()
            except OSError:
                pass

    def mutate(self, fn: Callable[[dict], Any]) -> Any:
        """Lock, read the file afresh, ``fn(data)``, write it back atomically if ``fn`` changed it
        (``rev`` grows by one per change). Returns what ``fn`` returned."""
        with self._locked():
            self._stamp = None
            data = self._read()
            data = json.loads(json.dumps(data))          # fn works on a copy: a raise changes nothing
            before = json.dumps(data, sort_keys=True)
            out = fn(data)
            if json.dumps(data, sort_keys=True) != before:
                data["rev"] = int(data.get("rev", 0)) + 1
                _prune(data)
                tmp = self.path.with_name(FILE + f".{os.getpid()}.tmp")
                tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
                os.replace(tmp, self.path)
                self._stamp = None
                self._read()
            return out

    # ------------------------------------------------------------------ the bridge's lease
    def take_lease(self, owner: str, now: float | None = None) -> bool:
        """True if the bridge of ``owner`` may drive the packages of this save now: the lease is
        free, expired or already its own. The lease is renewed on every success. The read and the
        write go under the lock of the file, so two processes never both win a free lease."""
        try:
            with self._locked():
                now = time.time() if now is None else now
                try:
                    cur = json.loads(self._lease_path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    cur = None
                if (isinstance(cur, dict) and cur.get("owner") != owner
                        and isinstance(cur.get("until"), (int, float)) and cur["until"] > now):
                    return False
                tmp = self._lease_path.with_name(FILE + f".lease.{os.getpid()}.tmp")
                tmp.write_text(json.dumps({"owner": owner, "until": now + LEASE_TTL}), encoding="utf-8")
                os.replace(tmp, self._lease_path)
        except (OSError, PartnerError):
            return False
        return True

def _prune(data: dict) -> None:
    """Finished packages leave ``packages`` for ``history`` (without steps); history keeps the last ones."""
    keep, done = [], []
    for p in data["packages"]:
        (done if p.get("status") in DONE else keep).append(p)
    data["packages"] = keep
    data["history"] = (data["history"] + [compact(p) for p in done])[-HISTORY_MAX:]


def find(data: dict, pid: str) -> dict | None:
    for p in data["packages"]:
        if p.get("id") == pid:
            return p
    return None


def add(data: dict, helper: str, clean: dict, tick: int | None, rev: int | None = None) -> dict:
    """Put a checked package (validate.check_package) into ``data`` as ``queued``."""
    if rev is not None and rev != data.get("rev"):
        raise PartnerError("bad_args", f"rev: the packages changed (rev {data.get('rev')}); read them again")
    active = [p for p in data["packages"] if p.get("helper") == helper and p.get("status") in ACTIVE]
    if len(active) >= ACTIVE_MAX:
        raise PartnerError("limit", f"at most {ACTIVE_MAX} active packages per helper; cancel one or "
                                    "wait for one to finish")
    n = int(data.get("next", 1))
    data["next"] = n + 1
    pkg = dict(clean, id=f"pk{n}", n=n, helper=helper, status="queued", created_tick=tick, from_step=1)
    data["packages"].append(pkg)
    return pkg


def next_up(pkgs: list[dict]) -> list[dict]:
    """Queued packages of one helper in the order they start: priority, then age."""
    q = [p for p in pkgs if p.get("status") == "queued"]
    return sorted(q, key=lambda p: (PRIORITY_RANK.get(p.get("priority"), 1), p.get("n", 0)))
