import SwiftUI
import UIKit

/// Single Words surface (Notebook tab + reader overflow). Formerly titled Vocabulary.
///
/// `externalQuery` lets a host that already owns a search field — the Notebook hub — drive
/// the filter, instead of stacking a second search bar on top of its own.
struct VocabularyListView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: VocabularyStoring
    var bookId: UUID?
    var externalQuery: Binding<String>?
    var onOpen: ((VocabularyEntry) -> Void)?
    @State private var entries: [VocabularyEntry] = []
    @State private var ownQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var errorMessage: String?
    @State private var pendingDelete: VocabularyEntry?
    @State private var showDeleteConfirmation = false
    @State private var actionError: String?

    private var query: String { externalQuery?.wrappedValue ?? ownQuery }

    var body: some View {
        VStack(spacing: 0) {
            if externalQuery == nil {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search words", text: $ownQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("vocab.search")
                        .focused($searchFocused)
                    if !ownQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            ownQuery = ""
                            searchFocused = false
                        } label: {
                            Text("Clear")
                                .foregroundStyle(LRColor.navy)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .accessibilityIdentifier("vocab.search.clear")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(LRColor.pillInactive.opacity(0.85), in: Capsule(style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            List {
                if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Try again", action: reload)
                    }
                }
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.phrase)
                                .font(.headline)
                            Spacer()
                            if entry.isKnown {
                                Text("Known")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(entry.definition)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(onOpen == nil ? nil : 3)
                        Text("\(entry.bookTitle) · \(entry.chapterTitle)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 16))
                        layout {
                            Button {
                                update {
                                    try store.markKnown(id: entry.id, isKnown: !entry.isKnown)
                                }
                            } label: {
                                Text(entry.isKnown ? "Mark unlearned" : "Mark known")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("vocab.known.\(entry.id.uuidString)")
                            if onOpen != nil {
                                Button { onOpen?(entry) } label: {
                                    Text("Open")
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("vocab.open.\(entry.id.uuidString)")
                            }
                            Button(role: .destructive) { requestDelete(entry) } label: {
                                Text("Delete")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("vocab.delete.\(entry.id.uuidString)")
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    // Keep one navigable row while preserving the separate
                    // known/open/delete controls inside it.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("vocab.row.\(entry.id.uuidString)")
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            requestDelete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if filtered.isEmpty, errorMessage == nil {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No words yet — select text in the reader and tap Add to Words.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("vocab.empty")
                    } else {
                        Text("No matching words")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("vocab.search.empty")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("vocab.list")
        }
        .background(LRColor.cream)
        .navigationTitle(externalQuery == nil ? "Words" : "Notebook")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vocab.list")
        .onAppear(perform: reload)
        .alert("Delete word?", isPresented: $showDeleteConfirmation) {
            Button("Delete Word", role: .destructive) {
                if let pendingDelete {
                    update { try store.delete(id: pendingDelete.id) }
                }
                pendingDelete = nil
            }
            Button("Keep Word", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removes “\(pendingDelete?.phrase ?? "this word")” from your saved Words. The book and your notes stay unchanged.")
        }
        .alert("Couldn’t update word", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var filtered: [VocabularyEntry] {
        let base: [VocabularyEntry]
        if let bookId {
            base = entries.filter { $0.bookId == bookId }
        } else {
            base = entries
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.phrase.localizedCaseInsensitiveContains(q)
                || $0.definition.localizedCaseInsensitiveContains(q)
                || $0.originalSentence.localizedCaseInsensitiveContains(q)
        }
    }

    private func reload() {
        do {
            entries = try store.loadAll()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load Words. Your saved words haven’t been changed."
        }
    }

    private func requestDelete(_ entry: VocabularyEntry) {
        pendingDelete = entry
        showDeleteConfirmation = true
    }

    private func update(_ action: () throws -> Void) {
        do {
            try action()
            reload()
        } catch {
            actionError = "The change wasn’t saved. Your word is still here; try again."
        }
    }
}
