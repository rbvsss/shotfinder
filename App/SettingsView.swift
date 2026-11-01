import SwiftUI

struct SettingsView: View {
    let supportsRAW: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("camera.raw") private var rawEnabled = false
    @State private var apiKey = KeyStore.load() ?? ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first {
                                apiKey = first.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    Text(message ?? footer)
                }

                if supportsRAW {
                    Section {
                        Toggle("Save RAW", isOn: $rawEnabled)
                    } footer: {
                        Text("Also saves an Apple ProRAW file to Photos with each shot.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var footer: String {
        apiKey.isEmpty
            ? "Add your Claude API key to scan. It stays in this iPhone's Keychain and only goes to Claude."
            : "Scans use your key and your credits. It stays in this iPhone's Keychain and only goes to Claude."
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
