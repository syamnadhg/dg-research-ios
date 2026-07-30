#!/usr/bin/env python3
"""Refuse to ship a credential-shaped literal in a tracked file.

Added after a real incident rather than as a precaution: the repo's first push tripped GitHub's
secret scanner, because ``docs/FIRESTORE_CONTRACT.md`` reproduced the project's Firebase **Web** API
key twice — copied out of the backend's own default while documenting the pairing contract.

The severity and the lesson are separate, and conflating them is how this recurs:

* The key is **public by design.** It ships in every client that talks to the project and is already
  served to the open internet from the frontend's ``public/firebase-messaging-sw.js``. Firestore
  Security Rules and App Check are what gate access, not the key's secrecy — so the remediation is to
  *restrict* it (Google Cloud → Credentials → API restrictions / HTTP referrers), not to rotate it.
  Rotating a value that is deliberately in a public service worker breaks every deployed client and
  buys nothing.
* **None of that makes committing it acceptable.** An alert costs someone's attention, a second copy
  widens the blast radius of any future misconfiguration, and "it was already public" explains why
  this was low-severity — it does not explain why it was there.

So this gate does not try to judge sensitivity. It matches **shapes that scanners match**, and fails
the build on any of them, because a human deciding "this particular key is fine to commit" is exactly
the judgement that produced the incident.

Scans ``git ls-files`` rather than the working tree: an untracked ``GoogleService-Info.plist`` holding
the same key is correct and must not fail the gate. What matters is what is *committed*.

    python bin/secret_scan.py        # exit 1 on any finding
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

#: Credential shapes, chosen to mirror what GitHub's own scanners look for.
#:
#: Deliberately shape-based, not entropy-based. An entropy heuristic on this repo would fire on every
#: Firestore document id, every ``data-turn-id``, and the base64 in the golden fixtures — a gate that
#: cries wolf is a gate someone switches off.
PATTERNS: dict[str, str] = {
    "google api key": r"AIza[0-9A-Za-z_\-]{35}",
    "openai key": r"\bsk-[A-Za-z0-9]{20,}",
    "anthropic key": r"\bsk-ant-[A-Za-z0-9\-_]{20,}",
    "github token": r"gh[pousr]_[A-Za-z0-9]{36}",
    "slack token": r"xox[baprs]-[0-9A-Za-z\-]{10,}",
    "aws access key": r"\bAKIA[0-9A-Z]{16}\b",
    "private key block": r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    "google oauth client secret": r"\bGOCSPX-[A-Za-z0-9_\-]{20,}",
}

#: This file necessarily contains the patterns themselves.
SELF = "bin/secret_scan.py"


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True
    )
    return [f for f in out.stdout.split("\n") if f]


def scan() -> list[str]:
    findings: list[str] = []
    for rel in tracked_files():
        if rel == SELF:
            continue
        path = REPO / rel
        try:
            body = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for name, pattern in PATTERNS.items():
            for match in re.finditer(pattern, body):
                line = body[: match.start()].count("\n") + 1
                # Truncated in the report on purpose: a gate that prints the whole secret has copied it
                # into your CI logs, which are usually less protected than the repo was.
                findings.append(f"{rel}:{line}: {name} -> {match.group(0)[:10]}…")
    return findings


def main() -> int:
    findings = scan()
    if findings:
        print("SECRET-SHAPED LITERALS IN TRACKED FILES:")
        for f in findings:
            print("  " + f)
        print(
            "\nRemove the literal and read it from the environment or a gitignored file. If you believe "
            "a match is genuinely safe to commit, that is the judgement that caused the incident this "
            "gate exists for — read the header before overriding."
        )
        return 1
    print(f"secret scan: clean ({len(tracked_files())} tracked files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
