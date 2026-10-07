import SwiftUI

struct LearningSourcesView: View {
    let course: LearningCourse

    var body: some View {
        List {
            Section("This course") {
                Text(course.authorship)
                Text("An original introductory companion, not an edition or summary of Feynman's The Character of Physical Law.")
                    .font(.subheadline).foregroundStyle(LRColor.secondaryText)
            }.listRowBackground(LRColor.surface)
            Section {
                ForEach(course.sources) { source in
                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: source.url) {
                            Label(source.title, systemImage: "arrow.up.right")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 44)
                        Text(source.supports).font(.body)
                        Text(source.rights).font(.caption).foregroundStyle(LRColor.secondaryText)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(LRColor.surface)
                }
            } header: { Text("References") }
            footer: { Text("The readings and questions work offline. These reference websites require an internet connection.") }
        }
        .scrollContentBackground(.hidden).background(LRColor.background)
        .foregroundStyle(LRColor.text).tint(LRColor.accent)
        .navigationTitle("Sources and authorship").navigationBarTitleDisplayMode(.inline)
        .learningPaperToolbar()
    }
}

/// Compatibility entry point for an explicitly presented reference sheet.
/// Normal navigation and Settings both push the shared native Foundations view.
struct LearningDefinitionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FoundationsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("learning.guide.close")
                    }
                }
        }.tint(LRColor.accent)
    }
}
