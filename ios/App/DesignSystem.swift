import SwiftUI
import UIKit

/// The web app's design tokens, transcribed — not approximated.
///
/// Every value here is read out of `dg-research/src/app/globals.css`. The point of transcribing
/// rather than eyeballing is that "consistent with the rest of the app" is a claim someone will
/// check by putting the two side by side, and a hex that is one digit off reads as a different
/// product. Where the web app has a responsive scale, the phone takes the smallest step, which is
/// what that breakpoint exists for.
enum DS {

    // MARK: - Colour  (globals.css `--color-*`)

    /// Colour tokens, **theme-aware**.
    ///
    /// Every neutral is a dynamic colour built from the frontend's own light/dark pairs in
    /// `globals.css` (`:root` vs `[data-theme="light"]`), so switching theme here produces the same
    /// palette the web app produces — not an approximation of it.
    ///
    /// Brand and status colours are deliberately NOT dynamic: `#10A37F` is ChatGPT's green in both
    /// themes, and re-tinting a brand mark per theme would make it a different mark. The one exception
    /// the web app itself makes is `terminal`, which is slate-200 on dark and slate-400 on light —
    /// its comment says why: the dark value "disappears against a white surface".
    enum C {
        /// A colour that resolves per trait collection, so light/dark needs no branching at call sites.
        private static func dyn(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { traits in
                UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
            })
        }

        static let bg = dyn(light: 0xF5F7FA, dark: 0x050A15)
        static let surface = dyn(light: 0xFFFFFF, dark: 0x0A0F1E)
        /// The web app's `surface-2`, for pills and chips sitting ON a card.
        static let surfaceRaised = dyn(light: 0xF0F1F5, dark: 0x111B33)
        static let surfaceHigh = dyn(light: 0xE5E7EC, dark: 0x182444)
        static let border = dyn(light: 0xE0E2E8, dark: 0x1A2540)
        static let borderHover = dyn(light: 0xC8CCD4, dark: 0x253556)
        static let textPrimary = dyn(light: 0x1A1A2E, dark: 0xF1F5F9)
        static let textSecondary = dyn(light: 0x4A4A5E, dark: 0x94A3B8)
        static let textTertiary = dyn(light: 0x7A7A8E, dark: 0x4B5C78)
        static let accent = Color(hex: 0x3B82F6)
        static let accent2 = Color(hex: 0x7C6CAD)
        /// Slate-400 on light, slate-200 on dark — the one neutral the web app re-tints, because the
        /// dark value disappears against a white surface.
        static let terminal = dyn(light: 0x94A3B8, dark: 0xE2E8F0)

        /// Per-platform brand colours, straight from the web app. Fixed across themes: a brand mark
        /// re-tinted per theme is a different mark.
        static let chatgpt = Color(hex: 0x10A37F)
        static let gemini = Color(hex: 0x7D6A9E)
        static let claude = Color(hex: 0xD97706)
        static let notebooklm = Color(hex: 0x8B5CF6)
        static let youtube = Color(hex: 0xFF0000)
        static let gmail = Color(hex: 0xEA4335)
        static let gdocs = Color(hex: 0x38BDF8)

        /// Status colours are derived from the palette rather than invented, so a "good" green here
        /// is the same green as the ChatGPT brand mark the user already reads as positive.
        static let ok = chatgpt

        /// The web app's worker-pill green — Tailwind `green-500`, read off
        /// `account/page.tsx`'s own `bg-green-500`.
        ///
        /// ⛔ **NOT `ok`.** `ok` is the ChatGPT teal (`#10A37F`), and a worker pill drawn in it sits
        /// beside the same pill in the web app's Shared-with popup drawn in `#22C55E`. They are
        /// close enough to look like a rendering bug rather than a decision — which is exactly how
        /// this was reported. Anything that names a WORKER uses this; everything else keeps `ok`.
        static let worker = Color(hex: 0x22C55E)
        static let warn = claude
        static let danger = Color(hex: 0xEF4444)

        static func platform(_ key: String) -> Color {
            switch key.lowercased() {
            case "chatgpt": return chatgpt
            case "gemini": return gemini
            case "claude": return claude
            case "notebooklm": return notebooklm
            default: return textTertiary
            }
        }
    }

    // MARK: - Spacing  (globals.css `--pad-*` / `--gap-*`, at `--size-scale: 0.72`)

    enum S {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        /// Not a token — a phone needs a screen-edge inset the web app gets from its page layout.
        static let screen: CGFloat = 14
        /// Also not a token: Apple's 44pt minimum touch target. The web app's 8px paddings are
        /// mouse-sized, and copying them literally onto a phone would produce controls that are
        /// visually right and physically unusable.
        static let touch: CGFloat = 44
    }

    enum R {
        static let md: CGFloat = 8   // --radius-md at the smallest scale
        static let sm: CGFloat = 5
    }

    // MARK: - Type  (globals.css `--font-sans` / `--font-mono`)

    enum F {
        /// Every type size in the app is multiplied by this.
        ///
        /// ⭐ **One multiplier here rather than an edit at several hundred call sites.** The design
        /// system hands out fonts by point size, so scaling the app means scaling this function —
        /// and `.dynamicTypeSize` cannot help, because it only moves text that asked for a text
        /// STYLE, and none of these did.
        ///
        /// ⚠ Set from `AppSizeManager`, which owns the persistence. A plain global is enough
        /// because it is read during body evaluation: the manager is `@Published`, so changing the
        /// size re-renders, and the re-render reads the new value.
        static var scale: CGFloat = 1

        /// Inter and JetBrains Mono are not on iOS, and bundling them into a Simulator-only harness
        /// buys little. The system faces are the closest available match — SF for Inter's role,
        /// SF Mono via `.monospaced` for JetBrains Mono. Noted so nobody thinks the fonts shipped.
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: scaled(size), weight: weight, design: .default)
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: scaled(size), weight: weight, design: .monospaced)
        }

        /// ⚠ Rounded, and floored at 1pt. A fractional point size renders on a half-pixel and the
        /// mono columns stop lining up — which is most visible in exactly the places this app uses
        /// mono for, the ids and the counters.
        static func scaled(_ size: CGFloat) -> CGFloat {
            max(1, (size * scale).rounded())
        }

        // ⛔ **`var`, not `let`, and that is the whole reason the control works.** As stored
        // constants these were evaluated once, at first access, and captured whatever the scale
        // happened to be then — so changing the size moved every call to `mono(_:)` and left every
        // use of `.label`, `.title` and `.code` at the old size. Half the app would resize.
        static var title: Font { sans(17, .semibold) }
        static var body: Font { sans(14) }
        static var label: Font { sans(11, .medium) }
        static var code: Font { mono(13) }
        static var codeLarge: Font { mono(28, .semibold) }
    }
}

// MARK: - Shared chrome

extension View {
    /// The card treatment the web app uses for every panel: surface fill, 1px border, `--radius-md`.
    func srCard() -> some View {
        self
            .padding(DS.S.lg)
            .background(DS.C.surface)
            .overlay(
                RoundedRectangle(cornerRadius: DS.R.md)
                    .stroke(DS.C.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.R.md))
    }
}

/// An uppercase tracked section label — the web app's panel-heading treatment.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.F.label)
            .tracking(0.8)
            .foregroundStyle(DS.C.textTertiary)
    }
}

/// A status dot plus label. Dot *and* text, never colour alone — colour-blind users get nothing
/// from a green circle, and this is the control that says whether the device is working.
/// A status pill. When it means "online", the dot breathes.
///
/// The pulse is tied to the one thing it is honest about: a device is online *because it is
/// heartbeating*, and a slow pulse is what a heartbeat looks like. Deliberately NOT applied to offline
/// or not-paired — animating those would be decoration, and worse, would imply activity where there is
/// none. That restraint is what keeps the motion informative rather than ambient.
struct StatusPill: View {
    let color: Color
    let text: String
    /// Only the live state pulses.
    var live: Bool = false

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: DS.S.sm) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .scaleEffect(live && pulsing ? 1.35 : 1)
                .opacity(live && pulsing ? 0.55 : 1)
                .animation(
                    live
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
            Text(text).font(DS.F.body).foregroundStyle(DS.C.textPrimary)
        }
        .onAppear { if live { pulsing = true } }
        .onChange(of: live) { _, isLive in pulsing = isLive }
    }
}

/// The breathing dot, on its own.
///
/// ⚠ Extracted from `StatusPill` rather than copied, so the two cannot drift into two different
/// ideas of what "live" looks like. Same restraint as the pill: the motion is tied to something it
/// is honest about — a worker breathes *because a run is moving through it* — and a still dot means
/// still. Decorative animation on an idle worker would imply activity where there is none.
struct PulsingDot: View {
    let colour: Color
    var live: Bool = false
    var size: CGFloat = 6

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: size, height: size)
            .scaleEffect(live && pulsing ? 1.45 : 1)
            .opacity(live && pulsing ? 0.5 : 1)
            .animation(
                live ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { if live { pulsing = true } }
            .onChange(of: live) { _, isLive in pulsing = isLive }
    }
}

/// A button sized for a thumb, styled like the web app's.
///
/// `destructive` is a separate role rather than a colour argument so that a caller cannot make an
/// irreversible action look ordinary — `--unpair`, `--retire` and `--uninstall` all live behind it.
struct SRButton: View {
    enum Role { case primary, secondary, destructive }
    let title: String
    var role: Role = .secondary
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.F.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: DS.S.touch)
                .foregroundStyle(fg)
                .background(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.R.sm)
                        .stroke(role == .secondary ? DS.C.border : .clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.R.sm))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private var fg: Color {
        switch role {
        case .primary, .destructive: return .white
        case .secondary: return DS.C.textPrimary
        }
    }
    private var bg: Color {
        switch role {
        case .primary: return DS.C.accent
        case .destructive: return DS.C.danger
        case .secondary: return .clear
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
