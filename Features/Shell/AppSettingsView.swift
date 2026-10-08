import SwiftUI

/// One settings surface shared by every top-level destination.
struct AppSettingsView: View {
    var learningModel: LearningViewModel? = nil
    @EnvironmentObject private var settings: ReaderSettingsStore
    @EnvironmentObject private var modelPrefs: AIModelPreferenceStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsLearningPreferences = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Make it comfortable") {
                    Picker("Appearance", selection: $settings.colorScheme) {
                        ForEach(ReaderColorScheme.allCases) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .accessibilityIdentifier("settings.appearance")
                    if learningModel != nil {
                        Button("Learning preferences") { showsLearningPreferences = true }
                            .accessibilityIdentifier("learning.preferences")
                    }
                }
                Section {
                    NavigationLink {
                        Form { AISettingsSection(modelPrefs: modelPrefs, keyStore: KeychainAPIKeyStore.shared) }
                            .navigationTitle("BookBot")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("BookBot", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("settings.bookbot")
                } footer: {
                    Text("BookBot is optional. Saved books and the physics course work without an AI connection.")
                }
                Section("About GenBooks") {
                    NavigationLink { FoundationsView() } label: {
                        Label("Foundations", systemImage: "leaf")
                    }
                    .accessibilityIdentifier("settings.foundations")
                    NavigationLink { PrivacyAndSupportView(page: .privacy) } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings.privacy")
                    NavigationLink { PrivacyAndSupportView(page: .support) } label: {
                        Label("Help & Support", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings.support")
                    NavigationLink { OpenSourceNoticesView() } label: {
                        Label("Open-source notices", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("settings.notices")
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LRColor.background)
            .navigationTitle("Settings")
            .genBooksNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsLearningPreferences) {
                if let learningModel { LearningPreferencesView(model: learningModel) }
            }
        }
        .tint(LRColor.accent)
    }
}
