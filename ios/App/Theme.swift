import SwiftUI

/// Light or dark, persisted. **No "follow the system".**
///
/// Owner decision, 2026-08-07: two states, not three, in both places the toggle appears — the
/// landing page header and Settings. The two must agree; a landing page offering System and a
/// Settings sheet offering two options is the same control disagreeing with itself.
///
/// ⚠ A stored `"system"` from a build that had three options must still be readable. Dropping the
/// case without handling it would send `Choice(rawValue: "system")` to nil and silently reset the
/// owner's choice — so it is migrated to an explicit value on the way in, and overwritten on the way
/// out the first time the toggle is touched.
@MainActor
final class ThemeManager: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var symbol: String {
            switch self {
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        /// Always a concrete scheme now. Returning nil for any case would re-introduce
        /// follow-the-system through the back door, which is what was removed.
        var colorScheme: ColorScheme? {
            switch self {
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @Published var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private static let key = "sr.theme"

    /// Read a stored value, migrating the retired `"system"` and defaulting to dark.
    ///
    /// Separate and static so the migration is testable without a live `ThemeManager` — the whole
    /// risk here is a silent reset, which a running app cannot report.
    static func resolve(stored: String?) -> Choice {
        // Defaults to dark, not light: this is a backend that sits on a desk running a browser, and
        // the rest of the product's authed surface is dark. A first launch that came up white would
        // look like a different app. A previously stored "system" lands here too — dark is the
        // product's own default, so it is the honest thing to fall back to.
        Choice(rawValue: stored ?? "") ?? .dark
    }

    init() {
        choice = Self.resolve(stored: UserDefaults.standard.string(forKey: Self.key))
    }
}

/// How large the app draws itself.
///
/// ⭐ Its own manager rather than a second field on `ThemeManager`: the two are stored under
/// different keys, and a reader that only wanted the colour scheme should not be re-rendered by a
/// size change (or the reverse).
final class AppSizeManager: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case xs, s, m, l, xl
        var id: String { rawValue }

        /// Shown uppercased; stored lowercased. The stored form is the contract.
        var label: String { rawValue.uppercased() }

        /// ⚠ Deliberately gentle at the ends. A phone propped on a desk is read from further away
        /// than a phone in the hand, so the useful range is "a bit smaller" to "noticeably bigger"
        /// — not a range that makes the ids unreadable at one end and reflows every card at the
        /// other. XL is +25%, which is about as far as the two-column platform grid goes before
        /// its captions wrap.
        var scale: CGFloat {
            switch self {
            case .xs: return 0.85
            case .s: return 0.925
            case .m: return 1
            case .l: return 1.12
            case .xl: return 1.25
            }
        }
    }

    @Published var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            DS.F.scale = choice.scale
        }
    }

    private static let key = "sr.textSize"

    /// Separate and static for the same reason `ThemeManager.resolve` is: the risk is a silent
    /// reset to a size the owner did not choose, which a running app cannot report.
    static func resolve(stored: String?) -> Choice {
        Choice(rawValue: stored ?? "") ?? .m
    }

    init() {
        choice = Self.resolve(stored: UserDefaults.standard.string(forKey: Self.key))
        // ⛔ Applied in `init`, not only in `didSet`. A stored size would otherwise take effect
        // only after the owner touched the control again — so the app would relaunch at medium
        // every time and look like the setting had not saved.
        DS.F.scale = choice.scale
    }
}

/// The XS–XL control, beside light/dark in Appearance.
struct SizeToggle: View {
    @ObservedObject var size: AppSizeManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSizeManager.Choice.allCases) { choice in
                Button { size.choice = choice } label: {
                    Text(choice.label)
                        // ⚠ A FIXED size, not a scaled one. Every other label in the app grows
                        // with the setting; if this one did too, the control would resize itself
                        // as you used it and the segment under your thumb would move.
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(size.choice == choice ? DS.C.accent : DS.C.textTertiary)
                        .frame(minWidth: 30)
                        .padding(.vertical, DS.S.sm)
                        .background(size.choice == choice ? DS.C.accent.opacity(0.15) : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Text size \(choice.label)")
                .accessibilityAddTraits(size.choice == choice ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(DS.C.surfaceRaised)
        .clipShape(Capsule())
    }
}

/// The segmented light/dark control. Used at the top of the landing page and in Settings — the same
/// two places the web app offers it, and now offering the same two options in both.
struct ThemeToggle: View {
    @ObservedObject var theme: ThemeManager
    /// Compact drops the labels, for the landing page's header where space is tight.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemeManager.Choice.allCases) { choice in
                Button {
                    theme.choice = choice
                } label: {
                    HStack(spacing: DS.S.sm) {
                        Image(systemName: choice.symbol)
                            .font(.system(size: 11, weight: .medium))
                        if !compact {
                            Text(choice.label).font(DS.F.mono(10, .medium))
                        }
                    }
                    .foregroundStyle(
                        theme.choice == choice ? DS.C.accent : DS.C.textTertiary
                    )
                    .padding(.horizontal, compact ? DS.S.md : DS.S.lg)
                    .padding(.vertical, DS.S.sm)
                    .background(
                        // The selected segment is filled, so the control reads at a glance rather than
                        // needing a colour comparison between three items.
                        theme.choice == choice ? DS.C.accent.opacity(0.15) : .clear
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(DS.C.surfaceRaised)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DS.C.border, lineWidth: 1))
        // Animated because the fill moving between segments is what communicates the change; a hard
        // cut would read as a redraw.
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: theme.choice)
    }
}
