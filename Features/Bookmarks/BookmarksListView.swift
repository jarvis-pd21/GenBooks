import SwiftUI

/// Keeps failed edits visible instead of dismissing a sheet as though they saved.
@MainActor
final class BookmarkListModel: ObservableObject {
    @Published private(set) var items: [NamedBookmark] = []
    @Published private(set) var errorMessage: String?
    @Published var query = ""
    @Published var renameTarget: NamedBookmark?
    @Published var renameDraft = ""
    @Published var deleteTarget: NamedBookmark?
    private let store: BookmarkStoring
    private let bookId: UUID?

    init(store: BookmarkStoring, bookId: UUID?) {
        self.store = store
        self.bookId = bookId
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var filtered: [NamedBookmark] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.snippet.localizedCaseInsensitiveContains(q)
                || $0.chapterTitle.localizedCaseInsensitiveContains(q)
        }
    }
    var canSaveRename: Bool {
        renameTarget != nil && !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasRenameChanges: Bool {
        guard let renameTarget else { return false }
        return renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != renameTarget.title
    }

    func reload() {
        do {
            if let bookId { items = try store.loadBookmarks(bookId: bookId) }
            else { items = try store.loadAllBookmarks() }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load bookmarks. \(error.localizedDescription)"
        }
    }

    func beginRename(_ bookmark: NamedBookmark) {
        renameTarget = bookmark
        renameDraft = bookmark.title
        errorMessage = nil
    }

    func cancelRename() {
        renameTarget = nil
        renameDraft = ""
    }

    @discardableResult
    func saveRename() -> Bool {
        guard let target = renameTarget, canSaveRename else { return false }
        do {
            try store.renameBookmark(id: target.id, bookId: target.bookId,
                                     title: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            renameTarget = nil
            renameDraft = ""
            reload()
            return true
        } catch {
            errorMessage = "Couldn’t rename bookmark. Your title is still here. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func confirmDelete() -> Bool {
        guard let target = deleteTarget else { return false }
        do {
            try store.deleteBookmark(id: target.id, bookId: target.bookId)
            deleteTarget = nil
            reload()
            return true
        } catch {
            deleteTarget = nil
            errorMessage = "Couldn’t delete bookmark. \(error.localizedDescription)"
            return false
        }
    }
}

struct BookmarksListView: View {
    let bookTitle: String?
    var onOpen: ((NamedBookmark) -> Void)?
    @StateObject private var model: BookmarkListModel
    @State private var confirmDiscardRename = false

    init(bookTitle: String?, bookmarks: BookmarkStoring, bookId: UUID?,
         onOpen: ((NamedBookmark) -> Void)? = nil) {
        self.bookTitle = bookTitle
        self.onOpen = onOpen
        _model = StateObject(wrappedValue: BookmarkListModel(store: bookmarks, bookId: bookId))
    }

    var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                        .accessibilityIdentifier("bookmarks.error")
                    Button("Try again") { model.reload() }
                        .accessibilityIdentifier("bookmarks.retry")
                }
            }
            Section("Bookmarks") {
                ForEach(model.filtered) { bookmark in
                    HStack(alignment: .center, spacing: 8) {
                        if let onOpen {
                            Button { onOpen(bookmark) } label: { bookmarkLabel(bookmark) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("bookmarks.row.\(bookmark.id.uuidString)")
                        } else {
                            bookmarkLabel(bookmark)
                                .accessibilityIdentifier("bookmarks.row.\(bookmark.id.uuidString)")
                        }
                        Menu {
                            Button("Rename", systemImage: "pencil") { model.beginRename(bookmark) }
                            Button("Delete bookmark", systemImage: "trash", role: .destructive) {
                                model.deleteTarget = bookmark
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Actions for \(bookmark.title)")
                        .accessibilityIdentifier("bookmarks.actions.\(bookmark.id.uuidString)")
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) { model.deleteTarget = bookmark } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { model.beginRename(bookmark) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                }
                if model.filtered.isEmpty && model.errorMessage == nil {
                    if model.hasQuery {
                        // Full-size ContentUnavailableView pushes its recovery action
                        // below the keyboard at accessibility text sizes.
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No matching bookmarks")
                                .font(.headline)
                                .accessibilityIdentifier("bookmarks.search.empty")
                            Button { model.query = "" } label: {
                                Text("Clear search")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("bookmarks.search.clear")
                            Text("Try another title, passage, or chapter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    } else {
                        Text("No bookmarks yet. Select a passage while reading, then choose Bookmark.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("bookmarks.empty")
                    }
                }
            }
        }
        .navigationTitle(bookTitle.map { "Bookmarks · \($0)" } ?? "Bookmarks")
        .searchable(text: $model.query, prompt: "Search bookmarks")
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("bookmarks.list")
        .onAppear { model.reload() }
        .alert("Delete bookmark?", isPresented: Binding(
            get: { model.deleteTarget != nil },
            set: { if !$0 { model.deleteTarget = nil } }
        ), presenting: model.deleteTarget) { target in
            Button("Delete bookmark", role: .destructive) {
                model.deleteTarget = target
                model.confirmDelete()
            }
                .accessibilityIdentifier("bookmarks.delete.confirm")
            Button("Cancel", role: .cancel) { model.deleteTarget = nil }
        } message: { _ in
            Text("Only this saved bookmark will be removed. Your book, notes, and reading position stay unchanged.")
        }
        .sheet(item: $model.renameTarget) { target in
            NavigationStack {
                Form {
                    Section("Title") {
                        TextField("Bookmark title", text: $model.renameDraft, axis: .vertical)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("bookmarks.rename.field")
                    }
                    Section("Snippet") {
                        Text(target.snippet).font(.body).foregroundStyle(.secondary)
                    }
                    if let errorMessage = model.errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                                .accessibilityIdentifier("bookmarks.rename.error")
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Rename bookmark")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if model.hasRenameChanges { confirmDiscardRename = true }
                            else { model.cancelRename() }
                        }
                        .accessibilityIdentifier("bookmarks.rename.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { model.saveRename() }
                            .disabled(!model.canSaveRename)
                            .accessibilityIdentifier("bookmarks.rename.save")
                    }
                }
                .alert("Discard title changes?", isPresented: $confirmDiscardRename) {
                    Button("Discard changes", role: .destructive) { model.cancelRename() }
                    Button("Keep editing", role: .cancel) {}
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.hasRenameChanges)
            .accessibilityIdentifier("bookmarks.rename.sheet")
        }
    }

    private func bookmarkLabel(_ bookmark: NamedBookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bookmark.title).font(.body).lineLimit(2)
            Text("\(bookmark.chapterTitle) · \(bookmark.snippet)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct BookBookmarksListView: View {
    let bookId: UUID
    let bookTitle: String
    var bookmarks: BookmarkStoring
    var onOpen: ((NamedBookmark) -> Void)?

    var body: some View {
        BookmarksListView(bookTitle: bookTitle, bookmarks: bookmarks, bookId: bookId, onOpen: onOpen)
    }
}
