import SwiftUI

struct FoundationsView: View {
    private let content: FoundationsContent? = try? FoundationsContent.load()

    var body: some View {
        Group {
            if let content {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(content.mission)
                                .font(.system(.title2, design: .serif).weight(.semibold))
                                .foregroundStyle(LRColor.text)
                            Text(content.vision)
                                .font(.body)
                                .foregroundStyle(LRColor.secondaryText)
                        }
                        .padding(.vertical, 8)
                    }
                    Section("Definitions") {
                        ForEach(content.sections.filter { definitionIDs.contains($0.id) }) { section in
                            sectionLink(section)
                        }
                    }
                    Section("How it works") {
                        ForEach(content.sections.filter { !definitionIDs.contains($0.id) }) { section in
                            sectionLink(section)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Foundations unavailable", systemImage: "doc.text",
                                       description: Text("This copy of the app is missing its bundled guide."))
            }
        }
        .background(LRColor.background)
        .navigationTitle("Foundations")
        .genBooksNavigationBar()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("foundations.screen")
    }

    private var definitionIDs: Set<String> { ["retained-knowledge", "skills", "evidence", "experience"] }

    private func sectionLink(_ section: FoundationsContent.Section) -> some View {
        NavigationLink {
            FoundationsSectionView(section: section)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(section.title).font(.headline)
                Text(section.summary).font(.subheadline).foregroundStyle(LRColor.secondaryText)
            }.padding(.vertical, 6)
        }
        .accessibilityIdentifier("foundations.section.\(section.id)")
    }

}

private struct FoundationsSectionView: View {
    let section: FoundationsContent.Section

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(section.title)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(section.summary).font(.title3).foregroundStyle(LRColor.secondaryText)
                ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("•").foregroundStyle(LRColor.accent).accessibilityHidden(true)
                        Text(bullet).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !section.references.isEmpty {
                    Divider()
                    Text("Sources").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.references.enumerated()), id: \.offset) { _, reference in
                        Link(destination: reference.url) {
                            Label(reference.title, systemImage: "arrow.up.right")
                                .frame(minHeight: 44, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.body)
            .foregroundStyle(LRColor.text)
            .textSelection(.enabled)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .background(LRColor.background)
        .navigationTitle(section.title)
        .genBooksNavigationBar()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("foundations.detail.\(section.id)")
    }
}
