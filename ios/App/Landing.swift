import SwiftUI

/// What the app shows before there is anything to show — the backend-side counterpart of the web app's
/// login page.
///
/// The web app's landing page sells the *product*: one topic in, a research package out. This one has a
/// different job, because the person reading it is not deciding whether to use Super Research — they
/// already do. They are deciding to turn **this phone into one of its backends**, and what they need to
/// know is what that means: which part of the work happens here, what it will ask of them, and what it
/// costs them (the app stays open).
///
/// Copy and phase names are taken from the frontend's own login page rather than invented, so the two
/// describe the same product in the same words.
enum AppScreen {
    case landing
    case notPaired
    case pairing
}

struct LandingView: View {
    let onGetStarted: () -> Void

    /// The phases this device actually runs.
    ///
    /// ⚠ P0–P3 only. P4 (video) and P5 (upload) are frontend-owned Cloud Run work with no browser
    /// involved, so listing them here would promise something this device never does.
    private let phases: [(String, String, String)] = [
        ("0", "Submit", "A topic becomes a structured research plan."),
        ("1", "Research brief", "The topic is expanded into a brief that guides the agents."),
        ("2", "Parallel deep research",
         "Three agents work at once. Total time is the slowest, not the sum."),
        ("3", "Synthesis", "Every report is combined into one, with sources kept."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.S.lg * 2) {
                hero
                whatThisIs
                phaseList
                whatItNeeds
                cta
            }
            .padding(DS.S.screen)
        }
        .background(DS.C.bg)
    }

    private var hero: some View {
        VStack(spacing: DS.S.md) {
            Wordmark(size: 28)
            // The frontend's own tagline, verbatim.
            Text("One topic. Three AI agents. Complete research package.")
                .font(DS.F.body)
                .foregroundStyle(DS.C.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.S.lg * 2)
    }

    private var whatThisIs: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "This app is a backend")
            Text("Research is fired from the web app, and a *backend* does the work — driving the AI platforms in a real browser, waiting out long deep-research runs, and reporting progress back.")
                .font(DS.F.body).foregroundStyle(DS.C.textSecondary)
            Text("That backend is normally a Mac. This turns your iPhone into one. Same account, same runs, same contract — a device your web app can send work to.")
                .font(DS.F.body).foregroundStyle(DS.C.textSecondary)
        }
        .srCard()
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "What runs here")
            ForEach(phases, id: \.0) { phase in
                HStack(alignment: .firstTextBaseline, spacing: DS.S.lg) {
                    Text("P\(phase.0)")
                        .font(DS.F.mono(11, .semibold))
                        .foregroundStyle(DS.C.accent)
                        .frame(width: 22, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase.1).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                        Text(phase.2).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
                    }
                }
            }
            // Said plainly rather than left for someone to discover: promising the video and upload
            // stages would be promising something this device never does.
            Text("The podcast, video and upload stages run in the cloud, not on this device.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .srCard()
    }

    private var whatItNeeds: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            SectionLabel(text: "What it needs from you")
            need("A pair code", "Claimed once on the web app's Account page.")
            need("A sign-in per platform", "One time each. The session persists.")
            need("The app open", "iOS suspends background apps, so a backend has to be on screen. The display is kept awake for you.")
        }
        .srCard()
    }

    private func need(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.S.lg) {
            Text("•").font(DS.F.body).foregroundStyle(DS.C.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
                Text(detail).font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }
        }
    }

    /// The closing CTA.
    ///
    /// Deliberately carries a tight description of *this* thing rather than a generic sign-off. There is
    /// no "set up a research computer" or "drive from the agent" call to action here on purpose — those
    /// belong to the web app, which is where a person chooses how to run research. By the time someone
    /// is reading this screen they have already installed a backend; the only decision left is whether
    /// to pair it.
    private var cta: some View {
        VStack(spacing: DS.S.lg) {
            VStack(spacing: DS.S.sm) {
                Text("Super Research for iOS")
                    .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
                Text("A Super Research backend that runs on your iPhone. Pair it to your account, sign in to the platforms once, and the web app can send it research — phases 0 to 3, in a real browser, on this device.")
                    .font(DS.F.label)
                    .foregroundStyle(DS.C.textSecondary)
                    .multilineTextAlignment(.center)
            }
            SRButton(title: "Get started", role: .primary, action: onGetStarted)
            Text("Takes about two minutes.")
                .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
        }
        .padding(.bottom, DS.S.lg * 2)
    }
}

/// The in-between state: this iOS backend exists and has no **user** yet.
///
/// ⚠ The wording matters and the first version got it backwards. "No device paired" is what the *web
/// app* would say, because from there the device is the missing thing. Here, the device is what you are
/// holding — what is missing is the account it serves. Saying "no device" on the device reads as though
/// the app cannot find itself.
///
/// A deliberate stop rather than dropping straight into stage 1. Pairing calls the frontend and mints a
/// real code with a real expiry the moment it starts, so it should begin when the user is ready to go
/// and look at the web app — not because they tapped through a marketing page.
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
