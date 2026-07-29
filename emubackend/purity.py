"""Mechanical enforcement of A8: the BE and FE checkouts stay untouched.

A8 is stated as a rule, and rules stated in prose get broken by accident — an editable
install that regenerates an ignored ``egg-info/``, a stray ``__pycache__``, a test that
writes a fixture into the wrong tree, a tool that reformats on save. The recipe's
definition of done requires that *"both existing repos show zero modifications"*, which
is only meaningful if something checks.

This module is that check. It is deliberately paranoid in three ways that a naive
``git status`` eyeball is not:

1. **``.gitignore`` is not a defence.** The BE ignores ``build/``, ``dist/`` and
   ``*.egg-info/``, so writes there are invisible to ``git status`` while still
   mutating a checkout a live daemon runs from. Those directories are therefore
   fingerprinted by content, not trusted to git.
2. **New untracked files are violations too.** A baseline records the untracked paths
   that already existed; anything appearing later is flagged. Otherwise "no
   modifications" would silently permit dropping new files into the BE.
3. **HEAD is pinned.** Committing to the BE is a modification even when the working
   tree ends up clean.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

__all__ = [
    "GUARDED_REPOS",
    "PurityViolation",
    "RepoState",
    "assert_pristine",
    "capture",
    "compare",
    "load_baseline",
    "no_queue_writes",
    "queue_census",
    "save_baseline",
]

#: Repo directory names, relative to the SuperResearch parent dir, that A8 protects.
GUARDED_REPOS = ("dg-research-backend", "dg-research")

#: Ignored-but-live directories that git will not report on. Fingerprinted by content
#: so an editable install or a stray build cannot hide behind .gitignore. Only
#: directories that *nothing legitimate* writes to during normal operation belong here.
_IGNORED_BUT_LIVE = ("build", "dist", "superresearch.egg-info")

#: ``queues/`` is deliberately NOT in the list above. The production daemon writes a run
#: directory there on every real research run, so a content digest compared against a
#: stored baseline would go red for reasons that have nothing to do with us — and a guard
#: that cries wolf is a guard that gets switched off. It still needs watching, because
#: ``setup_firestore_run`` writing ``owner.json`` into ``queues/<run_id>`` is precisely
#: the contamination A8 most fears. The right granularity is therefore *session-scoped*:
#: census the directory before and after a piece of our own work, where nothing
#: legitimate should appear. See :func:`queue_census` and :func:`no_queue_writes`.
_VOLATILE = ("queues",)

_BASELINE_PATH = Path(__file__).resolve().parent.parent / "fixtures" / "a8_baseline.json"


class PurityViolation(AssertionError):
    """A guarded repo was modified. Carries a human-readable, itemised report."""


@dataclass
class RepoState:
    """A fingerprint of one guarded repo at a point in time."""

    name: str
    head: str
    #: porcelain entries for *tracked* changes, e.g. " M research.py"
    tracked_changes: list[str] = field(default_factory=list)
    #: untracked paths, sorted
    untracked: list[str] = field(default_factory=list)
    #: name -> content digest for the ignored-but-live dirs (absent dirs are omitted)
    ignored_digests: dict[str, str] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "head": self.head,
            "tracked_changes": self.tracked_changes,
            "untracked": self.untracked,
            "ignored_digests": self.ignored_digests,
        }

    @classmethod
    def from_json(cls, raw: dict) -> RepoState:
        return cls(
            name=raw["name"],
            head=raw["head"],
            tracked_changes=list(raw.get("tracked_changes", [])),
            untracked=list(raw.get("untracked", [])),
            ignored_digests=dict(raw.get("ignored_digests", {})),
        )


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise PurityViolation(
            f"git {' '.join(args)} failed in {repo}: {proc.stderr.strip()}"
        )
    return proc.stdout


def _digest_tree(root: Path) -> str:
    """Content digest of a directory tree: sorted (relpath, size, sha256-of-bytes).

    Deliberately excludes mtime. A tool that rewrites a file with identical content has
    not meaningfully modified the checkout, and flagging that would make the guard noisy
    enough to be ignored — which is how guards die.
    """
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        try:
            data = p.read_bytes()
        except OSError:
            continue
        h.update(rel.encode())
        h.update(str(len(data)).encode())
        h.update(hashlib.sha256(data).digest())
    return h.hexdigest()


def capture(parent: Path | None = None) -> dict[str, RepoState]:
    """Fingerprint every guarded repo. *parent* defaults to this repo's parent dir."""
    parent = parent or Path(__file__).resolve().parent.parent.parent
    states: dict[str, RepoState] = {}
    for name in GUARDED_REPOS:
        repo = parent / name
        if not repo.is_dir():
            continue
        porcelain = _git(repo, "status", "--porcelain=v1").splitlines()
        tracked, untracked = [], []
        for line in porcelain:
            if line.startswith("?? "):
                untracked.append(line[3:])
            elif line.strip():
                tracked.append(line)
        digests = {
            d: _digest_tree(repo / d) for d in _IGNORED_BUT_LIVE if (repo / d).is_dir()
        }
        states[name] = RepoState(
            name=name,
            head=_git(repo, "rev-parse", "HEAD").strip(),
            tracked_changes=sorted(tracked),
            untracked=sorted(untracked),
            ignored_digests=digests,
        )
    return states


def save_baseline(path: Path | None = None, parent: Path | None = None) -> Path:
    """Record the current state as the A8 baseline."""
    path = path or _BASELINE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    states = capture(parent)
    path.write_text(
        json.dumps(
            {name: st.to_json() for name, st in sorted(states.items())},
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return path


def load_baseline(path: Path | None = None) -> dict[str, RepoState]:
    path = path or _BASELINE_PATH
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {name: RepoState.from_json(st) for name, st in raw.items()}


def compare(
    baseline: dict[str, RepoState], current: dict[str, RepoState]
) -> list[str]:
    """Return an itemised list of A8 violations; empty means pristine."""
    problems: list[str] = []
    for name, base in sorted(baseline.items()):
        cur = current.get(name)
        if cur is None:
            problems.append(f"{name}: repo has disappeared since the baseline")
            continue
        if cur.head != base.head:
            problems.append(
                f"{name}: HEAD moved {base.head[:12]} -> {cur.head[:12]} "
                f"(committing to a guarded repo is a modification)"
            )
        new_tracked = sorted(set(cur.tracked_changes) - set(base.tracked_changes))
        if new_tracked:
            problems.append(
                f"{name}: tracked files changed:\n    " + "\n    ".join(new_tracked)
            )
        new_untracked = sorted(set(cur.untracked) - set(base.untracked))
        if new_untracked:
            problems.append(
                f"{name}: new untracked paths appeared:\n    "
                + "\n    ".join(new_untracked)
            )
        for d, base_digest in sorted(base.ignored_digests.items()):
            cur_digest = cur.ignored_digests.get(d)
            if cur_digest is None:
                problems.append(f"{name}: ignored-but-live dir {d!r} was removed")
            elif cur_digest != base_digest:
                problems.append(
                    f"{name}: contents of {d!r} changed — .gitignore hid this from "
                    f"git status, which is exactly why it is fingerprinted"
                )
        appeared = sorted(set(cur.ignored_digests) - set(base.ignored_digests))
        if appeared:
            problems.append(
                f"{name}: ignored-but-live dir(s) newly created: {', '.join(appeared)} "
                f"(an editable install of the BE would do this)"
            )
    return problems


def queue_census(parent: Path | None = None) -> dict[str, set[str]]:
    """Census the volatile dirs: repo -> set of relative paths currently present.

    Used for the session-scoped guard rather than the stored baseline, because the
    production daemon writes here legitimately (see :data:`_VOLATILE`).
    """
    parent = parent or Path(__file__).resolve().parent.parent.parent
    census: dict[str, set[str]] = {}
    for name in GUARDED_REPOS:
        repo = parent / name
        for d in _VOLATILE:
            target = repo / d
            if target.is_dir():
                census[f"{name}/{d}"] = {
                    p.relative_to(target).as_posix() for p in target.rglob("*")
                }
    return census


@contextmanager
def no_queue_writes(parent: Path | None = None):
    """Assert that the guarded repos' volatile dirs gain nothing inside this block.

    Scoped to a block rather than to a stored baseline so that a concurrent real
    research run cannot make it fail: the daemon would have to create a run directory
    inside this exact window, which is rare, and if it does the report names the paths
    so the cause is obvious rather than mysterious.
    """
    before = queue_census(parent)
    try:
        yield
    finally:
        after = queue_census(parent)
        appeared: list[str] = []
        for key, paths in sorted(after.items()):
            new = sorted(paths - before.get(key, set()))
            if new:
                appeared.append(f"{key}: {', '.join(new[:20])}")
        if appeared:
            raise PurityViolation(
                "A8 VIOLATED — paths appeared under a guarded repo's volatile dirs "
                "during this block. If our code called setup_firestore_run (or anything "
                "that arms it), that is the cause:\n\n"
                + "\n".join(f"  - {a}" for a in appeared)
            )


def assert_pristine(
    baseline_path: Path | None = None, parent: Path | None = None
) -> None:
    """Raise :class:`PurityViolation` unless every guarded repo matches the baseline."""
    problems = compare(load_baseline(baseline_path), capture(parent))
    if problems:
        raise PurityViolation(
            "A8 VIOLATED — dg-research-backend / dg-research must not be modified:\n\n"
            + "\n".join(f"  - {p}" for p in problems)
        )
