import SwiftUI

private enum NotebookKind: String, CaseIterable, Identifiable {
    case words, notes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: return "Words"
        case .notes: return "Notes"
        }
    }
}

/// Notebook hub: one surface per kind of saved thing, one name each.
/// Words is `VocabularyListView`; Notes is every annotated passage, colour marks included.
struct NotebookView: View {
    @ObservedObject var model: LibraryViewModel
    var learningModel: LearningViewModel? = nil
    @State private var showSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind: NotebookKind = .words
    @State private var query = ""
    @State private var rows: [NoteRow] = []
    @State private var errorMessage: String?
    @State private var editingRow: NoteRow?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterPills
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .background(LRColor.cream.ignoresSafeArea())
            .navigationTitle("Notebook")
            .navigationBarTitleDisplayMode(.large)
            .genBooksNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .accessibilityIdentifier("notebook.settings")
                }
            }
            .sheet(isPresented: $showSettings) { AppSettingsView(learningModel: learningModel) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notebook.screen")
            .onAppear(perform: reload)
            .onChange(of: kind) { _, _ in reload() }
            .sheet(item: $editingRow, onDismiss: reload) { row in
                if let annotations = model.annotations {
                    StoredNoteEditorSheet(row: row, annotations: annotations) { editingRow = nil }
                }
            }
        }
    }

    /// One search field for the whole hub — the Words surface used to bring a second one.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Notebook", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("notebook.search")
                .focused($searchFocused)
            if kind == .words && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("notebook.search.clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(LRColor.secondarySurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var filterPills: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                collectionPicker.pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                collectionPicker.pickerStyle(.segmented)
            }
        }
        .accessibilityIdentifier("notebook.collection")
    }

    private var collectionPicker: some View {
        Picker("Collection", selection: $kind) {
            ForEach(NotebookKind.allCases) { item in
                Text(item.title).tag(item)
                    .accessibilityIdentifier("notebook.filter.\(item.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView("Notebook error", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            switch kind {
            case .words:
                if let vocabulary = model.vocabulary {
                    VocabularyListView(store: vocabulary, externalQuery: $query)
                } else {
                    emptyState(
                        systemImage: "text.badge.plus",
                        title: "No saved words",
                        subtitle: "Select text while reading and choose Add to Words.",
                        accessibilityIdentifier: "vocab.list"
                    )
                }
            case .notes:
                notesContent
            }
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        let visible = NoteRowFilter.matching(query, in: rows)
        if visible.isEmpty {
            emptyState(
                systemImage: "note.text",
                title: "No notes yet",
                subtitle: "Select text while reading and choose Note. Pick a colour, and write words only if you want to.",
                accessibilityIdentifier: "notes.list"
            )
        } else {
            List(visible) { row in
                Button { editingRow = row } label: {
                    NoteRowView(row: row)
                }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit or delete this note")
                    .listRowBackground(LRColor.cream)
                    .accessibilityIdentifier("notes.row.\(row.id.uuidString)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notes.list")
        }
    }

    private func emptyState(
        systemImage: String,
        title: String,
        subtitle: String,
        accessibilityIdentifier: String = "notebook.empty"
    ) -> some View {
        let hasSearch = kind != .words && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 12) {
            Spacer(minLength: hasSearch ? 0 : 40)
            Image(systemName: hasSearch ? "magnifyingglass" : systemImage)
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(LRColor.emptyIcon)
            Text(hasSearch ? "No matching \(kind.title.lowercased())" : title)
                .font(LRFont.sans(17, weight: .semibold))
                .foregroundStyle(LRColor.navy)
                .accessibilityIdentifier(hasSearch ? "notebook.noResults" : "notebook.empty.title")
            Text(hasSearch ? "Try another search or clear it." : subtitle)
                .font(LRFont.sans(14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if hasSearch {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Text("Clear search")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(LRColor.navy)
                .accessibilityIdentifier("notebook.search.clear")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func reload() {
        do {
            if let annotations = model.annotations {
                rows = NoteRowBuilder.rows(
                    highlights: try annotations.loadAllHighlights(),
                    notes: try annotations.loadAllNotes()
                )
            } else {
                rows = []
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
