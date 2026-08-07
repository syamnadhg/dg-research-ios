import SwiftUI

/// The output of an operation that produced more than one line.
///
/// ⚠ Without this, Doctor and Version had nowhere to put their answer. "Version" that reports the
/// version only into a two-second toast is a button you have to press twice to read, and a doctor
/// that says "2 problems found" without naming them is a diagnosis you cannot act on. The owner's
/// ask was that Version show the current backend version *on tap* — this is where it shows.
struct OpDetailSheet: View {
    let title: String
    let body_: String
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.lg) {
            HStack {
                Text(title).font(DS.F.body.weight(.medium)).foregroundStyle(DS.C.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Text("Done").font(DS.F.label).foregroundStyle(DS.C.accent)
                }
                .frame(minWidth: DS.S.touch, minHeight: DS.S.touch)
            }

            ScrollView {
                // Monospaced and selectable: these reports get pasted into a bug thread, and a
                // proportional font turns an aligned findings list into a ragged one.
                Text(body_)
                    .font(DS.F.mono(11))
                    .foregroundStyle(DS.C.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                UIPasteboard.general.string = body_
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy")
                    .font(DS.F.label.weight(.medium))
                    .foregroundStyle(copied ? DS.C.ok : DS.C.accent)
                    .frame(maxWidth: .infinity, minHeight: DS.S.touch)
                    .background(DS.C.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(DS.S.screen)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.bg)
        .presentationDetents([.medium, .large])
    }
}
