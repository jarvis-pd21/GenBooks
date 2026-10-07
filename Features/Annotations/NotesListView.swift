import SwiftUI

/// The in-book Notes surface. Notes are the one feature: every row is a note on a passage,
/// carrying a colour category and, when the reader wrote one, a body.
struct BookNotesListView: View {
    let bookId: UUID
    var annotations: AnnotationStoring
    var onOpen: ((NoteRow) -> Void)?
    @State private var rows: [NoteRow] = []
    @State private var query = ""
    @State private var editingRow: NoteRow?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage).foregroundStyle(.red)
                    Button(action: reload) {
                        Text("Try again")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                .accessibilityIdentifier("notes.error")
            }
            ForEach(filtered) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Button { editingRow = row } label: {
                        NoteRowView(row: row, showsFullText: onOpen == nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit or delete this note")
                    HStack {
                        Button { editingRow = row } label: {
                            Text("Edit Note")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("notes.edit.\(row.id.uuidString)")
                        if let onOpen {
                            Spacer()
                            Button { onOpen(row) } label: {
                                Text("Open passage")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("notes.open.\(row.id.uuidString)")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notes.row.\(row.id.uuidString)")
            }
            if filtered.isEmpty, errorMessage == nil {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No notes yet — select text while reading and choose Note. A note can be just a colour.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No matching notes").foregroundStyle(.secondary)
                        Button { query = "" } label: {
                            Text("Clear search")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("notes.search.clear")
                    }
                }
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $query)
        .accessibilityIdentifier("notes.list")
        .onAppear(perform: reload)
        .sheet(item: $editingRow, onDismiss: reload) { row in
            StoredNoteEditorSheet(row: row, annotations: annotations) { editingRow = nil }
        }
    }

    private var filtered: [NoteRow] {
        NoteRowFilter.matching(query, in: rows)
    }

    private func reload() {
        do {
            rows = NoteRowBuilder.rows(
                highlights: try annotations.loadHighlights(bookId: bookId),
                notes: try annotations.loadNotes(bookId: bookId)
            )
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load notes. Your saved notes haven’t been changed."
        }
    }
}

/// A list can edit saved annotations without reopening or moving the book.
struct StoredNoteEditorSheet: View {
    let row: NoteRow
    let annotations: AnnotationStoring
    let onClose: () -> Void
    @State private var draft: String
    @State private var color: HighlightColor

    init(row: NoteRow, annotations: AnnotationStoring, onClose: @escaping () -> Void) {
        self.row = row
        self.annotations = annotations
        self.onClose = onClose
        _draft = State(initialValue: row.note ?? "")
        _color = State(initialValue: row.color)
    }

    var body: some View {
        NoteEditorSheet(
            selectedText: row.selectedText, isEditingExisting: true,
            draft: $draft, color: $color,
            onSave: {
                try annotations.saveNotePassage(row, body: draft, color: color)
                onClose()
            },
            onClose: onClose,
            onDelete: {
                try annotations.deleteNotePassage(row)
                onClose()
            }
        )
    }
}

/// Shared row layout so the reader surface and the Notebook pill read identically.
struct NoteRowView: View {
    let row: NoteRow
    var showsFullText = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule(style: .continuous)
                .fill(row.color.tint)
                .frame(width: 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let note = row.note, row.hasNote {
                    Text(note)
                        .font(.body)
                        .lineLimit(showsFullText ? nil : 4)
                }
                Text(row.selectedText)
                    .font(row.hasNote ? .callout : .body)
                    .foregroundStyle(row.hasNote ? .secondary : .primary)
                    .lineLimit(showsFullText ? nil : 3)
                Text("\(row.color.displayName) · \(row.chapterTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}

enum NoteRowFilter {
    static func matching(_ query: String, in rows: [NoteRow]) -> [NoteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter {
            $0.selectedText.localizedCaseInsensitiveContains(trimmed)
                || ($0.note?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || $0.chapterTitle.localizedCaseInsensitiveContains(trimmed)
                || $0.color.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
