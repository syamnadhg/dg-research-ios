"""Which model a platform should be switched to, chosen by FAMILY and never by version literal.

⛔ **No version numbers in this file, and that is a standing rule rather than a preference.** A pinned
"3.6 Flash" misreports the moment the family moves on, and a *floor* rots in both directions: it
strands a run on an old model when the account is offered a newer one, and it silently matches
something else entirely when the numbering scheme changes. The owner's instruction is "the latest
Flash", so the code asks the picker what it is offering and takes the highest of that family.

⚠ **Flash-Lite is a DIFFERENT family from Flash, and the distinction is load-bearing.** Measured on
the live picker: `3.5 Flash-Lite`, `3.6 Flash`, `3.1 Pro`. "Latest Flash" is 3.6 Flash today — but a
substring match on "Flash" also matches Flash-Lite, so the first time the account is offered a
`3.7 Flash-Lite` a naive highest-version-containing-Flash would switch the run to the *fastest,
cheapest* model for a deep-research phase. Nothing would fail; the research would just be worse.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

#: A menu row's leading version, e.g. "3.6 Flash All-around help" -> (3, 6).
_VERSION = re.compile(r"^\s*(\d+)(?:\.(\d+))?\s")


@dataclass(frozen=True)
class ModelOption:
    label: str
    family: str
    version: tuple[int, ...]


def parse_option(label: str) -> ModelOption | None:
    """Read one picker row into (family, version).

    The family is the token(s) after the version and before the description — `Flash`, `Flash-Lite`,
    `Pro`. Hyphenated names are kept whole precisely so `Flash-Lite` cannot collapse into `Flash`.
    """
    match = _VERSION.match(label)
    if not match:
        return None
    major = int(match.group(1))
    minor = int(match.group(2) or 0)
    rest = label[match.end():].strip()
    if not rest:
        return None
    family = rest.split()[0].strip()
    if not family:
        return None
    return ModelOption(label=label.strip(), family=family, version=(major, minor))


def pick_latest(labels: list[str], family: str) -> str | None:
    """The highest-versioned option of exactly *family*, or None if it is not offered.

    ⚠ **Exact family match, case-insensitively — never a substring.** `"Flash" in "Flash-Lite"` is
    the bug this function exists to prevent.

    ⚠ **Returns None rather than a near miss.** A picker that stops offering the family is a real
    change and the caller must decide what to do; silently taking "the closest thing" would switch a
    deep-research phase onto a model nobody chose.
    """
    wanted = family.strip().lower()
    best: ModelOption | None = None
    for label in labels:
        option = parse_option(label)
        if option is None or option.family.lower() != wanted:
            continue
        if best is None or option.version > best.version:
            best = option
    return best.label if best else None


#: The picker row that turns on longer reasoning. Not a model — a modifier applied alongside one,
#: which is why it is matched separately and has no version.
EXTENDED_THINKING = "Extended thinking"


def is_extended_thinking(label: str) -> bool:
    return label.strip().lower().startswith(EXTENDED_THINKING.lower())


#: What each platform's P2 should be set to, by FAMILY.
#:
#: Measured on the live in-app picker 2026-08-08 for Gemini: the rows are "3.5 Flash-Lite", "3.6
#: Flash", "3.1 Pro" and "Extended thinking". The owner's instruction is the latest **Flash** plus
#: extended thinking, then Deep Research from the "+" menu.
P2_MODEL_FAMILY = {
    "gemini": "Flash",
    # ⭐ Owner: "Opus highest so far (rn at 5)". FAMILY only — that parenthesis is precisely why no
    # literal belongs here. The picker currently reads "Opus 5 Max"; the day it reads 6 this must
    # follow with no edit at all.
    "claude": "Opus",
}

#: Platforms whose P2 also enables the longer-reasoning modifier.
P2_EXTENDED_THINKING = {"gemini"}
