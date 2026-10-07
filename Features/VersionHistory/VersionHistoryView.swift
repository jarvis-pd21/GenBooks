import SwiftUI

struct ChapterVersionGroup: Identifiable {
    let id: UUID
    let chapterTitle: String
    let rows: [ChapterVersionEntry]

    /// Titles can repeat within an imported book. Only chapter identity groups revisions.
    static func groups(_ entries: [ChapterVersionEntry]) -> [ChapterVersionGroup] {
        var order: [UUID] = []
        var map: [UUID: [ChapterVersionEntry]] = [:]
        for entry in entries {
            if map[entry.chapterId] == nil { order.append(entry.chapterId) }
            map[entry.chapterId, default: []].append(entry)
        }
        return order.compactMap { chapterId in
            guard let entries = map[chapterId], let title = entries.first?.chapterTitle else { return nil }
            return ChapterVersionGroup(id: chapterId, chapterTitle: title,
                                       rows: entries.sorted { $0.revisionIndex > $1.revisionIndex })
        }
    }
}

/// Sheets-like revision history: browse every version a chapter has had, see why each one
/// exists, and restore any of them. Restore is offered only for chapters you haven't finished —
/// the consumed past is permanent by design.
struct VersionHistoryView: View {
    let bookTitle: String
    let entries: [ChapterVersionEntry]
    var isRestoring: Bool
    var errorMessage: String?
    /// Chapter the reader came from; history opens scoped to it when it has versions.
    var focusChapterId: UUID? = nil
    var onRestore: (ChapterVersionEntry) -> Void
    var onClose: () -> Void

    enum Scope: String, CaseIterable, Identifiable {
        case thisChapter
        case wholeBook

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .thisChapter: return "This chapter"
            case .wholeBook: return "Whole book"
            }
        }
    }

    @State private var scope: Scope = .thisChapter

    private var canScopeToChapter: Bool {
        guard let focusChapterId else { return false }
        return entries.contains { $0.chapterId == focusChapterId }
    }

    private var visibleEntries: [ChapterVersionEntry] {
        guard scope == .thisChapter, canScopeToChapter, let focusChapterId else { return entries }
        return entries.filter { $0.chapterId == focusChapterId }
    }

    private var grouped: [ChapterVersionGroup] { ChapterVersionGroup.groups(visibleEntries) }

    var body: some View {
        NavigationStack {
            List {
                if canScopeToChapter {
                    Section {
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("versionHistory.scope.picker")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("versionHistory.error")
                    }
                }

                if visibleEntries.isEmpty {
                    ContentUnavailableView(
                        "No versions yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Revisions appear here after adaptations or restores.")
                    )
                } else {
                    ForEach(grouped) { group in
                        Section(group.chapterTitle) {
                            ForEach(group.rows) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                        .accessibilityIdentifier("versionHistory.done")
                }
                if isRestoring {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView()
                    }
                }
            }
            .onAppear {
                scope = canScopeToChapter ? .thisChapter : .wholeBook
            }
        }
        .accessibilityIdentifier("versionHistory.sheet")
    }

    @ViewBuilder
    private func row(_ entry: ChapterVersionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("v\(entry.revisionIndex)")
                    .font(.headline.monospacedDigit())
                if entry.isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                if entry.isConsumedLocked {
                    Text("Locked")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let originLabel = entry.originLabel {
                Text(originLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .accessibilityIdentifier("versionHistory.origin.\(entry.revisionId.uuidString)")
            }

            Text(entry.previewSnippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(entry.proseWordCount) words · \(entry.visualBlockCount) visuals")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !entry.isConsumedLocked && !entry.isActive {
                Button {
                    onRestore(entry)
                } label: {
                    Label("Restore this version", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(isRestoring)
                .accessibilityIdentifier("versionHistory.restore.\(entry.revisionId.uuidString)")
            } else if entry.isConsumedLocked {
                Text("Consumed chapter — every version is read-only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("versionHistory.row.\(entry.revisionId.uuidString)")
    }
}
