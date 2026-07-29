"""Data-driven P0–P3 phase bodies.

The structural point of this module, and the reason it can exist before anyone has logged into a
platform: **a phase body describes a sequence, the manifest describes what the steps are on
mobile.** "Tap the composer, type the brief, tap send, wait for a response, harvest the sources" is
knowable now. *Which element is the composer on mobile Safari* is not — that needs real logged-in
DOM. So the browser layer is not one indivisible ~24k-line block gated on a login; it is code that
can be written and tested now plus data that arrives later.

Two disciplines are structural here rather than optional:

* **Every mutating step goes through :func:`emubackend.intents.guarded_intent`** with an
  ``outcome_predicate`` — that is phase A1 under A8, where wrapping is a design property rather
  than a retrofit.
* **Every extraction is judged by a harvest-shaped predicate**, not by "did we get something".
  Read drift is the dominant failure class, and the P1 incident is the proof: every click landed and
  extraction returned zero for an entire run, which a non-empty check passes happily.

An unresolved selector raises. It does **not** skip the step. A silent skip reports success on a
page nothing touched, which is the failure mode this whole layer is built to make impossible.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from emubackend import harvest, intents
from emubackend.selectors import ManifestError, SelectorEntry, SelectorManifest

__all__ = [
    "PhaseDeps",
    "PlatformDriver",
    "build_phase_bodies",
    "resolve",
]


async def resolve(page: Any, entry: SelectorEntry) -> Any | None:
    """Find the element an entry describes, trying its CSS chain then its text.

    The chain exists because platforms A/B-test their DOM, so a single selector is a single point of
    failure on a surface we do not control. Order is significant: the first match wins, so a
    manifest should list its most specific selector first.
    """
    for css in entry.css:
        found = await page.query_selector(css)
        if found is not None:
            return found
    if entry.text_contains:
        # Text is the fallback for structure that moves but labels that do not. Deliberately
        # last — matching on copy is fragile in the opposite direction (an i18n change breaks it).
        candidates = await page.query_selector_all("button, a, [role=button]")
        for handle in candidates:
            try:
                text = await handle.inner_text()
            except Exception:
                continue
            if entry.text_contains.lower() in (text or "").lower():
                return handle
    return None


@dataclass
class PhaseDeps:
    """What a phase body needs, injected so bodies are testable without a Simulator."""

    manifest: SelectorManifest
    registry: intents.IntentRegistry
    history: harvest.HarvestHistory
    #: platform key -> a PageShim-shaped object.
    pages: dict[str, Any] = field(default_factory=dict)
    topic: str = ""
    #: Recorded per platform so a caller can see what actually happened rather than inferring it.
    log: list[str] = field(default_factory=list)


class PlatformDriver:
    """The mutating steps for one platform, each already wrapped.

    Registers its intents on construction so an intent's predicate exists before anything can run
    it — an intent registered lazily at first use would have no bake history and could never
    accumulate one honestly.
    """

    def __init__(self, platform: str, deps: PhaseDeps):
        self.platform = platform
        self.deps = deps
        self.page = deps.pages.get(platform)
        self._register()

    # -- predicates --------------------------------------------------------------

    async def _present(self, key: str) -> bool:
        entry = self.deps.manifest.entry(self.platform, key)
        if not entry.resolvable or self.page is None:
            return False
        return await resolve(self.page, entry) is not None

    async def logged_in(self) -> bool:
        """The per-platform logged-in marker.

        ⚠ Deliberately a manifest entry rather than a hardcoded check: the recipe warns that the
        desktop sidebar markers *collapse on mobile*, so reusing them would report a logged-out
        page as logged in.
        """
        return await self._present("logged_in_marker")

    async def composer_focused(self) -> bool:
        if self.page is None:
            return False
        active = await self.page.evaluate("document.activeElement && document.activeElement.tagName")
        return bool(active)

    async def response_present(self) -> bool:
        return await self._present("response_container")

    # -- intents -----------------------------------------------------------------

    def _register(self) -> None:
        keys = self.deps.manifest.platforms.get(self.platform, {})

        def add(name: str, predicate, *, confirmed_off=None, reversible=False) -> None:
            intent_id = f"{self.platform}.{name}"
            try:
                self.deps.registry.get(intent_id)
            except KeyError:
                self.deps.registry.register(
                    intents.Intent(
                        id=intent_id,
                        platform=self.platform,
                        description=f"{name} on {self.platform}",
                        outcome_predicate=predicate,
                        confirmed_off=confirmed_off,
                        reversible=reversible,
                    )
                )

        add("focus_composer", self.composer_focused)
        add("send", self.response_present)
        for toggle in ("deep_research_toggle", "research_toggle"):
            if toggle in keys:
                # A toggle is the one genuinely reversible+verifiable shape, so it is the only kind
                # eligible to ever escalate live — and it needs a POSITIVE off-signal, because a
                # false-negative predicate driving a toggle would switch a live control OFF.
                add(
                    toggle,
                    self._toggle_on_predicate(toggle),
                    confirmed_off=self._toggle_off_predicate(toggle),
                    reversible=True,
                )

    def _toggle_on_predicate(self, key: str):
        async def _p() -> bool:
            if self.page is None:
                return False
            entry = self.deps.manifest.entry(self.platform, key)
            handle = await resolve(self.page, entry) if entry.resolvable else None
            if handle is None:
                return False
            state = await handle.get_attribute("aria-pressed")
            if state is None:
                state = await handle.get_attribute("aria-checked")
            return state == "true"

        return _p

    def _toggle_off_predicate(self, key: str):
        async def _p() -> bool:
            """A POSITIVE off-signal: the control exists and reports itself off.

            Not `not on`. If the control cannot be found at all we return False, so an unfindable
            toggle is never treated as confirmed-off — which is what stops a rotted selector from
            authorising a click that would turn a live control off.
            """
            if self.page is None:
                return False
            entry = self.deps.manifest.entry(self.platform, key)
            handle = await resolve(self.page, entry) if entry.resolvable else None
            if handle is None:
                return False
            state = await handle.get_attribute("aria-pressed")
            if state is None:
                state = await handle.get_attribute("aria-checked")
            return state == "false"

        return _p

    # -- actions -----------------------------------------------------------------

    async def _tap(self, key: str) -> None:
        entry = self.deps.manifest.require(self.platform, key)
        handle = await resolve(self.page, entry)
        if handle is None:
            raise ManifestError(
                f"{self.platform}.{key} did not match anything on the page. Selectors tried: "
                f"{list(entry.css)}"
                + (f", text~={entry.text_contains!r}" if entry.text_contains else "")
            )
        await handle.click()

    async def focus_composer(self) -> intents.IntentOutcome:
        return await intents.guarded_intent(
            self.deps.registry, f"{self.platform}.focus_composer", lambda: self._tap("composer")
        )

    async def type_brief(self, text: str) -> None:
        entry = self.deps.manifest.require(self.platform, "composer")
        handle = await resolve(self.page, entry)
        if handle is None:
            raise ManifestError(f"{self.platform}.composer vanished before typing")
        # fill() focuses by a real trusted tap and then uses the editor-aware path, which is what
        # ProseMirror-style composers require — a plain value assignment leaves their model empty
        # and the send control disabled.
        await handle.fill(text)

    async def send(self) -> intents.IntentOutcome:
        return await intents.guarded_intent(
            self.deps.registry, f"{self.platform}.send", lambda: self._tap("send")
        )

    async def enable_deep_research(self) -> intents.IntentOutcome | None:
        for key in ("deep_research_toggle", "research_toggle"):
            if key in self.deps.manifest.platforms.get(self.platform, {}):
                return await intents.guarded_intent(
                    self.deps.registry,
                    f"{self.platform}.{key}",
                    lambda k=key: self._tap(k),
                )
        return None

    async def harvest_sources(self) -> harvest.HarvestVerdict:
        entry = self.deps.manifest.require(self.platform, "sources")

        async def _extract() -> list[str]:
            handles = []
            for css in entry.css:
                handles = await self.page.query_selector_all(css)
                if handles:
                    break
            out = []
            for handle in handles:
                try:
                    out.append(await handle.inner_text())
                except Exception:
                    continue
            return out

        items = await _extract()
        return harvest.judge(f"{self.platform}.sources", items, self.deps.history)


# --------------------------------------------------------------------------------------
# the phase bodies
# --------------------------------------------------------------------------------------


def build_phase_bodies(deps: PhaseDeps, platforms: tuple[str, ...]):
    """Return P0–P3 bodies bound to *deps*, suitable for :func:`emubackend.pipeline.run_pipeline`."""

    drivers = {p: PlatformDriver(p, deps) for p in platforms}

    async def p0_verify(_ctx) -> None:
        """P0 — confirm every platform is logged in before committing to a run.

        Checked up front because discovering it in P2 wastes the whole brief phase, and because a
        logged-out page usually *renders* — so without an explicit marker check the run proceeds and
        fails much later for a reason that looks unrelated.
        """
        for name, driver in drivers.items():
            if not await driver.logged_in():
                raise ManifestError(
                    f"{name} is not logged in (or its logged_in_marker has not been captured "
                    f"from real mobile DOM yet). ⚠ Do NOT reuse the desktop sidebar markers — "
                    f"they collapse on mobile and would report a logged-out page as logged in."
                )
            deps.log.append(f"p0:{name}:logged_in")

    async def p1_brief(_ctx) -> None:
        """P1 — put the topic into one platform and capture the brief."""
        driver = drivers[platforms[0]]
        await driver.focus_composer()
        await driver.type_brief(deps.topic)
        await driver.send()
        deps.log.append(f"p1:{driver.platform}:brief_sent")

    async def p2_deep_research(_ctx) -> None:
        """P2 — enable deep research per platform and dispatch."""
        for name, driver in drivers.items():
            await driver.enable_deep_research()
            await driver.focus_composer()
            await driver.type_brief(deps.topic)
            await driver.send()
            deps.log.append(f"p2:{name}:dispatched")

    async def p3_harvest(_ctx) -> None:
        """P3 — harvest, and judge each harvest rather than merely collecting it.

        A harvest that fails its predicate raises, so a run cannot report success having collected
        nothing — the exact P1 outcome this exists to prevent.
        """
        for name, driver in drivers.items():
            verdict = await driver.harvest_sources()
            deps.log.append(f"p3:{name}:{'ok' if verdict.ok else 'SUSPECT'}:{verdict.count}")
            if not verdict.ok:
                raise ManifestError(f"{name} harvest failed its predicate: {verdict.reason}")

    return [p0_verify, p1_brief, p2_deep_research, p3_harvest]
