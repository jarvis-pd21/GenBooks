import SwiftUI

/// Saved metadata and retained research snapshots; no AI or mutable reader state.
struct BookGuideContent: Equatable {
    let title: String
    let author: String?
    let subtitle: String?
    let edition: String?
    let synopsis: String?
    let notes: [String]
    let timeline: [TimelineEvent]
    let sources: [RetrievedResearchSource]
    let isSourcePreview: Bool

    var overviewTitle: String { isSourcePreview ? "Opening passage · preview" : "Overview · whole book" }
    var overviewEmptyText: String {
        isSourcePreview ? "No reviewed opening passage saved yet." : "No overview saved for this book."
    }
    var revisionNotice: String {
        isSourcePreview
            ? "The opening passage comes from the active source-reviewed revision. Timeline and editorial notes are saved separately and may not reflect later adaptations."
            : "Overview, timeline and editorial notes are saved separately from chapter revisions and may not reflect later adaptations."
    }

    init(book: Book) {
        title = Self.nonblank(book.title) ?? "Untitled book"
        author = Self.nonblank(book.author)
        edition = Self.nonblank(book.edition?.label)
        if let chapter = book.chapters.first(where: { $0.sourceGrounding != nil }) {
            isSourcePreview = true
            // The saved synopsis is the original writing brief and participates
            // in retry identity checks. Project actual reviewed content instead;
            // never replace the brief or rewrite a published revision for display.
            if let preview = Self.reviewedPreview(chapter, bookID: book.id) {
                synopsis = preview.passage
                subtitle = "Source-checked preview · \(preview.words) prose words"
            } else {
                synopsis = nil
                subtitle = chapter.isOutlineStub ? "Source preview · not reviewed" : nil
            }
        } else if book.subtitle == "Source preview · not reviewed",
                  book.provenanceNotes.contains("Pending preview: no source-support review has been completed.") {
            // Retrieval can fail before a source requirement is attached. These
            // exact app-owned markers identify the saved pending preview then.
            isSourcePreview = true
            synopsis = nil
            subtitle = "Source preview · not reviewed"
        } else {
            isSourcePreview = false
            synopsis = Self.nonblank(book.synopsis)
            subtitle = Self.nonblank(book.subtitle)
        }
        notes = book.provenanceNotes.compactMap(Self.nonblank)
        var seenSources = Set<String>()
        sources = book.chapters.compactMap { $0.sourceGrounding?.source }
            .filter { seenSources.insert($0.id).inserted }
        // Preserve the author's stored order for events with equal chronology positions.
        timeline = book.timeline.enumerated().sorted {
            if $0.element.orderIndex != $1.element.orderIndex {
                return $0.element.orderIndex < $1.element.orderIndex
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private static func reviewedPreview(_ chapter: Chapter, bookID: UUID) -> (passage: String, words: Int)? {
        guard let requirement = chapter.sourceGrounding,
              let revisionID = chapter.activeRevisionId,
              let revision = chapter.revision(id: revisionID) else { return nil }
        do {
            try SourceGrounding.validate(receipt: revision.sourceReview, bookID: bookID,
                chapterID: chapter.id, blocks: revision.blocks, requirement: requirement)
            guard let first = try SourceGrounding.prose(revision.blocks, source: requirement.source).first else { return nil }
            return (first, try SourceGrounding.proseWordCount(revision.blocks, source: requirement.source))
        } catch { return nil }
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct BookGuideView: View {
    private let content: BookGuideContent
    let onDone: () -> Void
    @State private var overviewExpanded = false
    @State private var notesExpanded = false
    @State private var sourceLimitsExpanded = false
    @State private var timelineExpanded = false

    init(book: Book, onDone: @escaping () -> Void) {
        content = BookGuideContent(book: book)
        self.onDone = onDone
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(content.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("reader.guide.title")
                    if let subtitle = content.subtitle {
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    Text(content.author ?? "Author not provided")
                        .accessibilityIdentifier("reader.guide.author")
                    if let edition = content.edition {
                        Text(edition)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("reader.guide.edition")
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Saved with this book. No new content is generated here.")
            }

            Section {
                DisclosureGroup(content.overviewTitle, isExpanded: $overviewExpanded) {
                    Text(content.synopsis ?? content.overviewEmptyText)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("reader.guide.synopsis")
                }
                .accessibilityIdentifier("reader.guide.overview")

                DisclosureGroup("Editorial notes", isExpanded: $notesExpanded) {
                    Text("These are saved editorial notes, not an independent source check.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if content.notes.isEmpty {
                        Text("No editorial notes saved for this book.")
                            .accessibilityIdentifier("reader.guide.notes.empty")
                    }
                    ForEach(Array(content.notes.enumerated()), id: \.offset) { index, note in
                        Text(note)
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("reader.guide.note.\(index)")
                    }
                }
                .accessibilityIdentifier("reader.guide.notes")

                DisclosureGroup("Sources and limits", isExpanded: $sourceLimitsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This guide shows saved book information, not a bibliography or an independent fact-check.")
                            .accessibilityIdentifier("reader.guide.sourceLimits.scope")
                        Text("Editorial notes describe the edition’s stated approach; they do not independently verify its claims.")
                            .accessibilityIdentifier("reader.guide.sourceLimits.notes")
                        Text(content.revisionNotice)
                            .accessibilityIdentifier("reader.guide.sourceLimits.revisions")
                        if content.sources.isEmpty {
                            Text("No retained source snapshots are attached to this book. Per-passage citations are not available in this Guide.")
                                .accessibilityIdentifier("reader.guide.sourceLimits.sources.empty")
                        } else {
                            Text("Retained source snapshots are listed below with revision and attribution links.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("reader.guide.sourceLimits.sources.summary")
                        }
                        ForEach(content.sources, id: \.id) { source in
                            DisclosureGroup("Saved \(source.scope == .wikipediaIntroduction ? "introduction" : "opening excerpt"): \(source.title)") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("This retained source may discuss material you have not read. It is not an independent fact-check.")
                                        .foregroundStyle(.secondary)
                                    Text(source.text)
                                        .textSelection(.enabled)
                                        .accessibilityIdentifier("reader.guide.savedSource.text")
                                    Text(source.attribution)
                                    if let metadata = source.extractionMetadata {
                                        Text(metadata.scopeDescription)
                                        Text(metadata.renderingCaveat)
                                            .foregroundStyle(.secondary)
                                        ForEach(Array(metadata.paragraphLocators.enumerated()), id: \.offset) { _, locator in
                                            Text("\(locator.sectionTitle) · paragraph \(locator.paragraphIndex)")
                                                .font(.caption)
                                        }
                                    }
                                    Link("Wikipedia revision \(source.revisionID)", destination: source.revisionURL)
                                    Link("Contributors and history", destination: source.attributionURL)
                                    Link(source.licenseName, destination: source.licenseURL)
                                }
                                .padding(.vertical, 8)
                            }
                            .accessibilityIdentifier("reader.guide.savedSource.open")
                        }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("reader.guide.sourceLimits")

                DisclosureGroup("Timeline · whole book", isExpanded: $timelineExpanded) {
                    Text("This timeline covers the whole book, including unread chapters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader.guide.timeline.warning")
                    if content.timeline.isEmpty {
                        Text("No timeline saved for this book.")
                            .accessibilityIdentifier("reader.guide.timeline.empty")
                    }
                    ForEach(content.timeline) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.yearLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(event.title).font(.headline)
                            Text(event.summary)
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("reader.guide.event.\(event.id.uuidString)")
                    }
                }
                .accessibilityIdentifier("reader.guide.timeline")
            }
        }
        .navigationTitle("Book Guide")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
                    .accessibilityIdentifier("reader.guide.done")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.guide.screen")
    }
}
