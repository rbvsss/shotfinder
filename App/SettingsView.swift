import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = KeyStore.load() ?? ""
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Claude API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Create a key in the Claude Console. It stays in this phone's Keychain and is only sent to Claude when you scan.")
                }
                if saveFailed {
                    Text("Couldn't save the key. Try again.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeyStore.delete()
            dismiss()
        } else if KeyStore.save(trimmed) {
            dismiss()
        } else {
            saveFailed = true
        }
    }
}
