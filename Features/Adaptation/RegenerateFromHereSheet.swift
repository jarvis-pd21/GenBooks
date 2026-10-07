import SwiftUI

/// Cut-boundary preview: which chapters regenerate + remaining reading time before Apply.
struct RegenerateFromHereSheet: View {
    let chapters: [(id: UUID, title: String, orderIndex: Int)]
    let lockedChapterIds: Set<UUID>
    @Binding var selectedChapterId: UUID?
    var preview: RegenerationPreview?
    var isBusy: Bool
    var errorMessage: String?
    var remainingLabel: String?
    var fromCanon: Bool = false
    @Binding var lengthPreset: AdaptationLengthPreset
    var onCutChanged: () -> Void
    var onLengthChanged: () -> Void = {}
    var onBuildPreview: () -> Void
    var onApply: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if fromCanon {
                        Text("Starts from this Canon book. Apply adapts unread future only — consumed words stay exact. After Apply, the book becomes Living.")
                            .font(.subheadline)
                            .accessibilityIdentifier("regen.makeLiving.blurb")
                    }
                    Text(fromCanon
                         ? "Choose an unread chapter boundary. Apply uses the existing Living loop on that chapter and at most the next unread one. This is not a new-book wizard."
                         : "Choose an unread chapter boundary. Apply replaces that full chapter and at most the next unread chapter; text before the boundary and all consumed chapters stay unchanged. Mid-chapter or page cuts are not supported.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cut boundary") {
                    Picker("From chapter", selection: $selectedChapterId) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(chapters.filter { !lockedChapterIds.contains($0.id) }, id: \.id) { chapter in
                            Text(chapter.title).tag(Optional(chapter.id))
                        }
                    }
                    .onChange(of: selectedChapterId) { _, _ in onCutChanged() }
                    .accessibilityIdentifier("regen.cut.picker")
                    .disabled(isBusy)

                    AdaptationLengthPicker(selection: $lengthPreset)
                        .disabled(isBusy)
                        .onChange(of: lengthPreset) { _, _ in onLengthChanged() }
                    Text("Half-length is the default. Full is opt-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if chapters.allSatisfy({ lockedChapterIds.contains($0.id) }) {
                        Text("No unread chapter boundaries remain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Preview regeneration") {
                        onBuildPreview()
                    }
                    .disabled(selectedChapterId == nil || isBusy)
                    .accessibilityIdentifier("regen.preview.button")
                }

                if let preview {
                    Section("Will replace on Apply") {
                        ForEach(preview.regeneratingChapters) { chapter in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.title)
                                    Text("\(chapter.wordCount) words")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(lengthPreset.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .accessibilityIdentifier("regen.chapter.\(chapter.id.uuidString)")
                        }
                        if preview.lockedSkippedCount > 0 {
                            Text("\(preview.lockedSkippedCount) locked chapter(s) skipped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("regen.locked.skipped")
                        }
                    }

                    Section("Remaining reading time") {
                        LabeledContent("Baseline", value: preview.baselineRemaining.displayLabel)
                        LabeledContent("Projected after Apply", value: preview.plannedRemaining.displayLabel)
                        Text("Time uses words ÷ WPM; page count ignored. Visual placeholders weighted separately.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("regen.time.section")
                } else if let remainingLabel {
                    Section("Current remaining") {
                        Text(remainingLabel)
                            .accessibilityIdentifier("regen.remaining.label")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("regen.error")
                    }
                }
            }
            .navigationTitle(fromCanon ? "Make Living" : "Regenerate from here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                        .disabled(isBusy)
                        .accessibilityIdentifier("regen.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply()
                    } label: {
                        if isBusy {
                            ProgressView()
                        } else {
                            Text("Apply")
                        }
                    }
                    .disabled(preview == nil || isBusy)
                    .accessibilityIdentifier("regen.apply")
                }
            }
        }
        .accessibilityIdentifier("regen.sheet")
        .interactiveDismissDisabled(isBusy)
    }
}
