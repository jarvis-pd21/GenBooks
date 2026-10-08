import SwiftUI

/// Reads the same notice distributed in the repository; no network or duplicated license text.
struct OpenSourceNoticesView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return "Open-source notices could not be loaded. Please report this to jarvis@agi-jarvis.com."
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
                .accessibilityIdentifier("notices.content")
        }
        .background(LRColor.background)
        .navigationTitle("Open-source notices")
        .navigationBarTitleDisplayMode(.inline)
        .genBooksNavigationBar()
        .accessibilityIdentifier("notices.screen")
    }
}
