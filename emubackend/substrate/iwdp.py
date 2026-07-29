"""The DOM/read channel: WebKit's remote inspector, reached via `ios_webkit_debug_proxy`.

This is one of the two channels the iOS substrate needs. It reads the DOM and runs JS
(``Runtime.evaluate``), which covers everything except *trusted* input — that requires the
HID channel in :mod:`emubackend.substrate.hid`, because JS-dispatched events carry
``isTrusted === false`` and the chat SPAs reject them.

Two things here contradict ``EmulatorRecipe.md`` Appendix F, both found empirically:

1. **The Simulator is NOT auto-discovered.** Appendix F says *"the sim is auto-discovered,
   no UDID arg"*. Running bare `ios_webkit_debug_proxy` returns an empty device list. The
   Simulator requires the explicit ``-s unix:<socket>`` flag, and the socket lives at a
   **randomly named** path — ``/private/var/tmp/com.apple.launchd.<random>/``
   ``com.apple.webinspectord_sim.socket`` — which must be read out of the Simulator's own
   launchd job. IWDP's own ``--help`` example shows the path under ``/private/tmp/``,
   which is a different directory and does not exist. See :func:`discover_simulator_socket`.
2. **Commands must be wrapped in the ``Target`` domain.** Since iOS 12.2 WebKit
   multiplexes the inspector per target, so a bare ``Runtime.evaluate`` is rejected with
   *"'Runtime' domain was not found"* — a message that reads like a missing feature rather
   than a missing envelope, which is what makes it cost an hour. See :class:`Inspector`.

The socket path is allocated per boot, so it must be rediscovered after every
``simctl shutdown``/``boot`` — which matters directly for the reboot-persistence leg of B0a.
"""

from __future__ import annotations

import json
import re
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

__all__ = [
    "Inspector",
    "InspectorError",
    "Page",
    "discover_simulator_socket",
    "list_pages",
    "wait_for_page",
]

_RWI_RE = re.compile(r"RWI_LISTEN_SOCKET\s*=>\s*(\S+)")


class InspectorError(RuntimeError):
    """A remote-inspector command failed, timed out, or the target went away."""


@dataclass(frozen=True)
class Page:
    """One inspectable page as IWDP reports it."""

    url: str
    title: str
    ws_url: str
    app_id: str

    @classmethod
    def from_json(cls, raw: dict) -> Page:
        return cls(
            url=raw.get("url", ""),
            title=raw.get("title", ""),
            ws_url=raw.get("webSocketDebuggerUrl", ""),
            app_id=raw.get("appId", ""),
        )


def discover_simulator_socket(udid: str, uid: int = 501) -> str:
    """Read the Simulator's web-inspector socket path out of its own launchd job.

    Asking launchd is the only reliable way: the containing directory name is random per
    boot, so neither a glob over ``/private/var/tmp`` (which would match every simulator
    and every other launchd job) nor a hardcoded path can be trusted.
    """
    proc = subprocess.run(
        [
            "xcrun",
            "simctl",
            "spawn",
            udid,
            "launchctl",
            "print",
            f"user/{uid}/com.apple.webinspectord",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    match = _RWI_RE.search(proc.stdout)
    if not match:
        raise InspectorError(
            f"could not find RWI_LISTEN_SOCKET for {udid}. Is the device booted "
            f"(`xcrun simctl bootstatus {udid} -b`)? launchctl said:\n"
            f"{proc.stdout[-800:]}\n{proc.stderr[-400:]}"
        )
    return match.group(1)


def list_pages(port: int = 9222, timeout: float = 8.0) -> list[Page]:
    """List inspectable pages from a running IWDP."""
    try:
        with urllib.request.urlopen(
            f"http://localhost:{port}/json", timeout=timeout
        ) as resp:
            raw = json.loads(resp.read().decode() or "[]")
    except (urllib.error.URLError, TimeoutError) as exc:
        raise InspectorError(
            f"IWDP not answering on :{port} ({exc}). Started with "
            f"`-s unix:<socket>`? A bare invocation finds no simulator."
        ) from exc
    return [Page.from_json(p) for p in raw]


def wait_for_page(
    url_substring: str, port: int = 9222, timeout: float = 30.0
) -> Page:
    """Wait until a page whose URL contains *url_substring* is inspectable."""
    deadline = time.monotonic() + timeout
    seen: list[str] = []
    while time.monotonic() < deadline:
        pages = list_pages(port)
        seen = [p.url for p in pages]
        for page in pages:
            if url_substring in page.url and page.ws_url:
                return page
        time.sleep(0.5)
    raise InspectorError(
        f"no inspectable page matching {url_substring!r} within {timeout}s; saw: {seen}"
    )


class Inspector:
    """A `Runtime.evaluate` channel to one WebKit page.

    Handles the ``Target`` multiplexing that WebKit has required since iOS 12.2: every
    command is wrapped in ``Target.sendMessageToTarget`` and every reply arrives as a
    ``Target.dispatchMessageFromTarget`` event carrying the real message as a JSON
    *string*. The inner protocol keeps its own ``id`` sequence, independent of the outer.
    """

    def __init__(self, ws_url: str, timeout: float = 15.0):
        import websocket  # imported lazily so the module is importable without it

        self._timeout = timeout
        self._ws = websocket.create_connection(ws_url, timeout=timeout)
        self._outer_id = 0
        self._inner_id = 0
        self._target_id: str | None = None
        self._pending: dict[int, dict] = {}
        self._await_target()

    # -- lifecycle ---------------------------------------------------------------

    def __enter__(self) -> Inspector:
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def close(self) -> None:
        try:
            self._ws.close()
        except Exception:  # pragma: no cover - close is best-effort
            pass

    # -- plumbing ----------------------------------------------------------------

    def _await_target(self) -> None:
        """Consume ``Target.targetCreated`` until the *page* target appears."""
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            try:
                msg = json.loads(self._ws.recv())
            except Exception as exc:
                raise InspectorError(f"inspector closed before a target appeared: {exc}")
            if msg.get("method") == "Target.targetCreated":
                info = msg.get("params", {}).get("targetInfo", {})
                # There is also a "frame" target; only the page target accepts Runtime.
                if info.get("type") == "page":
                    self._target_id = info.get("targetId")
                    return
        raise InspectorError(
            "no Target.targetCreated(type=page) received — the page may have no "
            "inspectable content yet"
        )

    def command(self, method: str, params: dict | None = None) -> dict:
        """Send one inner-protocol command and return its ``result``."""
        if self._target_id is None:  # pragma: no cover - constructor guarantees this
            raise InspectorError("no page target attached")
        self._inner_id += 1
        inner_id = self._inner_id
        inner = json.dumps({"id": inner_id, "method": method, "params": params or {}})
        self._outer_id += 1
        self._ws.send(
            json.dumps(
                {
                    "id": self._outer_id,
                    "method": "Target.sendMessageToTarget",
                    "params": {"targetId": self._target_id, "message": inner},
                }
            )
        )
        return self._pump_for(inner_id)

    def _pump_for(self, inner_id: int) -> dict:
        if inner_id in self._pending:
            return self._unwrap(self._pending.pop(inner_id))
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            try:
                outer = json.loads(self._ws.recv())
            except Exception as exc:
                raise InspectorError(f"inspector connection lost: {exc}")
            if outer.get("method") != "Target.dispatchMessageFromTarget":
                continue  # an outer ack or an unrelated Target event
            inner = json.loads(outer["params"]["message"])
            if "id" not in inner:
                continue  # an inner event (console, DOM, …) — not a reply
            if inner["id"] == inner_id:
                return self._unwrap(inner)
            self._pending[inner["id"]] = inner  # out-of-order reply; keep it
        raise InspectorError(f"timed out after {self._timeout}s waiting for {inner_id}")

    @staticmethod
    def _unwrap(inner: dict) -> dict:
        if "error" in inner:
            err = inner["error"]
            raise InspectorError(
                f"{err.get('message', err)} (code {err.get('code')})"
            )
        return inner.get("result", {})

    # -- the useful surface ------------------------------------------------------

    def evaluate_json(self, expression: str) -> Any:
        """Evaluate *expression*, returning it decoded from JSON.

        The expression is wrapped in ``JSON.stringify`` and decoded here rather than
        relying on the protocol's ``returnByValue`` object serialisation, which differs
        between WebKit versions and silently drops or mangles nested values. A string
        round-trip is boring and identical everywhere.
        """
        wrapped = f"JSON.stringify((function(){{ return ({expression}); }})())"
        result = self.command(
            "Runtime.evaluate",
            {"expression": wrapped, "returnByValue": True, "awaitPromise": False},
        )
        if result.get("wasThrown") or result.get("result", {}).get("subtype") == "error":
            raise InspectorError(
                f"JS threw evaluating {expression!r}: {result.get('result', {}).get('description')}"
            )
        payload = result.get("result", {}).get("value")
        if payload is None:
            return None
        return json.loads(payload)
