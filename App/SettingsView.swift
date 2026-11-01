import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("camera.grid") private var showsGrid = false
    @AppStorage("camera.level") private var showsLevel = true
    @State private var apiKey = KeyStore.load() ?? ""
    @State private var savedKey = KeyStore.load() ?? ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Toggle("Grid", isOn: $showsGrid)
                    Toggle("Level", isOn: $showsLevel)
                }

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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                }
            }
        }
        .presentationDetents([.medium])
        // A swipe away shouldn't lose a key you just pasted. Done saves it.
        .interactiveDismissDisabled(apiKey != savedKey)
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
