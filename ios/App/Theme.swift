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
