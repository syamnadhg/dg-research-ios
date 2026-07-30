"""The mobile selector manifest — the layer that makes the browser port *data*, not code.

This is the recipe's keystone (§0.5.3) applied to the port itself. The backend's
``selfheal.py::load_intents`` **prefers** an external ``selfheal_intents.json`` over its compiled
baseline, which is why a platform-change fix there is a JSON patch rather than a version bump, a
wheel rebuild and a three-platform republish. Iteration cost is the dominant tax on this codebase,
and that route avoids it.

The same reasoning decides the shape of the browser layer here, and it has a consequence worth
being explicit about: **the phase bodies can be written before the selectors are known.** A body
says *"tap the composer, then tap send, then harvest the sources"*; the manifest says *what those
are on mobile*. Only the manifest needs real logged-in DOM. So the ~24k-line browser layer is not
one indivisible block gated on a login — it is code that can be written and tested now, plus data
that arrives later.

That split also means a selector fix never touches Python. When ChatGPT moves its send button, the
change is a line in a JSON file — which is the difference between a fix that ships in minutes and
one that ships in a release.

**Resolution order**, mirroring the backend: ``$DG_IOS_SELECTORS`` → ``selectors_mobile.json``
beside the repo → the built-in baseline. A missing or corrupt external file falls back safely
rather than failing the run, because a broken manifest should degrade to the last known-good
behaviour instead of taking the pipeline down with it.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

__all__ = [
    "BASELINE",
    "SelectorEntry",
    "SelectorManifest",
    "load_manifest",
    "manifest_path",
]

#: The built-in baseline. Deliberately **empty of real selectors**: mobile selectors can only be
#: derived from real logged-in DOM in the Simulator, and inventing plausible ones is worse than
#: having none — a wrong selector produces the P1 failure (every click lands, extraction returns
#: nothing, the run reports success), whereas a *missing* one fails loudly at the first use.
#:
#: The structure is populated so the shape is fixed and reviewable, and so a manifest supplied
#: later is validated against a known key set rather than accepted blindly.
BASELINE: dict[str, Any] = {
    "version": 1,
    "surface": "ios-mobile-safari",
    "platforms": {
        "chatgpt": {
            "logged_in_marker": None,
            "composer": None,
            "send": None,
            "deep_research_toggle": None,
            "activity_panel": None,
            "sources": None,
            "response_container": None,
        },
        "gemini": {
            "logged_in_marker": None,
            "composer": None,
            "send": None,
            "deep_research_toggle": None,
            "start_research": None,
            "sources": None,
            "response_container": None,
        },
        "claude": {
            "logged_in_marker": None,
            "composer": None,
            "send": None,
            "research_toggle": None,
            "artifact_panel": None,
            "sources": None,
            "response_container": None,
        },
        "notebooklm": {
            "logged_in_marker": None,
            "add_source": None,
            "generate_audio": None,
            "audio_ready_marker": None,
        },
    },
}

#: Keys every platform entry may contain. A manifest naming something outside its platform's set is
#: rejected — a typo'd key would otherwise sit in the file silently doing nothing, and the symptom
#: would be a step that never finds its element for reasons nothing explains.
ALLOWED_KEYS = {p: set(v) for p, v in BASELINE["platforms"].items()}


@dataclass(frozen=True)
class SelectorEntry:
    """One resolvable target.

    More than a CSS string on purpose. A mobile target frequently needs a fallback chain (platforms
    A/B-test their DOM), and the recipe is explicit that **network-level predicates are far more
    redesign-stable than DOM ones** — so a target can carry the request pattern that confirms it as
    well as the selector that finds it.
    """

    css: tuple[str, ...] = ()
    #: Text that must appear in the element, for cases where structure is unstable but the label is not.
    text_contains: str | None = None
    #: A request URL fragment observed when this target is genuinely engaged. The durable signal.
    network_hint: str | None = None
    #: Where this came from — hand-derived, or proposed by the offline repair agent (phase A2).
    provenance: str = "unset"

    @property
    def resolvable(self) -> bool:
        return bool(self.css) or self.text_contains is not None

    @classmethod
    def from_json(cls, raw: Any) -> SelectorEntry:
        if raw is None:
            return cls()
        if isinstance(raw, str):
            return cls(css=(raw,), provenance="literal")
        if isinstance(raw, list):
            return cls(css=tuple(raw), provenance="literal-list")
        if isinstance(raw, dict):
            css = raw.get("css")
            if isinstance(css, str):
                css = [css]
            return cls(
                css=tuple(css or ()),
                text_contains=raw.get("text_contains"),
                network_hint=raw.get("network_hint"),
                provenance=raw.get("provenance", "manifest"),
            )
        raise ValueError(f"cannot read a selector entry from {type(raw).__name__}")


class ManifestError(ValueError):
    """The manifest is structurally wrong in a way that would fail silently if accepted."""


@dataclass
class SelectorManifest:
    """Resolved selectors for one surface."""

    version: int = 1
    surface: str = "ios-mobile-safari"
    platforms: dict[str, dict[str, SelectorEntry]] = field(default_factory=dict)
    source: str = "baseline"

    def entry(self, platform: str, key: str) -> SelectorEntry:
        try:
            return self.platforms[platform][key]
        except KeyError:
            raise ManifestError(
                f"no selector for {platform}.{key} in the manifest loaded from {self.source!r}. "
                f"Known keys for {platform}: {sorted(ALLOWED_KEYS.get(platform, ()))}"
            ) from None

    def require(self, platform: str, key: str) -> SelectorEntry:
        """Fetch an entry that must be resolvable, failing loudly if it is not.

        The loud failure is the design. An unresolved selector means "nobody has captured this from
        real DOM yet", and a step that quietly does nothing instead would report success on a page
        it never touched.
        """
        found = self.entry(platform, key)
        if not found.resolvable:
            raise ManifestError(
                f"{platform}.{key} is present but has no selector — it has not been captured from "
                f"real logged-in DOM yet. This step cannot run until it is; a silent skip here "
                f"would report success on a page nothing touched."
            )
        return found

    def missing(self) -> list[str]:
        """Every ``platform.key`` still awaiting real DOM. The honest to-do list."""
        return [
            f"{platform}.{key}"
            for platform, entries in sorted(self.platforms.items())
            for key, entry in sorted(entries.items())
            if not entry.resolvable
        ]

    def coverage(self) -> tuple[int, int]:
        """(resolvable, total) — so progress is a number rather than an impression."""
        total = sum(len(v) for v in self.platforms.values())
        done = total - len(self.missing())
        return done, total


def manifest_path() -> Path | None:
    """Where an external manifest would be found, or None if there is none."""
    env = os.environ.get("DG_IOS_SELECTORS")
    if env:
        candidate = Path(env).expanduser()
        return candidate if candidate.is_file() else None
    default = Path(__file__).resolve().parent.parent / "selectors_mobile.json"
    return default if default.is_file() else None


def load_manifest(path: Path | None = None) -> SelectorManifest:
    """Load the manifest, preferring an external file over the baseline.

    A missing or corrupt external file falls back to the baseline rather than raising. That mirrors
    ``selfheal.load_intents`` and is the right trade: a broken manifest should degrade to known-good
    behaviour, not take the pipeline down. The fallback is recorded in ``source`` so it is visible
    rather than mysterious.
    """
    raw = BASELINE
    source = "baseline"
    candidate = path or manifest_path()
    if candidate is not None:
        try:
            loaded = json.loads(Path(candidate).read_text(encoding="utf-8"))
            _validate(loaded)
            raw = loaded
            source = str(candidate)
        except (OSError, ValueError) as exc:
            source = f"baseline (external manifest at {candidate} unusable: {exc})"

    # Merged ONTO the baseline's key structure, never substituted for it.
    #
    # ⚠ This was a substitution, and the bug it produced was a reporting lie rather than a crash. A
    # partial manifest — seven captured keys out of the twenty-five — made `platforms` contain only
    # those seven, so `coverage()` returned `(7, 7)` and `missing()` returned `[]`. The two functions
    # whose whole job is to say how far along the capture is both reported *finished* at 28%.
    #
    # Merging keeps every baseline key present as an unresolvable entry, which is what `missing()`
    # counts and what `require()` fails loudly on. A manifest can now add values but never shrink the
    # question being asked.
    #
    # Scoped to the platforms the loaded file actually MENTIONS, which is the correction to the
    # correction. Merging onto every baseline platform fixed the honesty bug (a 7-key file reporting
    # 7/7 complete) and created a new one: the mock e2e's manifest deliberately covers one platform,
    # and judging it against all twenty-five made `done == total` false, so the gate failed on a
    # manifest that was entirely correct. A single-platform manifest should be measured against that
    # platform.
    #
    # All three cases now read correctly: no external file -> the full baseline, 0/25. The real
    # manifest, which names four platforms -> 15/25. The mock's, which names one -> 7/7.
    loaded = raw.get("platforms") or {}
    named = set(loaded) if candidate is not None and raw is not BASELINE else set(ALLOWED_KEYS)
    platforms: dict[str, dict[str, SelectorEntry]] = {
        platform: {key: SelectorEntry() for key in keys}
        for platform, keys in ALLOWED_KEYS.items()
        if platform in named
    }
    for platform, entries in loaded.items():
        merged = platforms.setdefault(platform, {})
        for key, value in (entries or {}).items():
            merged[key] = SelectorEntry.from_json(value)
    return SelectorManifest(
        version=int(raw.get("version", 1)),
        surface=str(raw.get("surface", "ios-mobile-safari")),
        platforms=platforms,
        source=source,
    )


def _validate(raw: Any) -> None:
    if not isinstance(raw, dict):
        raise ValueError("manifest must be an object")
    platforms = raw.get("platforms")
    if not isinstance(platforms, dict):
        raise ValueError("manifest.platforms must be an object")
    for platform, entries in platforms.items():
        if platform not in ALLOWED_KEYS:
            raise ValueError(
                f"unknown platform {platform!r}; known: {sorted(ALLOWED_KEYS)}"
            )
        if not isinstance(entries, dict):
            raise ValueError(f"platforms.{platform} must be an object")
        unknown = set(entries) - ALLOWED_KEYS[platform]
        if unknown:
            # Rejected rather than ignored: a typo'd key sits in the file doing nothing, and the
            # symptom is a step that never finds its element with nothing to explain why.
            raise ValueError(
                f"platforms.{platform} has unknown key(s) {sorted(unknown)}; "
                f"known: {sorted(ALLOWED_KEYS[platform])}"
            )
