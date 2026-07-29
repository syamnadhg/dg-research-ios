import SwiftUI

/// The backend-side counterpart of the web app's login page, built to the **same structure**.
///
/// The first version invented its own layout, which made it a different product page sitting in front of
/// the same product. This one follows `dg-research/src/components/LoginScreen.tsx`:
///
/// * a **CTA card at the top** — title, tagline, one primary button
/// * the **phase timeline**: numbered circles on a blue→purple gradient rail, connected
/// * each card carrying **tag pills** and a **duration pill**, with an expandable **Details** list
/// * **phase 2 given its three agent cards**, since running in parallel is the point of that step
/// * the tagline under the CTA, and a closing CTA at the end
///
/// Copy, titles, durations, tags, details and agent names/subtitles are verbatim from that file rather
/// than paraphrased, so the two screens describe the product identically.
///
/// **Two deliberate departures.**
///
/// 1. **Dark, not light.** The web login page uses white cards; every other surface in this app — and the
///    web app's own authed shell — is `#050A15`. A light page here would be the only light screen in the
///    product.
/// 2. **A left rail instead of alternating columns.** The web page alternates cards around a centre rail
///    and degrades to a `0.3fr` stub column on narrow screens. At 402pt that stub is dead space, so the
///    rail moves left and cards take the full width — same numbered-circle identity without spending a
///    third of a phone screen on nothing.
///
/// There is deliberately no "set up a research computer" or "drive from the agent" call to action: those
/// are the web app's decisions about *how* to run research. By the time someone reads this they have
/// already installed a backend, and the only question left is whether to pair it.
enum AppScreen {
    case landing
    case notPaired
    case pairing
}

private struct Phase: Identifiable {
    let id: Int
    let title: String
    let duration: String
    let description: String
    let tags: [String]
    let details: [String]
    /// Set only for phase 2, the parallel step.
    var agents: [(name: String, sub: String, id: String)] = []
    /// False for the phases that run in the cloud rather than on this device.
    var runsHere = true
}

private let phases: [Phase] = [
    Phase(
        id: 0, title: "Submit Your Topic", duration: "Instant",
        description: "Enter a high-level research topic. It will be automatically converted into a structured research plan.",
        tags: ["Any Topic", "Instant"],
        details: [
            "Type any research topic — broad or specific",
            "Customize which steps and agents to include",
            "Pipeline starts automatically",
        ]
    ),
    Phase(
        id: 1, title: "Research Brief", duration: "10–25 min",
        description: "Your high-level topic is converted into a detailed research brief that guides the best research agents on the market.",
        tags: ["AI-Powered", "Deep Analysis"],
        details: [
            "Submit any research topic — broad or specific",
            "AI generates a comprehensive research plan",
            "Brief drives all three research agents",
        ]
    ),
    Phase(
        id: 2, title: "Parallel Deep Research", duration: "15–45 min",
        description: "Three leading AI research agents work simultaneously on your topic. Total time equals the slowest — not the sum.",
        tags: ["3 Agents", "Parallel"],
        details: [
            "Three agents research your topic independently",
            "Each produces a comprehensive report with sources",
            "If one agent fails, the others continue",
        ],
        agents: [
            (name: "ChatGPT", sub: "Deep Research + Web", id: "chatgpt"),
            (name: "Gemini", sub: "Advanced Research", id: "gemini"),
            (name: "Claude", sub: "Extended Thinking", id: "claude"),
        ]
    ),
    Phase(
        id: 3, title: "Synthesis & Podcast", duration: "10–20 min",
        description: "All research reports are synthesized together. A podcast-style audio overview is generated for easy listening.",
        tags: ["Synthesis", "Audio Overview"],
        details: [
            "Reports combined into a single knowledge base",
            "Podcast-style audio discussion generated",
            "Covers key findings from all perspectives",
        ]
    ),
    Phase(
        id: 4, title: "Video & Upload", duration: "5–10 min",
        description: "Your research podcast is converted into a video and uploaded for easy sharing and playback.",
        tags: ["Video", "Shareable"],
        details: [
            "Audio converted to shareable video format",
            "Uploaded as unlisted for privacy",
            "Link included in your final report",
        ],
        runsHere: false
    ),
    Phase(
        id: 5, title: "Report & Notification", duration: "2–5 min",
        description: "You receive a comprehensive report with the highest quality insights, along with a podcast and links to every agent used.",
        tags: ["Report", "Email"],
        details: [
            "Google Doc hub with all findings and links",
            "Email notification with report + podcast",
            "Links to each agent for follow-up questions",
        ],
        runsHere: false
    ),
]

struct LandingView: View {
    @ObservedObject var theme: ThemeManager
    let onGetStarted: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: DS.S.lg * 2) {
                header
                hero
                timeline
                footerLink
            }
            .padding(DS.S.screen)
        }
        .background(DS.C.bg)
    }

    /// Wordmark plus the theme control, at the top — the two things the web page puts in its header.
    private var header: some View {
        HStack {
            Wordmark(size: 20)
            Spacer()
            ThemeToggle(theme: theme, compact: true)
        }
        .padding(.top, DS.S.lg)
    }

    /// Everything explanatory, said ONCE.
    ///
    /// ⚠ An earlier version had a CTA card at the top and a near-identical one at the bottom, which read
    /// as the same pitch twice. The explanation and the button live here; the bottom carries a link out
    /// to the web app instead of repeating itself.
    private var hero: some View {
        VStack(spacing: DS.S.lg) {
            VStack(spacing: DS.S.md) {
                Text("Run research on this iPhone")
                    .font(DS.F.sans(20, .bold))
                    .foregroundStyle(DS.C.textPrimary)
                    .multilineTextAlignment(.center)
                // The frontend's own tagline, verbatim.
                Text("One topic. Three AI agents. Complete research package.")
                    .font(DS.F.body)
                    .foregroundStyle(DS.C.textSecondary)
                    .multilineTextAlignment(.center)
                Text("Research is fired from the web app, and a backend does the work — driving the AI platforms in a real browser and reporting back. That backend is normally a Mac. Pair this iPhone and it becomes one: phases 0 to 3 run here, on this device.")
                    .font(DS.F.label)
                    .foregroundStyle(DS.C.textTertiary)
                    .multilineTextAlignment(.center)
            }
            SRButton(title: "Get started", role: .primary, action: onGetStarted)
            Text("Pair code, a sign-in per platform, and the app left open. About two minutes.")
                .font(DS.F.label)
                .foregroundStyle(DS.C.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.S.lg * 2)
        .frame(maxWidth: .infinity)
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.C.border, lineWidth: 1))
    }

    /// Alternating left/right around a centre rail, as the web page does.
    ///
    /// The earlier left-rail version was a list, and a list loses what the alternation is FOR: the
    /// zig-zag is what makes six steps read as a path rather than six items. At 402pt the cards take
    /// ~62% of the width and lean to their side, which keeps the alternation legible without the web's
    /// dead `0.3fr` stub.
    private var timeline: some View {
        VStack(spacing: 0) {
            ForEach(phases) { phase in
                PhaseRow(
                    phase: phase,
                    isLast: phase.id == phases.last?.id,
                    onLeft: phase.id.isMultiple(of: 2)
                )
            }
        }
    }

    /// The bottom of the page: a way out to the web app, not a second pitch.
    private var footerLink: some View {
        VStack(spacing: DS.S.md) {
            Link(destination: URL(string: AppConfig.frontendBaseURL)!) {
                HStack(spacing: DS.S.md) {
                    Text("Open the web app")
                        .font(DS.F.label.weight(.medium)).foregroundStyle(DS.C.accent)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                }
                .frame(minHeight: DS.S.touch)
            }
            Text(AppConfig.frontendBaseURL.replacingOccurrences(of: "https://", with: ""))
                .font(DS.F.mono(9)).foregroundStyle(DS.C.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DS.S.lg * 2)
    }
}

/// One phase: a numbered circle on the rail, and its card.
private struct PhaseRow: View {
    let phase: Phase
    let isLast: Bool
    /// Even phases sit left of the rail, odd ones right — the web page's zig-zag.
    let onLeft: Bool
    @State private var expanded = false

    @State private var appeared = false

    var body: some View {
        // Alternating around the rail. The zig-zag is what makes six steps read as a path rather than
        // six list items — which is exactly what the earlier left-rail version lost.
        HStack(alignment: .top, spacing: DS.S.md) {
            if onLeft {
                card
                rail
                Spacer(minLength: 0).frame(width: 20)
            } else {
                Spacer(minLength: 0).frame(width: 20)
                rail
                card
            }
        }
        // The web page reveals each phase on scroll with `useInView`; this is the same idea with the
        // means available — a short rise-and-fade on first appearance. Staggered by phase so the
        // timeline reads as a sequence being laid down rather than six cards arriving at once.
        .opacity(appeared ? 1 : 0)
        // Rises AND leans in from its own side, so the reveal reinforces which side the card belongs
        // to rather than fighting it.
        .offset(x: appeared ? 0 : (onLeft ? -14 : 14), y: appeared ? 0 : 12)
        .onAppear {
            withAnimation(
                .easeOut(duration: 0.35).delay(Double(phase.id) * 0.06)
            ) { appeared = true }
        }
    }

    /// The numbered circle and its connector, in the web page's blue→purple gradient.
    private var rail: some View {
        VStack(spacing: 0) {
            Text("\(phase.id)")
                .font(DS.F.mono(10, .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [DS.C.accent, DS.C.notebooklm],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                // Dimmed for the cloud phases, so "what runs here" reads at a glance rather than only
                // in a footnote.
                .opacity(phase.runsHere ? 1 : 0.4)
            if !isLast {
                LinearGradient(
                    colors: [DS.C.accent.opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 1)
                .frame(minHeight: 40)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DS.S.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(phase.title)
                    .font(DS.F.sans(15, .semibold))
                    .foregroundStyle(phase.runsHere ? DS.C.textPrimary : DS.C.textSecondary)
                Spacer()
                if !phase.runsHere { Pill(text: "in the cloud", tone: .neutral) }
            }
            Text(phase.description)
                .font(DS.F.label)
                .foregroundStyle(DS.C.textTertiary)

            if !phase.agents.isEmpty { agentCards }

            HStack(spacing: DS.S.sm) {
                // A tag identical to the duration is dropped: phase 0 carries both `Instant` as a tag
                // and `Instant` as its duration, and showing the same word twice in adjacent pills
                // reads as a rendering bug rather than as data.
                ForEach(phase.tags.filter { $0 != phase.duration }, id: \.self) {
                    Pill(text: $0, tone: .accent)
                }
                Pill(text: phase.duration, tone: .violet)
                Spacer()
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Hide" : "Details")
                        .font(DS.F.mono(9, .medium))
                        .foregroundStyle(DS.C.textTertiary)
                        .padding(.horizontal, DS.S.md)
                        .padding(.vertical, 3)
                        .background(DS.C.surfaceRaised)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: DS.S.sm) {
                    Divider().overlay(DS.C.border)
                    ForEach(phase.details, id: \.self) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: DS.S.md) {
                            Circle().fill(DS.C.accent.opacity(0.6))
                                .frame(width: 4, height: 4)
                            Text(detail)
                                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(DS.S.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.C.border, lineWidth: 1))
        .padding(.bottom, DS.S.lg)
        // Details expand by growing the card, so the surrounding timeline shifts with it instead of
        // the new content overlapping what was there.
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: expanded)
    }

    /// Phase 2's three agents, side by side — the web page gives this step its own treatment.
    private var agentCards: some View {
        HStack(spacing: DS.S.md) {
            ForEach(phase.agents, id: \.id) { agent in
                VStack(spacing: DS.S.sm) {
                    // The real brand mark. A letter in a tinted circle made all three agents the same
                    // component with a different character in it.
                    AgentIcon(id: agent.id, size: 30)
                    Text(agent.name)
                        .font(DS.F.sans(11, .semibold))
                        .foregroundStyle(DS.C.textPrimary)
                        .lineLimit(1)
                    Text(agent.sub)
                        .font(DS.F.mono(8))
                        .foregroundStyle(DS.C.textTertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.S.md)
                .background(DS.C.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// The web page's tag/duration pills: small, tinted, bordered.
struct Pill: View {
    /// `queued` is amber, not violet — the web app uses amber for "waiting on something" and green for
    /// "in flight", and a queued run is the former.
    enum Tone { case accent, violet, neutral, ok, queued }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(DS.F.mono(9, .medium))
            .foregroundStyle(colour)
            .padding(.horizontal, DS.S.md)
            .padding(.vertical, 3)
            .background(colour.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(colour.opacity(0.3), lineWidth: 1))
    }

    private var colour: Color {
        switch tone {
        case .accent: return DS.C.accent
        case .violet: return DS.C.notebooklm
        case .ok: return DS.C.ok
        case .queued: return DS.C.warn
        case .neutral: return DS.C.textTertiary
        }
    }
}

/// The in-between state: this iOS backend exists and has no **user** yet.
///
/// ⚠ The wording matters and the first version got it backwards. "No device paired" is what the *web
/// app* would say, because from there the device is the missing thing. Here, the device is what you are
/// holding — what is missing is the account it serves.
struct NotPairedView: View {
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: DS.S.lg * 2) {
            Spacer()
            VStack(spacing: DS.S.lg) {
                Text("No user paired")
                    .font(DS.F.body.weight(.medium))
                    .foregroundStyle(DS.C.textPrimary)
                Text("This iOS backend isn't linked to an account yet. Pair it to start serving runs.")
                    .font(DS.F.label)
                    .foregroundStyle(DS.C.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            SRButton(title: "Pair with your account", role: .primary, action: onPair)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.S.screen)
    }
}
