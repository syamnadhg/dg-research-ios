"""The secret gate must actually catch a planted secret.

Written the same way `probe_forbidden_call_detector` is, and for the same reason: a scanner that finds
nothing looks exactly like a clean repo. The repo IS clean now, so the only way to know this gate works
is to plant a violation and watch it fire.

Motivated by a real incident — the first push tripped GitHub's secret scanner on a Firebase Web API key
reproduced in docs/FIRESTORE_CONTRACT.md.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent


def _module():
    spec = importlib.util.spec_from_file_location("secret_scan", REPO / "bin" / "secret_scan.py")
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["secret_scan"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def scanner():
    return _module()


def test_the_repo_is_currently_clean(scanner):
    assert scanner.scan() == []


def test_the_cli_exits_zero_on_the_real_repo():
    result = subprocess.run(
        [str(REPO / ".venv/bin/python"), str(REPO / "bin" / "secret_scan.py")],
        capture_output=True, text=True, cwd=REPO,
    )
    assert result.returncode == 0, result.stdout


@pytest.mark.parametrize(
    "planted,label",
    [
        ("AIzaSy" + "B" * 33, "google api key"),
        ("sk-" + "a" * 32, "openai key"),
        ("ghp_" + "b" * 36, "github token"),
        # Assembled at runtime so this FILE never contains the pattern contiguously. The gate caught
        # its own test fixture on the first run — a true positive about a false positive. An allowlist
        # entry would have been the easy fix and the wrong one: every exemption is a place a real
        # secret can later hide. Splitting the literal keeps the gate maximally strict instead.
        ("-----BEGIN " + "RSA PRIVATE KEY" + "-----", "private key block"),
        ("AKIA" + "C" * 16, "aws access key"),
        ("GOCSPX-" + "d" * 24, "google oauth client secret"),
    ],
)
def test_a_planted_secret_is_caught(scanner, planted, label, monkeypatch, tmp_path):
    """The positive direction, which matters more than the negative one for a scanner."""
    planted_file = tmp_path / "leaky.md"
    planted_file.write_text(f"config: {planted}\n")
    monkeypatch.setattr(scanner, "REPO", tmp_path)
    monkeypatch.setattr(scanner, "tracked_files", lambda: ["leaky.md"])

    findings = scanner.scan()
    assert findings, f"{label} was NOT caught"
    assert label in findings[0]


def test_the_finding_is_truncated_so_ci_logs_do_not_gain_the_secret(scanner, monkeypatch, tmp_path):
    """A gate that prints the whole secret has copied it somewhere usually less protected."""
    secret = "AIzaSy" + "E" * 33
    (tmp_path / "leaky.md").write_text(secret)
    monkeypatch.setattr(scanner, "REPO", tmp_path)
    monkeypatch.setattr(scanner, "tracked_files", lambda: ["leaky.md"])

    finding = scanner.scan()[0]
    assert secret not in finding, "the full secret must not appear in the report"
    assert "…" in finding


def test_it_scans_TRACKED_files_not_the_working_tree(scanner):
    """An untracked GoogleService-Info.plist holds this very key and is CORRECT.

    Scanning the working tree would fail the gate on a file that is properly gitignored, which teaches
    people to disable the gate. What matters is what is committed.
    """
    source = (REPO / "bin" / "secret_scan.py").read_text()
    assert "git" in source and "ls-files" in source
    assert (REPO / "ios" / "GoogleService-Info.plist").exists(), (
        "this test's premise is that the plist exists locally but untracked"
    )
    tracked = subprocess.run(
        ["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout
    assert "GoogleService-Info.plist" not in tracked
    assert scanner.scan() == []


def test_the_docs_no_longer_carry_the_literal_that_tripped_the_scanner():
    """Named explicitly so a future edit re-pasting it turns a test red, not just a scanner alert."""
    body = (REPO / "docs" / "FIRESTORE_CONTRACT.md").read_text()
    assert "AIzaSy" not in body
    assert "public web key" in body or "public by design" in body, (
        "the doc should explain WHY the value is absent, or someone will helpfully restore it"
    )
