import SwiftUI

/// Add or replace one API key.
///
/// ⚠ The reason this exists: Settings could *report* a key as saved but offered no way to change it.
/// A rotated or mistyped key was therefore unfixable from inside the app — the only route was Clear
/// state, which also destroys the pairing and every platform login. Reporting a problem you cannot
/// act on is worse than not reporting it.
///
/// **Write-only by design.** The stored value is never loaded back into the field. That is the same
/// rule the presence-only `APIKeyStore.has` was written for: a key rendered on screen is a key in
/// every screenshot, screen recording and shoulder-glance from then on. The cost is that replacing a
/// key means pasting it in full, which is the correct trade for a bearer credential.
struct APIKeyEditor: View {
    let kind: APIKeyStore.Kind
    let onDone: () -> Void

    @State private var value = ""
    @State private var confirmingRemoval = false
    @FocusState private var focused: Bool

    private var title: String {
        switch kind {
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    /// What the platform's own keys look like, so an obviously wrong paste is caught here rather
    /// than three phases into a run as an opaque 401.
    private var expectedPrefix: String? {
        switch kind {
        case .anthropic: return "sk-ant-"
        case .gemini: return nil    // Google's keys carry no stable documented prefix
        }
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var warning: String? {
        guard !trimmed.isEmpty else { return nil }
        if let expectedPrefix, !trimmed.hasPrefix(expectedPrefix) {
            return "Anthropic keys normally start with \(expectedPrefix) — check you pasted the whole thing."
        }
        // Deliberately advisory, never blocking. A length or prefix rule that hard-refuses is a rule
        // that breaks the day the vendor changes format, and the person it locks out is the owner.
        if trimmed.count < 20 { return "That looks too short for an API key." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                Text(APIKeyStore.has(kind) ? "Replace \(title) key" : "Add \(title) key")
                    .font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
                Spacer()
                Button(action: onDone) {
                    Text("Cancel").font(DS.F.label).foregroundStyle(DS.C.textSecondary)
                }
                .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
            }

            SecureField("Paste the key", text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(DS.F.mono(12))
                .foregroundStyle(DS.C.textPrimary)
                .padding(DS.S.md)
                .background(DS.C.bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.C.border, lineWidth: 1))
                .focused($focused)

            if let warning {
                Text(warning).font(DS.F.label).foregroundStyle(DS.C.warn)
            }

            if APIKeyStore.has(kind) {
                Text("A key is already saved. Saving replaces it; the old one is not shown.")
                    .font(DS.F.label).foregroundStyle(DS.C.textTertiary)
            }

            SRButton(title: "Save", role: .primary) {
                APIKeyStore.save(kind, trimmed)
                onDone()
            }
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.5 : 1)

            if APIKeyStore.has(kind) {
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Text("Remove this key")
                        .font(DS.F.label).foregroundStyle(DS.C.danger)
                        .frame(maxWidth: .infinity, minHeight: DS.S.touch)
                }
                .buttonStyle(.plain)
                // Confirmed, because removal is silent and irreversible — the value is gone and
                // cannot be read back to retype.
                .confirmationDialog(
                    "Remove the \(title) key?", isPresented: $confirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        APIKeyStore.remove(kind)
                        onDone()
                    }
                    Button("Keep it", role: .cancel) {}
                } message: {
                    Text("Runs that need \(title) will fail until a key is added again.")
                }
            }

            Spacer()
        }
        .padding(DS.S.screen)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.bg)
        // The keyboard comes up on its own: this sheet exists for exactly one paste, and making the
        // owner tap the field first is a step with no purpose.
        .onAppear { focused = true }
        .presentationDetents([.medium])
    }
}

/// `sheet(item:)` needs the selection to be `Identifiable`.
extension APIKeyStore.Kind: Identifiable {
    public var id: String { rawValue }
}
