"""Read-only access to the `dg-research-backend` source checkout.

⛔ **A8 — the hardest constraint in the plan.** `dg-research-backend` and
`dg-research` are not modified by this repo. Not a line. This module is the *only*
sanctioned way the iOS track reaches BE code, and it is strictly read-only: it
appends the checkout to ``sys.path`` and imports from it. It never writes, never
builds, never installs.

Deliberate deviation from the recipe
-----------------------------------
``EmulatorRecipe.md`` §0.5 (decision A8) specifies the BE as an editable dev
dependency — ``-e ../dg-research-backend``. **We do not do that.** The BE's
``[build-system]`` is ``setuptools.build_meta``, so ``pip install -e`` executes that
build backend *inside* the BE checkout and (re)generates ``superresearch.egg-info/``
there — writing into the very checkout the production ``--serve`` daemon runs from.
``.gitignore`` hides those artifacts, which makes the violation invisible to
``git status`` rather than harmless.

A ``sys.path`` append reaches exactly the same importable surface with **zero**
writes, so it is strictly safer and strictly simpler. Recorded in
``docs/DEVIATIONS.md``.

Why this is cheap
-----------------
``research.py``'s *module level* imports only ``models`` and ``prompts`` beyond the
standard library (verified by walking ``ast.Module.body`` — not by grep, which would
also match function-local imports). Everything heavy is deferred: ``patchright``
loads lazily inside ``Browser.start``, ``google.cloud`` imports are function-local,
and the entrypoint is ``__main__``-guarded. So ``import research`` is a fast,
side-effect-free read.

What is genuinely importable, and what is not
---------------------------------------------
Importable and safe to use directly: ``ALERT_INTENTS`` (a plain dict), the ``auth``
package, ``narrate``, ``selfheal``, and module-level constants.

**Not** usable by import, despite what §4 of the recipe says: the Firestore-contract
helpers (``_update_firestore_research``, ``_emit_to_firestore``, ``emit_event``,
``_persist_pending_decision``, ``upload_audio_to_storage``, ``_post_fe_p4p5_trigger``)
are welded to module globals that only ``setup_firestore_run`` arms — and that
function writes ``owner.json`` into ``<BE>/queues/<run_id>``, where the production
daemon's disk-restore scans. **Never call ``setup_firestore_run``.** Those helpers get
vendored into ``emubackend/contract/`` instead; see :mod:`emubackend.contract`.
"""

from __future__ import annotations

import ast
import os
import sys
from pathlib import Path

__all__ = [
    "BEHRepoError",
    "CLAIMED_TOP_LEVEL_NAMES",
    "FORBIDDEN_BE_SYMBOLS",
    "be_root",
    "ensure_on_path",
    "import_be",
    "import_be_file",
    "module_level_third_party_imports",
]


class BEHRepoError(RuntimeError):
    """The backend checkout could not be located or does not look like the BE."""


#: Top-level names the BE checkout claims once it is on ``sys.path``. This repo must
#: never define any of them. The first group are real modules/packages; the second are
#: plain directories, which Python 3 would merge with a same-named directory here into
#: a single implicit namespace package — a subtler collision, and just as unwanted.
CLAIMED_TOP_LEVEL_NAMES = frozenset(
    {
        # modules / packages
        "research",
        "models",
        "prompts",
        "vision",
        "vision_test",
        "narrate",
        "selfheal",
        "auth",
        "scripts",
        # plain dirs — implicit-namespace-package hazard
        "tests",
        "tools",
        "agent",
        # build artifacts, and a genuinely live hazard rather than a technicality:
        # the BE's `build/` holds a full copy of the sources (build/lib/research.py, …),
        # so `build` is importable as a namespace package. Any packaging run in *this*
        # repo would create a second `build/` and the two would merge. `dist/` is listed
        # for the same reason even though today it holds only wheels.
        "build",
        "dist",
    }
)

#: BE symbols that must never be called from this repo, with the reason. Enforced by
#: a static test (``test_no_forbidden_be_calls``) rather than trusted to discipline.
FORBIDDEN_BE_SYMBOLS = {
    "setup_firestore_run": (
        "writes owner.json into <BE>/queues/<run_id>, which the production daemon's "
        "disk-restore scans — calling it contaminates the running product"
    ),
    "init_firebase": (
        "authenticates as the production daemon's deviceId, producing two listeners "
        "on one devices/{id}/queue and double-claim races (A10)"
    ),
}

#: Files that must exist for a directory to be accepted as the BE checkout.
_BE_MARKERS = ("research.py", "auth", "models.py", "prompts.py")

_DEFAULT_REL = "../dg-research-backend"


def be_root() -> Path:
    """Locate the BE source checkout.

    Resolution order: ``$DG_BE_CHECKOUT``, else the sibling ``../dg-research-backend``
    relative to this repo. The result is validated against :data:`_BE_MARKERS` so a
    wrong path fails loudly here rather than as a confusing ``ModuleNotFoundError``
    later.
    """
    env = os.environ.get("DG_BE_CHECKOUT")
    if env:
        root = Path(env).expanduser()
        source = "$DG_BE_CHECKOUT"
    else:
        root = (Path(__file__).resolve().parent.parent / _DEFAULT_REL).resolve()
        source = f"default sibling {_DEFAULT_REL}"

    if not root.is_dir():
        raise BEHRepoError(f"BE checkout not found at {root} (from {source})")

    missing = [m for m in _BE_MARKERS if not (root / m).exists()]
    if missing:
        raise BEHRepoError(
            f"{root} (from {source}) does not look like dg-research-backend; "
            f"missing: {', '.join(missing)}"
        )
    return root


def ensure_on_path() -> Path:
    """Idempotently put the BE checkout on ``sys.path``; return its root.

    The path is **appended**, never prepended: this repo's own modules must always win
    a name resolution, so that an accidental collision surfaces as our code being used
    rather than silently shadowed by the BE's.
    """
    root = be_root()
    entry = str(root)
    if entry not in sys.path:
        sys.path.append(entry)
    return root


def import_be(module_name: str):
    """Import *module_name* from the BE checkout, ensuring the path is set up first.

    Raises :class:`BEHRepoError` for a name the BE does not claim, so a typo cannot
    silently import something from this repo or site-packages instead.
    """
    if module_name.split(".")[0] not in CLAIMED_TOP_LEVEL_NAMES:
        raise BEHRepoError(
            f"{module_name!r} is not a name the BE checkout claims; "
            f"expected one of {sorted(CLAIMED_TOP_LEVEL_NAMES)}"
        )
    ensure_on_path()
    import importlib

    return importlib.import_module(module_name)


def import_be_file(module_path: str, alias: str | None = None):
    """Load a single BE source file as a module, **without** running its package ``__init__``.

    Needed because ``auth/__init__.py`` eagerly does ``from . import credentials, keystore,
    pairing``, so a plain ``import auth.pairing`` drags in ``credentials`` (which needs
    ``google.auth``) and the backend's own ``keystore`` — whose module-level constants point at
    the production state dir. Loading the one file directly keeps the dependency surface honest
    (``auth/pairing.py`` needs only ``requests``) and guarantees the production keystore is
    never even imported, which is a stronger A10 position than "imported but not called".

    *module_path* is repo-relative, e.g. ``"auth/pairing.py"``.
    """
    import importlib.util

    root = ensure_on_path()
    target = root / module_path
    if not target.is_file():
        raise BEHRepoError(f"{target} does not exist in the BE checkout")
    name = alias or "be_" + module_path.replace("/", "_").removesuffix(".py")
    spec = importlib.util.spec_from_file_location(name, target)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise BEHRepoError(f"could not build an import spec for {target}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def module_level_third_party_imports(py_file: Path) -> set[str]:
    """Return the non-stdlib top-level names *py_file* imports **at module level**.

    Walks ``ast.Module.body`` only, so function-local and lazily-deferred imports are
    correctly excluded — the distinction that makes ``import research`` cheap. A grep
    would conflate the two and give the wrong answer.
    """
    tree = ast.parse(py_file.read_text(encoding="utf-8", errors="replace"))
    found: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                found.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            # level > 0 is a relative import; module is None for `from . import x`
            if node.level == 0 and node.module:
                found.add(node.module.split(".")[0])
    return {name for name in found if name not in sys.stdlib_module_names}
