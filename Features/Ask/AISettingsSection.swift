import SwiftUI

/// Settings UI for Keychain API key + Ask / generation model preferences.
/// Key text is never persisted to UserDefaults; only written to Keychain on Save.
struct AISettingsSection: View {
    @ObservedObject var modelPrefs: AIModelPreferenceStore
    var keyStore: APIKeyStoring
    /// Called after successful key save/remove or model change so Reader can re-resolve Live vs Mock.
    var onAIConfigurationChanged: (() -> Void)? = nil

    @State private var keyDraft: String = ""
    @State private var hasStoredKey = false
    @State private var statusMessage: String?
    @State private var showingKey = false
    @State private var confirmsKeyRemoval = false

    var body: some View {
        Section {
            Picker("BookBot model", selection: $modelPrefs.askModel) {
                ForEach(OpenAIModelOption.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .accessibilityIdentifier("ai.settings.askModel")
            .onChange(of: modelPrefs.askModel) { _, _ in
                onAIConfigurationChanged?()
            }

            Picker("Book generation model", selection: $modelPrefs.generationModel) {
                ForEach(OpenAIModelOption.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .accessibilityIdentifier("ai.settings.generationModel")
            .onChange(of: modelPrefs.generationModel) { _, _ in
                onAIConfigurationChanged?()
            }

            HStack {
                Group {
                    if showingKey {
                        TextField("sk-…", text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(hasStoredKey ? "•••••••• (saved in Keychain)" : "sk-…", text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .accessibilityIdentifier("ai.settings.key")

                Button {
                    showingKey.toggle()
                } label: {
                    Image(systemName: showingKey ? "eye.slash" : "eye")
                }
                .accessibilityIdentifier("ai.settings.key.toggle")
                .accessibilityLabel(showingKey ? "Hide API key" : "Show API key")
            }

            Button("Save API key to Keychain") {
                saveKey()
            }
            .accessibilityIdentifier("ai.settings.key.save")
            .disabled(!APIKeySettingsActions.canSave(keyDraft))

            if hasStoredKey {
                Button("Remove API key", role: .destructive) {
                    confirmsKeyRemoval = true
                }
                .accessibilityIdentifier("ai.settings.key.remove")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.settings.status")
            }
        } header: {
            Text("BookBot")
        } footer: {
            Text("""
            Your API key is saved in Keychain, secure storage on this iPhone. \
            Optional BookBot sends your questions and their context to OpenAI using the selected model and your key; an internet connection is required. \
            Saved books, physics readings and review checks work offline.
            """)
        }
        .onAppear { refreshKeyPresence() }
        .alert("Remove API key?", isPresented: $confirmsKeyRemoval) {
            Button("Remove API key", role: .destructive) { removeKey() }
                .accessibilityIdentifier("ai.settings.key.remove.confirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("BookBot and new narration will need a key again. Your books, notes and downloaded audio stay on this device.")
        }
    }

    private func refreshKeyPresence() {
        let existing = (try? keyStore.loadAPIKey())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasStoredKey = !(existing?.isEmpty ?? true)
        // Do not prefill the field with the real key (avoids accidental screenshots/logs).
        if keyDraft.isEmpty {
            keyDraft = ""
        }
    }

    private func saveKey() {
        do {
            guard try APIKeySettingsActions.saveDraft(keyDraft, to: keyStore) else { return }
            keyDraft = ""
            showingKey = false
            refreshKeyPresence()
            statusMessage = "Saved to Keychain."
            onAIConfigurationChanged?()
        } catch {
            statusMessage = "Couldn’t save key."
        }
    }

    private func removeKey() {
        do {
            try keyStore.saveAPIKey(nil)
            keyDraft = ""
            showingKey = false
            refreshKeyPresence()
            statusMessage = "Key removed from Keychain."
            onAIConfigurationChanged?()
        } catch {
            statusMessage = "Couldn’t remove key."
        }
    }
}

/// An untouched secure field is not a request to erase the saved credential.
enum APIKeySettingsActions {
    static func canSave(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    static func saveDraft(_ draft: String, to store: any APIKeyStoring) throws -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        try store.saveAPIKey(trimmed)
        return true
    }
}
