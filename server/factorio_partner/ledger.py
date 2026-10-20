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
steps; ``notes`` — the strategist's last note on the work, one per helper; ``questions`` — his
questions to the owner per helper (``open`` / ``answered``), ``qnext`` numbers them. Notes and
questions do not move ``rev``: ``rev`` guards the packages only. Every change goes through ``mutate``: a lock file, a fresh read of the file, the change, an
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
NOTE_MAX = 200              # characters of the strategist's note on the work
QUESTION_MAX = 200          # characters of a question to the owner
QUESTIONS_OPEN_MAX = 5      # open questions per helper
QUESTIONS_KEEP = 5          # answered questions kept per helper
ANSWER_SAID_MAX = 200       # characters of the owner's answer kept on the question
REMIND_AFTER = 10 * 60.0   # s: an open question unanswered this long is reminded once
_SIDE = ("notes", "questions", "qnext", "thoughts")      # parts of the file that do not move rev

now = time.time             # wall clock of notes and questions: it outlives a restart (tests patch it)


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
            before_pk = _packages_part(data)
            out = fn(data)
            if json.dumps(data, sort_keys=True) != before:
                if _packages_part(data) != before_pk:
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

def _packages_part(data: dict) -> str:
    return json.dumps({k: v for k, v in data.items() if k not in _SIDE and k != "rev"}, sort_keys=True)


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


# ---------------------------------------------------------------- the strategist's note and questions
def _side(data: dict, part: str) -> dict:
    v = data.get(part)
    if not isinstance(v, dict):
        v = data[part] = {}
    return v


def note_of(data: dict, helper: str) -> dict | None:
    v = data.get("notes")
    n = v.get(helper) if isinstance(v, dict) else None
    return n if isinstance(n, dict) and isinstance(n.get("text"), str) else None


def set_note(data: dict, helper: str, text: str, tick: int | None) -> dict:
    """The strategist's one last note on the work of a helper: a new one replaces the old."""
    n = {"text": text, "at": now(), "tick": tick}
    _side(data, "notes")[helper] = n
    return dict(n)


def thoughts_on(data: dict, helper: str) -> bool:
    v = data.get("thoughts")
    return isinstance(v, dict) and v.get(helper) is True


def set_thoughts(data: dict, helper: str, on: bool) -> bool:
    """The owner's switch «show the strategist's thoughts» of a helper (off by default)."""
    t = _side(data, "thoughts")
    if on:
        t[helper] = True
    else:
        t.pop(helper, None)
    return on


def questions_of(data: dict, helper: str) -> list[dict]:
    v = data.get("questions")
    qs = v.get(helper) if isinstance(v, dict) else None
    return [q for q in qs if isinstance(q, dict) and isinstance(q.get("id"), str)] if isinstance(qs, list) else []


def open_questions(data: dict, helper: str) -> list[dict]:
    return [q for q in questions_of(data, helper) if q.get("status") == "open"]


def ask(data: dict, helper: str, text: str, tick: int | None, order: str | None = None) -> dict:
    """A new open question of the strategist to the owner (``q<N>``); at most QUESTIONS_OPEN_MAX open.
    ``order`` — the owner's order the question is about (the leave for a package of that order)."""
    if len(open_questions(data, helper)) >= QUESTIONS_OPEN_MAX:
        raise PartnerError("limit", f"at most {QUESTIONS_OPEN_MAX} open questions per helper; wait for "
                                    "the owner's answers")
    n = int(data.get("qnext", 1)) if isinstance(data.get("qnext"), int) else 1
    data["qnext"] = n + 1
    q = {"id": f"q{n}", "text": text, "status": "open", "at": now(), "tick": tick}
    if order is not None:
        q["order"] = order
    qs = _side(data, "questions").setdefault(helper, [])
    qs.append(q)
    _keep_questions(data, helper)
    return dict(q)


def answer(data: dict, helper: str, qid: str, order_id: str, said: str | None = None) -> dict:
    """Close an open question: the owner's answer came as the order ``order_id``; ``said`` — his own
    words (kept: a package's leave is refused when he said no)."""
    for q in questions_of(data, helper):
        if q["id"] == qid:
            if q.get("status") != "open":
                raise PartnerError("bad_args", f"answer_to: question {qid} is already {q.get('status')}")
            q.update(status="answered", answer=order_id, answered_at=now())
            if isinstance(said, str):
                q["said"] = said[:ANSWER_SAID_MAX]
            _keep_questions(data, helper)
            return dict(q)
    raise PartnerError("not_found", f"answer_to: no question {qid}")


def due_reminders(data: dict, helper: str, at: float | None = None) -> list[dict]:
    """Open questions unanswered REMIND_AFTER seconds and not reminded yet: they are marked reminded."""
    t = now() if at is None else at
    out = []
    for q in open_questions(data, helper):
        if not q.get("reminded") and isinstance(q.get("at"), (int, float)) and t - q["at"] >= REMIND_AFTER:
            q["reminded"] = t
            out.append(dict(q))
    return out


def _keep_questions(data: dict, helper: str) -> None:
    qs = _side(data, "questions").get(helper)
    if not isinstance(qs, list):
        return
    opened = [q for q in qs if isinstance(q, dict) and q.get("status") == "open"]
    closed = [q for q in qs if isinstance(q, dict) and q.get("status") != "open"][-QUESTIONS_KEEP:]
    keep = {id(q) for q in opened + closed}
    qs[:] = [q for q in qs if id(q) in keep]


# ---------------------------------------------------------------- the owner's leave for a package
_NO_START = ("нет", "неа", "no", "нельзя", "отказ", "стоп")
_NO_PHRASES = ("не надо", "не бери", "не трогай", "не смей", "не нужно", "не стоит", "нельзя", "запрещаю",
               "не разрешаю", "не забирай")


def said_no(text: Any) -> bool:
    """The owner's answer reads as a refusal («нет», «не бери», «нельзя»): no leave, whatever the
    strategist thinks it means."""
    if not isinstance(text, str):
        return False
    t = " ".join(text.lower().replace("ё", "е").split())
    words = [w.strip(".,!?:;—-«»\"'()") for w in t.split()]
    words = [w for w in words if w]
    if words and words[0] in _NO_START:
        return True
    return any(p in t for p in _NO_PHRASES)


def leave_problem(data: dict, scope: str, pkg: dict, order_tick: Any) -> str | None:
    """Why the package may not take from the owner (None — it may): ``approved`` names a question of
    the strategist (of ``scope``) the owner answered, about the package's ``order`` — the question
    names that order, or was asked after it came (``order_tick``) — and the answer is not «нет»."""
    qid, oid = pkg.get("approved"), pkg.get("order")
    if not isinstance(qid, str) or not isinstance(oid, str):
        return "approved: a step takes from the owner — the package needs order and approved (q<N>)"
    q = next((x for x in questions_of(data, scope) if x["id"] == qid), None)
    if q is None:
        return f"approved: нет вопроса {qid} (partner_ledger list → questions)"
    if q.get("status") != "answered":
        return (f"approved: на вопрос {qid} хозяин ещё не ответил ({q.get('status')}); дождись ответа "
                "(поручение с answer_to)")
    if q.get("order") is not None:
        if q["order"] != oid:
            return f"approved: вопрос {qid} задан про поручение {q['order']}, а пакет — для {oid}"
    elif not (isinstance(order_tick, int) and isinstance(q.get("tick"), int) and q["tick"] >= order_tick):
        return (f"approved: вопрос {qid} не про поручение {oid} (задан раньше него или без order); "
                f"спроси заново: partner_ledger{{action:\"ask\", order:\"{oid}\"}}")
    if said_no(q.get("said")):
        return f"approved: хозяин ответил на {qid} отказом: забирать нельзя"
    return None
