import SwiftUI

/// "Change the book after this word."
///
/// Reached from the selection actions, never from always-visible chrome. States plainly
/// how much text is frozen through the anchor before anything is generated.
struct RegenerateFromWordSheet: View {
    let anchor: RegenerationWordAnchor
    /// True when the selected word sits in a finished (consumed) chapter — subtitle tints red;
    /// Ordinary Apply moves to the next unread chapter; source mode refuses the finished chapter.
    var chapterFinished: Bool = false
    @Binding var intents: Set<RegenerationIntent>
    @Binding var freeText: String
    var preview: WordForwardRegenerationPreview?
    var isSourceMode: Bool = false
    var sourceState: SourceContinuationState? = nil
    var offlineEvidence: String? = nil
    var isBusy: Bool
    var canPreview: Bool
    var canApply: Bool
    var errorMessage: String?
    var onRequestChanged: () -> Void
    var onBuildPreview: () -> Void
    var onApply: () -> Void
    var onOpenVersionHistory: () -> Void
    var onClose: () -> Void
    var onStartNewSourceChange: () -> Void = {}
    @State private var confirmStartNew = false

    private var availableIntents: [RegenerationIntent] {
        isSourceMode ? [.moreExplanation, .lessDetail] : RegenerationIntent.allCases
    }

    private var applyTitle: String {
        guard isSourceMode, let sourceState else { return "Apply" }
        switch sourceState.phase {
        case .needsReview, .reviewing: return "Retry review"
        case .readyToPublish, .publishing: return "Publish saved text"
        case .published: return "Open saved result"
        case .prepared: return "Write and review"
        case .writing, .uncertain: return "Start new required"
        }
    }

    private var sourceStatus: String {
        if isBusy { return "Working on this saved-source change. Text is published only after its source review passes." }
        guard let sourceState else { return "Prepare this text-only change before writing. No new source is retrieved." }
        switch sourceState.phase {
        case .prepared: return "Request saved. Writing has not started."
        case .writing, .uncertain:
            return "Writing may have been interrupted. It will not be repeated automatically. Start new archives this attempt."
        case .needsReview, .reviewing:
            return "The written candidate is saved. Retry reviews the same text without calling the writer again."
        case .readyToPublish, .publishing:
            return "The review is saved. Publication retries use that exact text and review without another AI call."
        case .published: return "This attempt was published. Opening the result checks that it is still the active version."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapterFinished ? "Selected “\(anchor.displayWord)”" : "After “\(anchor.displayWord)”")
                            .font(.headline)
                            .accessibilityIdentifier("wordRegen.anchor.word")
                        Text(anchor.chapterTitle)
                            .font(.caption)
                            .foregroundStyle(chapterFinished ? Color.red : Color.secondary)
                            .accessibilityIdentifier("wordRegen.anchor.chapter")
                            .accessibilityValue(chapterFinished ? "finished" : "unread")
                        Text(isSourceMode && chapterFinished
                             ? "This source-preview chapter is finished and cannot be rewritten. The selection will not move to another chapter."
                             : chapterFinished
                             ? "This chapter is finished. Changes begin at the start of the next unread chapter. Every finished chapter stays exactly as you read it."
                             : "Changes begin after this whole word. The selected word, everything before it, and every chapter you’ve finished stay exactly as you read them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("wordRegen.boundary.explanation")
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    Button {
                        onOpenVersionHistory()
                    } label: {
                        Label("Version history", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("wordRegen.versionHistory")
                } footer: {
                    Text(isSourceMode
                         ? "Each published change is saved as a version you can restore later."
                         : "Every regeneration is saved as a version you can restore later.")
                }

                // Preview CTA + results stay above the long intent list so UITests
                // (and readers) can see frozen/rewritten counts without scrolling.
                if !isSourceMode || sourceState == nil {
                    Section {
                        Button(isSourceMode ? "Prepare source change" : "Preview change") { onBuildPreview() }
                            .disabled(!canPreview || isBusy)
                            .accessibilityIdentifier("wordRegen.preview.button")
                    }
                }

                if isSourceMode {
                    Section {
                        Text(sourceStatus)
                            .font(.footnote)
                            .accessibilityIdentifier("wordRegen.source.status")
                            .accessibilityValue(sourceState?.phase.rawValue ?? "unprepared")
                        if isBusy {
                            Text("Working on the saved change. Keep this sheet open until the operation finishes.")
                                .font(.footnote)
                                .accessibilityIdentifier("wordRegen.source.busy")
                        }
                        if let sourceState {
                            Text(sourceState.requestSummary)
                                .accessibilityIdentifier("wordRegen.source.request")
                            LabeledContent("Stays frozen", value: "\(sourceState.frozenPrefixWordCount) words")
                                .accessibilityIdentifier("wordRegen.frozen.words")
                            LabeledContent("Eligible for change", value: "\(sourceState.replacingWordCount) words")
                                .accessibilityIdentifier("wordRegen.regen.words")
                            Button("Start new change") { confirmStartNew = true }
                                .disabled(isBusy)
                                .accessibilityIdentifier("wordRegen.source.startNew")
                        }
                    } header: {
                        Text("Saved-source continuation")
                    } footer: {
                        Text("Text only, using the same saved source. Every assembled paragraph must pass a new source-support review before publication; this is not independent fact-checking.")
                    }
                }

                if let preview {
                    Section("What Apply will do") {
                        HStack {
                            Text("Stays frozen")
                            Spacer()
                            Text("\(preview.frozenPrefixWordCount) words")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("wordRegen.frozen.words")
                        HStack {
                            Text("Rewritten")
                            Spacer()
                            Text("\(preview.regeneratingWordCount) words")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("wordRegen.regen.words")
                        if preview.plannedVisualCount > 0 {
                            HStack {
                                Text("Images ahead")
                                Spacer()
                                Text("\(preview.plannedVisualCount)")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("wordRegen.visuals")
                        }
                        ForEach(preview.followOnChapters) { chapter in
                            HStack {
                                Text(chapter.title)
                                Spacer()
                                Text("Full chapter")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .accessibilityIdentifier("wordRegen.followOn.\(chapter.id.uuidString)")
                        }
                        if preview.lockedSkippedCount > 0 {
                            Text("\(preview.lockedSkippedCount) finished chapter(s) skipped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("wordRegen.locked.skipped")
                        }
                    }

                    Section("Remaining reading time") {
                        HStack {
                            Text("Now")
                            Spacer()
                            Text(preview.baselineRemaining.displayLabel)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("After Apply")
                            Spacer()
                            Text(preview.plannedRemaining.displayLabel)
                                .foregroundStyle(.secondary)
                        }
                        Text("Time uses words ÷ WPM, with images weighted separately — asking for more images buys them with prose, not with your evening.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("wordRegen.time.section")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("wordRegen.error")
                    }
                }

                if let offlineEvidence {
                    Section {
                        Text("Authored offline fixture · mocked writer and review")
                            .font(.caption)
                            .accessibilityIdentifier("wordRegen.source.offlineProof")
                            .accessibilityValue(offlineEvidence)
                    }
                }

                if !isSourceMode || sourceState == nil {
                  Section("What should change?") {
                    ForEach(availableIntents) { intent in
                        Button {
                            if intents.contains(intent) {
                                intents.remove(intent)
                            } else {
                                intents.insert(intent)
                            }
                            onRequestChanged()
                        } label: {
                            HStack {
                                Label(intent.displayName, systemImage: intent.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if intents.contains(intent) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy || (isSourceMode && sourceState != nil))
                        .accessibilityIdentifier("wordRegen.intent.\(intent.rawValue)")
                        .accessibilityAddTraits(intents.contains(intent) ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    }

                    TextField("Anything else? (optional)", text: $freeText, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: freeText) { _, _ in onRequestChanged() }
                        .disabled(isBusy || (isSourceMode && sourceState != nil))
                        .accessibilityIdentifier("wordRegen.freeText")
                    if isSourceMode {
                        Text("Up to 1,000 characters. Start new to change a saved request; its old draft stays archived.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                  }
                }
            }
            .navigationTitle(chapterFinished && !isSourceMode ? "Change unread chapters" : "Change after word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSourceMode ? "Close" : "Cancel") { onClose() }
                        .disabled(isBusy)
                        .accessibilityIdentifier("wordRegen.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply()
                    } label: {
                        if isBusy {
                            ProgressView()
                        } else {
                            Text(applyTitle)
                        }
                    }
                    .disabled(!canApply || isBusy)
                    .accessibilityIdentifier("wordRegen.apply")
                }
            }
            .confirmationDialog("Archive this saved change?", isPresented: $confirmStartNew, titleVisibility: .visible) {
                Button("Archive and start new") { onStartNewSourceChange() }
                    .accessibilityIdentifier("wordRegen.source.confirmStartNew")
                Button("Keep saved change", role: .cancel) {}
            } message: {
                Text("The previous attempt and any written draft remain archived. No writing or review starts until you prepare and apply the new request.")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .accessibilityIdentifier("wordRegen.sheet")
    }
}
