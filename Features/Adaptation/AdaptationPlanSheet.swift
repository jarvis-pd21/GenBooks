import SwiftUI

struct AdaptationPlanSheet: View {
    let plan: AdaptationPlan
    var isApplying: Bool
    var errorMessage: String?
    var fromCanon: Bool = false
    var allowsLengthChange: Bool = true
    @Binding var lengthPreset: AdaptationLengthPreset
    var onLengthChanged: () -> Void = {}
    var onApply: () -> Void
    var onCancel: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if fromCanon {
                    Section {
                        Text("Starts from this Canon book. Apply adapts unread future only. Words you’ve already read stay exact. After Apply, the book becomes Living.")
                            .font(.subheadline)
                            .accessibilityIdentifier("adapt.plan.makeLiving.blurb")
                    }
                }

                if allowsLengthChange {
                    Section("Length") {
                        AdaptationLengthPicker(selection: $lengthPreset)
                            .disabled(isApplying)
                            .onChange(of: lengthPreset) { _, _ in onLengthChanged() }
                        Text("Half-length is the default. Full is opt-in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Why this plan") {
                    ForEach(plan.reasonsFromFeedback, id: \.self) { reason in
                        Text(reason)
                            .font(.subheadline)
                    }
                }

                Section("Preference updates") {
                    if plan.preferenceUpdatesSummary.isEmpty {
                        Text("No preference weight changes")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.preferenceUpdatesSummary, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Future chapters (proposed)") {
                    ForEach(plan.chapterTargets) { target in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(target.chapterTitle)
                                .font(.headline)
                            Text("Words: \(target.currentWordCount) → \(target.targetWordCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("adapt.plan.target.\(target.chapterId.uuidString)")
                            ForEach(target.desiredChanges, id: \.self) { change in
                                Text("• \(change)")
                                    .font(.caption)
                            }
                            if !target.mustRemainConcepts.isEmpty {
                                Text("Must remain: \(target.mustRemainConcepts.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !plan.continuityNotes.isEmpty || !(plan.factGateNotes ?? []).isEmpty {
                    Section("Continuity & facts") {
                        ForEach(plan.continuityNotes, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(plan.factGateNotes ?? [], id: \.self) { note in
                            Text(note)
                                .font(.caption)
                        }
                    }
                    .accessibilityIdentifier("adapt.plan.factGate")
                }

                if let baseline = plan.readingTimeBaselineMinutes {
                    Section("Reading time") {
                        Text(String(format: "Preserve ~%.0f min remaining (words ÷ WPM; visuals separate)", baseline))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("adapt.plan.readingTime")
                    }
                }

                if !plan.lockedChapterIds.isEmpty {
                    Section("Locked (unchanged)") {
                        Text("\(plan.lockedChapterIds.count) consumed chapter(s) will not be rewritten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("adapt.plan.locked")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("adapt.plan.error")
                    }
                }
            }
            .navigationTitle("Adaptation plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        onCancel()
                        onClose()
                    }
                    .accessibilityIdentifier("adapt.plan.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply()
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text("Apply")
                        }
                    }
                    .disabled(isApplying)
                    .accessibilityIdentifier("adapt.plan.apply")
                }
            }
        }
        .accessibilityIdentifier("adapt.plan.sheet")
    }
}
