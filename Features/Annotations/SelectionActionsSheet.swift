import SwiftUI
import UIKit



@MainActor
enum SelectionClipboard {
    /// Copy only the reviewed selection, without surrounding context or UI quotes.
    @discardableResult
    static func copy(_ text: String, to pasteboard: UIPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.string = text
        return true
    }
}

/// Display text for the reviewed phrase. A long selection must never wreck the sheet
/// chrome, so it is cut on a word boundary inside a character budget and elided.
enum SelectionPreview {
    static let characterBudget = 48

    static func truncated(_ text: String, budget: Int = characterBudget) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > budget else { return collapsed }

        let head = String(collapsed.prefix(budget))
        var kept = head.lastIndex(where: { $0.isWhitespace })
            .map { String(head[head.startIndex..<$0]) } ?? head
        while let last = kept.last, last.isWhitespace || last.isPunctuation {
            kept.removeLast()
        }
        // A single word longer than the budget has no boundary to cut on.
        return (kept.isEmpty ? head : kept) + "…"
    }
}

struct SelectionActionsSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: ReaderTextSelection
    /// True when these words already carry a note, so the action reads Edit Note.
    var hasExistingNote: Bool = false
    var onDefine: () -> Void
    var onAsk: () -> Void
    var onLearn: () -> Void
    var onNote: () -> Void
    var onBookmark: () -> Void
    var onListen: () -> Void
    var onRegenerateFromWord: () -> Void
    var onClose: () -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // A ScrollView keeps tall content (large type, long phrases) inside its
            // own bounds instead of overflowing up into the header, where the reader
            // page underneath used to show through.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    reviewedPhrase

                    actionGrid

                    Button(action: onRegenerateFromWord) {
                        Label("Change after this word", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)

                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("selection.regenFromWord")

                    Text("The selected word and everything before it stay exactly as they were.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(chromeBackground)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(chromeBackground)
        // Contain children so the sheet id keeps a real frame (iOS 26 otherwise
        // firstMatch can resolve to a ~1pt Button with the same identifier).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection.actions.sheet")
        .onChange(of: selection.selectedText) { _, _ in didCopy = false }
    }

    /// No title: the reviewed phrase below is the heading, and Close sits trailing
    /// per HIG. The opaque fill is what stops reader text bleeding into the chrome.
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Button(action: onClose) {
                Text("Close")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("selection.close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(chromeBackground)
    }

    private var reviewedPhrase: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("“\(SelectionPreview.truncated(selection.selectedText))”")
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .accessibilityIdentifier("selection.phrase")
                .accessibilityLabel("“\(selection.selectedText)”")

            Text(selection.chapterTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Opaque so no reader text composites through the sheet or its header.
    private var chromeBackground: Color { Color(uiColor: .systemBackground) }

    /// Laid out eagerly: every action stays in the accessibility tree even when
    /// it sits below the fold of the starting detent.
    private var actionGrid: some View {
        VStack(spacing: 14) {
            actionRow {
                actionButton(
                    hasExistingNote ? "Edit Note" : "Add Note",
                    systemImage: "note.text",
                    id: "selection.note",
                    action: onNote
                )
                actionButton("Define", systemImage: "book", id: "selection.define", action: onDefine)
            }
            actionRow {
                actionButton(BookBotChrome.askAction, systemImage: "bubble.left.and.bubble.right", id: "selection.ask", action: onAsk)
                actionButton("Add to Words", systemImage: "lightbulb", id: "selection.learn", action: onLearn)
            }
            actionRow {
                actionButton("Bookmark", systemImage: "bookmark", id: "selection.bookmark", action: onBookmark)
                actionButton("Listen", systemImage: "headphones", id: "selection.listen", action: onListen)
            }
            HStack(spacing: 14) {
                actionButton(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc", id: "selection.copy") {
                    didCopy = SelectionClipboard.copy(selection.selectedText, to: .general)
                }
            }
        }
    }

    private func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 14))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout { content() }
    }

    private func actionButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }
}

struct DefineSheet: View {
    let result: DefinitionResult
    var onExplainInContext: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if result.isEnriching {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Filling in senses…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("define.loading")
                    }

                    if let rich = result.rich {
                        sensesSection(rich)
                        if !rich.comparisons.isEmpty {
                            comparisonsSection(rich)
                        }
                    } else {
                        Text(result.definition)
                            .font(.body)
                            .accessibilityIdentifier("define.body")
                    }

                    if let soft = result.softFailMessage, !soft.isEmpty {
                        Text(soft)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("define.softFail")
                    }

                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("define.source")

                    Button("Explain in context", action: onExplainInContext)
                        .accessibilityIdentifier("define.explain")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Define")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("define.sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.rich?.term ?? result.term)
                .font(.title2.bold())
                .accessibilityIdentifier("define.term")

            HStack(spacing: 10) {
                if let pos = result.rich?.partOfSpeech, !pos.isEmpty {
                    Text(pos)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("define.pos")
                }
                if let pronunciation = result.rich?.pronunciation, !pronunciation.isEmpty {
                    Text(pronunciation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("define.pronunciation")
                }
            }
        }
    }

    private func sensesSection(_ rich: RichDefinition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Senses")
                .font(.headline)
                .accessibilityIdentifier("define.senses")

            ForEach(Array(rich.senses.enumerated()), id: \.element.id) { _, sense in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sense.number)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(sense.isContextMatch ? Color.accentColor : .secondary)
                            .frame(minWidth: 28, alignment: .leading)
                        Text(sense.gloss)
                            .font(sense.isContextMatch ? .body.weight(.semibold) : .body)
                            .foregroundStyle(.primary)
                    }
                    if let example = sense.example, !example.isEmpty {
                        Text(example)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                    }
                    if sense.isContextMatch {
                        Text("Matches this passage")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 36)
                            .accessibilityIdentifier("define.sense.match")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(sense.isContextMatch ? "define.sense.match.row" : "define.sense")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func comparisonsSection(_ rich: RichDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synonyms & antonyms")
                .font(.headline)
                .accessibilityIdentifier("define.comparisons.title")

            ForEach(rich.comparisons) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.word)
                            .font(.body.weight(.semibold))
                        Text(row.relationship == "antonym" ? "antonym" : "synonym")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                (row.relationship == "antonym" ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.12)),
                                in: Capsule()
                            )
                    }
                    if !row.tip.isEmpty {
                        Text(row.tip)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("define.comparison")
            }
        }
        .accessibilityIdentifier("define.comparisons")
    }

    private var sourceLabel: String {
        switch result.source {
        case .localLexicon: return "Source: GenBooks dictionary"
        case .luna: return "Source: Luna (in-app)"
        case .mock: return "Source: Mock dictionary"
        case .offlineFallback: return "Source: Offline stub"
        case .appleDictionary: return "Source: In-app (Apple Dictionary available on device)"
        }
    }
}

/// The Notes editor, and the only one. Colour tags the passage; the body is optional, so
/// saving with an empty body leaves a colour mark — the job the old Highlight button did.
///
/// Laid out as a compact stack (not a Form). A Form with Passage + Colour above the
/// field pushed `note.editor.field` off the medium detent and hid the real UITextView
/// behind a cell, so native Paste never updated the draft.
struct NoteEditorSheet: View {
    let selectedText: String
    var isEditingExisting: Bool = false
    @Binding var draft: String
    @Binding var color: HighlightColor
    var onSave: () throws -> Void
    var onClose: () -> Void
    var onDelete: (() throws -> Void)? = nil

    @FocusState private var noteFieldFocused: Bool
    @State private var detent: PresentationDetent = .large
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var showFullPassage = false

    private var canDelete: Bool { isEditingExisting && onDelete != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    passageBlock
                    colourBlock
                    noteBlock
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("note.editor.error")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                        .accessibilityIdentifier("note.editor.cancel")
                }
                // Delete lives in the same chrome as Cancel/Update so it stays
                // visible above the keyboard and on the medium detent. A body
                // control under the draft field was off-screen on first paint.
                ToolbarItemGroup(placement: .confirmationAction) {
                    if canDelete {
                        Button("Delete", role: .destructive) {
                            noteFieldFocused = false
                            confirmDelete = true
                        }
                        .accessibilityLabel("Delete Note")
                        .accessibilityIdentifier("note.editor.delete")
                    }
                    Button(isEditingExisting ? "Update" : "Save") {
                        perform(onSave, failure: "Couldn’t save note. Your changes are still here. Try again.")
                    }
                    .accessibilityIdentifier("note.editor.save")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.editor.sheet")
        .alert("Delete note?", isPresented: $confirmDelete) {
            Button("Delete Note", role: .destructive) {
                if let onDelete {
                    perform(onDelete, failure: "Couldn’t delete note. It is still saved. Try again.")
                }
            }
            Button("Keep Note", role: .cancel) {}
        } message: {
            Text("Deletes this note and its colour mark. The book’s text stays unchanged.")
        }
        .onAppear {
            // First responder is the draft field so native Paste updates `$draft`.
            // Defer one turn so presentation/detent settle before focus claims the field.
            DispatchQueue.main.async {
                noteFieldFocused = true
            }
        }
    }

    private var passageBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Passage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(selectedText)
                .font(.body)
                .lineLimit(showFullPassage ? nil : 3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(color.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("note.editor.passage")
            if !selectedText.isEmpty {
                Button {
                    showFullPassage.toggle()
                } label: {
                    Text(showFullPassage ? "Show less" : "Show full passage")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("note.editor.passage.expand")
            }
        }
    }

    private var colourBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(HighlightColor.allCases) { swatch in
                    colorSwatch(swatch)
                }
            }
            Text("Tags the passage so you can tell your notes apart at a glance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Write a note…", text: $draft, axis: .vertical)
                .lineLimit(4...10)
                .focused($noteFieldFocused)
                .textContentType(.none)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .accessibilityIdentifier("note.editor.field")
                // XCTest often still reads the placeholder on a vertical TextField;
                // expose `$draft` so Paste assertions see the bound value.
                .accessibilityValue(draft)
                .padding(10)
                .frame(minHeight: 88, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .background(DisableSmartPunctuation(refreshToken: noteFieldFocused))
            Text("Optional. Save with no words and the passage keeps just its colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("note.editor.explanation")
        }
    }

    private func colorSwatch(_ swatch: HighlightColor) -> some View {
        let isSelected = color == swatch
        return Button {
            color = swatch
        } label: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(swatch.tint)
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("note.editor.color.\(swatch.rawValue)")
        .accessibilityLabel("\(swatch.displayName) note")
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func perform(_ action: () throws -> Void, failure: String) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = failure
        }
    }
}

#if canImport(UIKit)
/// Vertical SwiftUI `TextField` is a `UITextView`. Smart punctuation would wrap a
/// pasted phrase in the same curly quotes the selection preview uses for display.
private struct DisableSmartPunctuation: UIViewRepresentable {
    /// Bumping this (e.g. when the field becomes focused) re-walks the tree so
    /// smart quotes are off before the first Paste.
    var refreshToken: Bool = false

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.apply(from: uiView)
    }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply(from: self)
        }

        func apply(from view: UIView) {
            var node: UIView? = view.superview
            while let current = node {
                if disable(in: current) { return }
                node = current.superview
            }
        }

        @discardableResult
        private func disable(in view: UIView) -> Bool {
            if let textView = view as? UITextView {
                textView.smartQuotesType = .no
                textView.smartDashesType = .no
                textView.smartInsertDeleteType = .no
                return true
            }
            if let textField = view as? UITextField {
                textField.smartQuotesType = .no
                textField.smartDashesType = .no
                textField.smartInsertDeleteType = .no
                return true
            }
            for child in view.subviews where disable(in: child) {
                return true
            }
            return false
        }
    }
}
#else
private struct DisableSmartPunctuation: View {
    var refreshToken: Bool = false
    var body: some View { EmptyView() }
}
#endif

/// One palette for the page paint, the editor swatches and the Notes list chips, so a
/// colour category looks the same everywhere it is shown.
enum NoteColorPalette {
    static func uiColor(for color: HighlightColor) -> UIColor {
        switch color {
        case .yellow: return UIColor.systemYellow.withAlphaComponent(0.38)
        case .green: return UIColor.systemGreen.withAlphaComponent(0.32)
        case .blue: return UIColor.systemBlue.withAlphaComponent(0.28)
        case .pink: return UIColor.systemPink.withAlphaComponent(0.28)
        }
    }
}

extension HighlightColor {
    var tint: Color { Color(NoteColorPalette.uiColor(for: self)) }
}
