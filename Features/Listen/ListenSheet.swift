import SwiftUI

/// Listen: Spotify-like chapter player consolidated into one sheet.
///
/// Book text sits above the transport; chrome stays one surface — voice, speed,
/// download, chapter list. Nothing here earns a permanent button on the reading
/// surface beyond the existing More → Listen entry.
struct ListenSheet: View {
    @ObservedObject var model: ListenViewModel
    let onClose: () -> Void
    @State private var downloadToRemove: ListenDocument?

    private static let aiDisclosure = """
    Narration is AI-generated (OpenAI gpt-4o-mini-tts) from this chapter’s current text, \
    and read word for word. Audio is saved per chapter revision, so a regenerated chapter \
    is narrated again. Listening never changes your reading place. Word highlight is \
    estimated from playback progress until true timestamps ship.
    """

    private static let highlightColor = Color.orange.opacity(0.35)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            chapterBody
                            chapterList
                            voicePicker
                            downloadSection
                            if let error = model.errorMessage {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("listen.error")
                            }
                            disclosure
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.visible)
                }

                Divider()
                playerBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.bar)
            }
            .navigationTitle("Listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                        .accessibilityIdentifier("listen.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("listen.sheet")
        .alert("Remove downloaded narration?", isPresented: Binding(
            get: { downloadToRemove != nil },
            set: { if !$0 { downloadToRemove = nil } }
        ), presenting: downloadToRemove) { target in
            Button("Remove download", role: .destructive) {
                model.removeDownload(matching: target.cacheKey)
                downloadToRemove = nil
            }
            Button("Keep download", role: .cancel) { downloadToRemove = nil }
        } message: { target in
            Text("Removes \(target.voice.rawValue.capitalized)’s audio for “\(target.chapterTitle)” from this iPhone. Book text and notes stay. Making this audio again may incur API charges.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.chapterTitle)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("listen.chapterTitle")
            Text(model.partLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("listen.partLabel")
            if let resume = model.resumeHint {
                Text(resume)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("listen.resumeHint")
            }
            if !model.availabilityLabel.isEmpty {
                Text(model.availabilityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("listen.availability")
            }
            if model.canSynthesize && !model.isFullyDownloaded {
                Text("Play or Download makes AI narration and may incur API charges. While playing, the next chapter may also be prepared. Opening this sheet alone makes no narration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("listen.costNotice")
            }
            if model.phase == .finishedChapter {
                Text("End of chapter.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("listen.finished")
            }
        }
    }

    /// Chapter prose with the speaking word highlighted (selection-like tint).
    private var chapterBody: some View {
        Group {
            if model.currentChunkText.isEmpty {
                Text("Open a chapter with prose to listen.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                highlightedChunkText
                    .font(.body)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("listen.chapterBody")
            }
        }
    }

    private var highlightedChunkText: some View {
        let text = model.currentChunkText
        let highlight = model.highlightedWord
        return Text(attributedChunk(text: text, highlight: highlight))
    }

    private func attributedChunk(text: String, highlight: ListenWordTiming.WordSpan?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let highlight else { return attributed }
        let nsRange = NSRange(location: highlight.utf16Start, length: highlight.utf16Length)
        guard let range = Range(nsRange, in: attributed) else { return attributed }
        attributed[range].backgroundColor = Self.highlightColor
        attributed[range].font = .body.weight(.semibold)
        return attributed
    }

    private var chapterList: some View {
        let chapters = model.chapterList
        return Group {
            if chapters.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chapters")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(chapters, id: \.id) { item in
                        Button {
                            model.jumpToChapter(item.id)
                        } label: {
                            HStack {
                                Text(item.title)
                                    .font(.subheadline.weight(item.isCurrent ? .semibold : .regular))
                                    .foregroundStyle(item.isCurrent ? Color.primary : Color.secondary)
                                    .lineLimit(2)
                                Spacer()
                                if item.isCurrent {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(item.isCurrent ? "listen.chapter.current" : "listen.chapter.row")
                    }
                }
            }
        }
    }

    private var playerBar: some View {
        VStack(spacing: 12) {
            scrubber
            transport
            speedRow
        }
        .accessibilityIdentifier("listen.playerBar")
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { model.chapterElapsed },
                    set: { model.seekChapter(to: $0) }
                ),
                in: 0...max(model.chapterDuration, 0.1)
            )
            .accessibilityIdentifier("listen.scrubber")
            HStack {
                Text(model.elapsedLabel)
                    .accessibilityIdentifier("listen.elapsed")
                Spacer()
                Text(model.remainingLabel)
                    .accessibilityIdentifier("listen.remaining")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button {
                model.skipChapter(by: -1)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!model.hasPreviousChapter)
            .accessibilityIdentifier("listen.previousChapter")
            .accessibilityLabel("Previous chapter")

            Button {
                model.skipSeconds(-ListenViewModel.rewindSeconds)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "gobackward.15")
                    Text("15")
                        .font(.caption2.weight(.semibold))
                }
            }
            .disabled(model.partCount == 0)
            .accessibilityIdentifier("listen.skipBack")
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            .buttonStyle(.plain)
            .disabled(model.partCount == 0)
            .accessibilityIdentifier("listen.playPause")
            .accessibilityLabel(model.isPlaying ? "Pause narration" : "Play narration")

            Button {
                model.skipSeconds(ListenViewModel.forwardSeconds)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "goforward.30")
                    Text("30")
                        .font(.caption2.weight(.semibold))
                }
            }
            .disabled(model.partCount == 0)
            .accessibilityIdentifier("listen.skipForward")
            .accessibilityLabel("Skip forward 30 seconds")

            Button {
                model.skipChapter(by: 1)
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!model.hasNextChapter)
            .accessibilityIdentifier("listen.nextChapter")
            .accessibilityLabel("Next chapter")
        }
        .font(.title3)
        .frame(maxWidth: .infinity)
    }

    private var speedRow: some View {
        HStack {
            Text("Speed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Speed", selection: speedBinding) {
                ForEach(ListenSpeed.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("listen.speed.picker")
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voice")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Voice", selection: voiceBinding) {
                ForEach(ListenVoice.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("listen.voice.picker")

            Text(model.voice.blurb)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isGenerating {
                ProgressView(value: model.downloadProgress)
                    .accessibilityIdentifier("listen.download.progress")
                Button("Stop making narration") { model.cancelDownload() }
                    .accessibilityIdentifier("listen.download.cancel")
            } else if model.isFullyDownloaded {
                Button(role: .destructive) {
                    downloadToRemove = model.document
                } label: {
                    Label("Remove download", systemImage: "trash")
                }
                .accessibilityIdentifier("listen.download.remove")
            } else if model.canSynthesize {
                Button {
                    model.downloadChapter()
                } label: {
                    Label("Download narration", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.partCount == 0)
                .accessibilityIdentifier("listen.download")
            } else {
                Text("Narration needs an API key. Add one in Settings → BookBot. Chapters you’ve already downloaded still play offline.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("listen.needsKey")
            }
        }
    }

    private var disclosure: some View {
        Text(Self.aiDisclosure)
            .font(.caption2)
                            .foregroundStyle(.primary)
            .accessibilityIdentifier("listen.disclosure")
    }

    private var voiceBinding: Binding<ListenVoice> {
        Binding(
            get: { model.voice },
            set: { model.select(voice: $0) }
        )
    }

    private var speedBinding: Binding<ListenSpeed> {
        Binding(
            get: { model.speed },
            set: { model.select(speed: $0) }
        )
    }
}
