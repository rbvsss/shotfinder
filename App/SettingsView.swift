import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = KeyStore.load() ?? ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CLAUDE API KEY")
                .font(Theme.label())
                .foregroundStyle(Theme.muted)

            SecureField("Paste your key", text: $apiKey)
                .font(Theme.text)
                .foregroundStyle(Theme.paper)
                .tint(Theme.signal)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Theme.raised)

            Text(message ?? "Scanning uses your key and your credits. The key stays in this phone's Keychain and only goes to Claude.")
                .font(Theme.text)
                .foregroundStyle(message == nil ? Theme.muted : Theme.paper)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: save) {
                Text("SAVE")
                    .font(Theme.label())
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.paper)
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ink.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeyStore.delete()
            dismiss()
        } else if KeyStore.save(trimmed) {
            dismiss()
        } else {
            message = "The key couldn't be saved. Try again."
        }
    }
}
