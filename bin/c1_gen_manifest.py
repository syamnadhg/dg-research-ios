#!/usr/bin/env python3
"""Generate the C1 harness's platform + selector constants from the real manifest.

One source of truth, for the same reason the runtime JS is generated: a hand-maintained Swift copy of
selectors would drift from the manifest every other consumer uses, and the drift would show up as the
in-app gate testing something nobody else tests.

`mockplatform` reads `fixtures/mockplatform/selectors_mock.json` and points at the local fixture server.
Any other platform reads the loaded selector manifest and points at that platform's real origin — so the
moment selectors are captured, `bin/c1_in_app.sh <UDID> chatgpt` works with no code change.

Usage: c1_gen_manifest.py <platform> <out.swift> [--manifest PATH]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend import selectors as selectors_mod  # noqa: E402

MOCK_SELECTORS = REPO / "fixtures" / "mockplatform" / "selectors_mock.json"
MOCK_URL = "http://127.0.0.1:8901/"

#: Where each real platform's mobile web app lives. Kept beside the generator rather than in the
#: manifest because it is not a selector — the manifest describes DOM, not origins.
ORIGINS = {
    "chatgpt": "https://chatgpt.com/",
    "gemini": "https://gemini.google.com/",
    "claude": "https://claude.ai/",
    "notebooklm": "https://notebooklm.google.com/",
}


def selectors_for(
    platform: str, manifest_path: Path | None
) -> tuple[dict[str, list[str]], dict[str, str], dict[str, str], str, str]:
    """Returns (selectors, texts, openers, url, provenance).

    ⚠ ``texts`` exists because dropping it was a real defect, not a hypothetical one. This used to emit
    only ``{key: entry.css}`` filtered by ``if entry.css`` — so an entry that is deliberately TEXT-ONLY
    vanished from the Swift manifest entirely. ChatGPT's ``deep_research_toggle`` is exactly that: it
    carries no css on purpose, because ``resolve()`` tries css before text and a broad ``[role=menuitem]``
    would match "Camera", the first of nineteen menu items. The in-app run therefore reported
    ``tapped=false`` twice and "still on=false", which reads as a platform or a two-step-menu problem and
    was neither — the key simply was not there.

    ⚠ The provenance is not decoration. It travels into the verdict, and the coverage gate credits a
    platform ONLY when its C1 run used the real manifest. Without it, a wiring-proof run against a
    fixture would write `verdict-chatgpt.json` and the gate would report chatgpt as covered — the gate
    congratulating itself on a platform nobody has actually captured.
    """
    if platform == "mockplatform":
        raw = json.loads(MOCK_SELECTORS.read_text())["platforms"]["chatgpt"]
        return (
            {key: list(entry["css"]) for key, entry in raw.items() if entry.get("css")},
            {
                key: entry["text_contains"]
                for key, entry in raw.items()
                if entry.get("text_contains")
            },
            {
                key: entry["opener"]
                for key, entry in raw.items()
                if entry.get("opener")
            },
            MOCK_URL,
            "fixtures/mockplatform/selectors_mock.json",
        )

    manifest = selectors_mod.load_manifest(manifest_path)
    entries = manifest.platforms.get(platform)
    if entries is None:
        raise SystemExit(
            f"no platform {platform!r} in the manifest loaded from {manifest.source!r}; "
            f"known: {sorted(manifest.platforms)}"
        )
    unresolved = sorted(key for key, entry in entries.items() if not entry.resolvable)
    if unresolved:
        # Refused rather than generated with gaps. A step whose selector is missing would either throw
        # at the first use or, worse, quietly match nothing — which is the P1 failure where every click
        # lands and extraction returns zero.
        raise SystemExit(
            f"{platform} has {len(unresolved)} uncaptured selectors: {unresolved}. Capture them from "
            f"real logged-in mobile DOM first (bin/capture_selectors.py) — generating a partial "
            f"manifest would produce a run that reports success while touching nothing."
        )
    if platform not in ORIGINS:
        raise SystemExit(f"no origin known for {platform!r}; add it to ORIGINS in this generator")
    return (
        {key: list(entry.css) for key, entry in entries.items() if entry.css},
        {
            key: entry.text_contains
            for key, entry in entries.items()
            if entry.text_contains
        },
        {
            key: entry.opener
            for key, entry in entries.items()
            if entry.opener
        },
        ORIGINS[platform],
        # "baseline (...)" or the manifest path — load_manifest records where it came from.
        manifest.source,
    )


def render(
    platform: str,
    selectors: dict[str, list[str]],
    texts: dict[str, str],
    openers: dict[str, str],
    url: str,
    provenance: str,
) -> str:
    def literal(text: str) -> str:
        r"""JSON string escaping, with `ensure_ascii=False`.

        ⚠ JSON escaping is *almost* Swift escaping and the difference bites on non-ASCII: JSON emits
        `\u2014` for an em dash, Swift requires `\u{2014}`, and the compiler rejects the JSON form with
        "expected hexadecimal code in braces after unicode escape". Swift source is UTF-8, so the
        simplest correct answer is not to escape non-ASCII at all. My earlier comment here asserted the
        two were interchangeable; they are not.
        """
        return json.dumps(text, ensure_ascii=False)

    lines = [
        "// GENERATED by bin/c1_gen_manifest.py — do not edit.",
        "//",
        "// One source of truth: a hand-maintained Swift copy of these selectors would drift from the",
        "// manifest every other consumer reads, and the drift would surface as the in-app gate testing",
        "// something nobody else tests.",
        "enum SRManifest {",
        f"    static let platform = {literal(platform)}",
        f"    static let pageURL = {literal(url)}",
        f"    static let manifestSource = {literal(provenance)}",
        "    static let selectors: [String: [String]] = [",
    ]
    for key, values in sorted(selectors.items()):
        rendered = ", ".join(literal(value) for value in values)
        lines.append(f"        {literal(key)}: [{rendered}],")
    lines.append("    ]")
    # The text fallbacks, carried across the boundary rather than discarded. A key may appear here with
    # NO css entry above it — that is the point, and the reason the old shape lost ChatGPT's toggle.
    # ⚠ Swift rejects `[]` for a dictionary — "use [:] to get an empty dictionary literal". The mock has
    # no text fallbacks at all, so the empty case is the COMMON one here, not an edge case.
    if texts:
        lines.append("    static let texts: [String: String] = [")
        for key, value in sorted(texts.items()):
            lines.append(f"        {literal(key)}: {literal(value)},")
        lines.append("    ]")
    else:
        lines.append("    static let texts: [String: String] = [:]")
    if openers:
        lines.append("    static let openers: [String: String] = [")
        for key, value in sorted(openers.items()):
            lines.append(f"        {literal(key)}: {literal(value)},")
        lines.append("    ]")
    else:
        lines.append("    static let openers: [String: String] = [:]")
    lines += ["}", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("platform")
    parser.add_argument("out", type=Path)
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument(
        "--url",
        default=None,
        help="override the page URL — used to prove the non-mock wiring against the local fixture "
        "without reaching a real platform",
    )
    args = parser.parse_args()

    selectors, texts, openers, url, provenance = selectors_for(args.platform, args.manifest)
    if args.url:
        url = args.url
        provenance = f"{provenance} (url overridden — WIRING PROOF, not real coverage)"
    args.out.write_text(render(args.platform, selectors, texts, openers, url, provenance))
    print(f"    {args.platform}: {len(selectors)} selector keys -> {args.out.name}")
    print(f"    provenance: {provenance}")
