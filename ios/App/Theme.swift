import SwiftUI

/// Light / dark / follow-the-system, persisted.
///
/// The web app puts a theme toggle in two places — the app's own settings and the top of the login
/// page — and this mirrors both. Three states rather than a boolean, because "follow the system" is a
/// real preference and a two-way switch silently overrides it forever after the first tap.
@MainActor
final class ThemeManager: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var symbol: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        /// nil means "don't override" — which is what makes System actually follow the system.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @Published var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private static let key = "sr.theme"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        // Defaults to dark, not system: this is a backend that sits on a desk running a browser, and
        // the rest of the product's authed surface is dark. A first launch that came up white would
        // look like a different app.
        choice = stored.flatMap(Choice.init(rawValue:)) ?? .dark
    }
}

/// The segmented light/dark/system control. Used at the top of the landing page and in Settings —
/// the same two places the web app offers it.
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
