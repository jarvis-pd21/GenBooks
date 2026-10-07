import SwiftUI

/// BookBot chat on GenBooks' cream paper.
///
/// The composer opens empty — a pre-filled question is something a reader has
/// to delete before asking their own — and the openers live as one-tap bubbles
/// in the empty pane. Tapping a bubble asks immediately.
struct AskSheet: View {
    @ObservedObject var session: AskSession
    @ObservedObject var voice: AskVoiceController
    var onClose: () -> Void

    /// Semantic text colors keep explanatory copy and placeholders readable in both appearances.
    private let ink = LRColor.text
    private let inkMuted = LRColor.secondaryText
    private let inkFaint = LRColor.secondaryText

    /// Opens large so the tap-to-ask bubbles are on screen, not below the fold.
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ZStack {
                LRColor.cream.ignoresSafeArea()

                VStack(spacing: 0) {
                    if let contextLine = session.contextLine {
                        contextBanner(contextLine)
                    }

                    Text("BookBot replies are not independently source-verified.")
                        .font(.caption)
                        .foregroundStyle(inkMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("ask.sourceDisclosure")

                    if session.hasConversation {
                        transcript
                    } else {
                        emptyPane
                    }

                    if session.pendingSpoilerReveal {
                        spoilerRevealBar
                    }

                    composer
                }
            }
            .navigationTitle(BookBotChrome.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    secondaryMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: onClose)
                        .accessibilityIdentifier("ask.close")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ask.sheet")
        .onAppear {
            let session = self.session
            voice.onTranscript = { spoken in
                Task { @MainActor in
                    await session.send(question: spoken, allowUnreadSpoilers: session.allowUnreadSpoilers)
                }
            }
        }
        .onChange(of: session.messages.last?.id) { _, _ in
            voice.speakLatestReplyIfNeeded(session.messages.last)
        }
        .onDisappear { voice.shutDown() }
    }

    // MARK: - Chrome

    /// Clear and the reply-aloud toggle are secondary: Close owns the corner a
    /// reader reaches for.
    private var secondaryMenu: some View {
        Menu {
            if voice.canSpeakReplies {
                Toggle(isOn: $voice.speakRepliesAloud) {
                    Label("Speak answers", systemImage: "speaker.wave.2")
                }
                .accessibilityIdentifier("ask.speak.toggle")
            }
            Button(role: .destructive) {
                voice.stopSpeaking()
                session.resetConversation()
            } label: {
                Label("Clear conversation", systemImage: "trash")
            }
            .disabled(!session.hasConversation)
            .accessibilityIdentifier("ask.clear")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("ask.menu")
        .accessibilityLabel("More BookBot options")
    }

    private func contextBanner(_ line: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.caption)
                .foregroundStyle(LRColor.mustard)
                .accessibilityHidden(true)
            Text(line)
                .font(.caption)
                .foregroundStyle(inkMuted)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LRColor.surface.opacity(0.65))
        .overlay(alignment: .bottom) { Divider() }
        // Ignore children so `ask.context` is the banner itself. On iOS 26,
        // firstMatch otherwise hits the quote glyph (system label "Lyrics").
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ask.context")
        .accessibilityLabel(line)
    }

    // MARK: - Empty pane

    private var emptyPane: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 16)

                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(LRColor.mustard)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(BookBotChrome.emptyStateTitle)
                        .font(LRFont.cardTitle(22))
                        .foregroundStyle(ink)
                    Text(BookBotChrome.emptyStateBlurb)
                        .font(.footnote)
                        .foregroundStyle(inkMuted)
                        .multilineTextAlignment(.center)
                }

                Text(BookBotChrome.suggestionsPrompt)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(inkMuted)
                    .accessibilityIdentifier("ask.suggestions.label")

                VStack(spacing: 10) {
                    ForEach(session.suggestions) { suggestion in
                        suggestionBubble(suggestion)
                    }
                }
                .frame(maxWidth: 460)

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("ask.empty")
    }

    private func suggestionBubble(_ suggestion: AskSuggestion) -> some View {
        Button {
            Task { await session.send(suggestion: suggestion) }
        } label: {
            HStack(spacing: 10) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(LRColor.mustard)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LRColor.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(LRColor.mustard.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(session.isSending)
        .accessibilityIdentifier("ask.suggestion.\(suggestion.id)")
        // VoiceOver (and UITests) hear the prompt that will be sent; the chip still shows the short title.
        .accessibilityLabel(suggestion.prompt)
        .accessibilityHint("Asks BookBot straight away")
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if session.isSending {
                        thinkingRow
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages.count) { _, _ in
                guard let last = session.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: session.isSending) { _, sending in
                guard sending else { return }
                withAnimation { proxy.scrollTo("ask.sending", anchor: .bottom) }
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(ink)
            Text(BookBotChrome.thinkingLabel)
                .font(.caption)
                .foregroundStyle(inkMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LRColor.surface.opacity(0.8), in: Capsule())
        .id("ask.sending")
        .accessibilityIdentifier("ask.sending")
    }

    @ViewBuilder
    private func messageBubble(_ message: AskMessage) -> some View {
        switch message.role {
        case .system:
            Text(message.content)
                .font(.caption)
                .foregroundStyle(inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ask.message.system")
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(LRColor.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(LRColor.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("ask.message.user")
            }
        case .assistant:
            assistantBubble(message)
        }
    }

    private func assistantBubble(_ message: AskMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if message.isSoftFailure {
                    Image(systemName: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(inkMuted)
                        .accessibilityHidden(true)
                }
                Text(message.content)
                    .font(message.isSoftFailure ? .footnote : .system(.callout, design: .serif))
                    .foregroundStyle(message.isSoftFailure ? inkMuted : ink)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                if message.usedUnreadReveal {
                    Label("Used a deliberate unread reveal", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LRColor.mustard)
                }
                Spacer(minLength: 0)
                speakButton(for: message)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            message.isSpoilerWarning ? LRColor.warning.opacity(0.16) : LRColor.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(.trailing, 24)
        .accessibilityIdentifier(assistantIdentifier(message))
    }

    @ViewBuilder
    private func speakButton(for message: AskMessage) -> some View {
        if voice.canSpeakReplies, !message.isSoftFailure {
            Button {
                if voice.isReadingAloud(message) {
                    voice.stopSpeaking()
                } else {
                    voice.speak(message)
                }
            } label: {
                Image(systemName: voice.isReadingAloud(message) ? "stop.circle" : "speaker.wave.2")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LRColor.navy.opacity(0.65))
            .accessibilityIdentifier("ask.message.speak")
            .accessibilityLabel(voice.isReadingAloud(message) ? "Stop reading aloud" : "Read this reply aloud")
        }
    }

    private func assistantIdentifier(_ message: AskMessage) -> String {
        if message.isSpoilerWarning { return "ask.message.spoiler" }
        if message.isSoftFailure { return "ask.message.error" }
        return "ask.message.assistant"
    }

    private var spoilerRevealBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Optional deliberate reveal", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink)
            Text("This includes later, unread book material in the next answer.")
                .font(.caption2)
                .foregroundStyle(inkMuted)
            Button("Reveal unread material & answer") {
                Task { await session.revealSpoilersAndResend() }
            }
            .buttonStyle(.borderedProminent)
            .tint(LRColor.mustard)
            .accessibilityIdentifier("ask.spoiler.reveal")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LRColor.mustard.opacity(0.14))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let failure = voice.failureMessage {
                voiceFailureRow(failure)
            } else if !voice.statusText.isEmpty {
                voiceStatusRow
            }

            if session.lastError != nil, !session.isSending {
                retryRow
            }

            HStack(alignment: .bottom, spacing: 10) {
                micButton
                inputField
                sendButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The placeholder is drawn rather than handed to `TextField` so it keeps
    /// its contrast on the white field in every theme — and so the field's
    /// accessibility value stays empty while nothing has been typed.
    private var inputField: some View {
        ZStack(alignment: .leading) {
            if session.draft.isEmpty {
                Text(BookBotChrome.composerPlaceholder)
                    .font(.callout)
                    .foregroundStyle(inkFaint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField("", text: $session.draft, axis: .vertical)
                .font(.callout)
                .foregroundStyle(ink)
                .tint(ink)
                .lineLimit(1...4)
                .disabled(session.isSending)
                .submitLabel(.send)
                .onSubmit { Task { await session.sendDraft() } }
                .accessibilityIdentifier("ask.input")
                .accessibilityLabel(BookBotChrome.composerPlaceholder)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(LRColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LRColor.navy.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isSending {
            Button {
                session.cancelInFlight()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .accessibilityIdentifier("ask.stop")
            .accessibilityLabel("Stop")
        } else {
            Button {
                Task { await session.sendDraft() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(session.canSendDraft ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .disabled(!session.canSendDraft)
            .accessibilityIdentifier("ask.send")
            .accessibilityLabel("Send")
        }
    }

    /// One control, two gestures: a tap latches the mic open (tap again to
    /// send), a hold keeps it open only while held. `VoiceModeMachine` decides
    /// which happened, so both routes end in the same place.
    private var micButton: some View {
        Button {
            voice.tapped()
        } label: {
            Image(systemName: voice.isCapturing ? "waveform" : "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(voice.isCapturing ? LRColor.onAccent : LRColor.text)
                .frame(width: 40, height: 40)
                .background(
                    voice.isCapturing ? LRColor.mustard : LRColor.surface,
                    in: Circle()
                )
                .overlay(Circle().strokeBorder(LRColor.navy.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: VoiceModeMachine.holdThreshold) {
            // Release is what commits; recognition alone only means "still held".
        } onPressingChanged: { isPressing in
            voice.pressChanged(isPressing)
        }
        .accessibilityIdentifier("ask.voice.button")
        .accessibilityLabel(voice.micAccessibilityLabel)
        .accessibilityHint("Tap to start and stop, or hold while you speak")
    }

    private var voiceStatusRow: some View {
        HStack(spacing: 8) {
            Text(voice.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if !voice.partialTranscript.isEmpty {
                Text(BookBotChrome.truncatedAtWordBoundary(voice.partialTranscript, limit: 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("ask.voice.transcript")
            }
            Spacer(minLength: 0)
            if voice.isCapturing || voice.isSpeaking {
                Button("Stop") { voice.cancel() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("ask.voice.stop")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Contain (don't combine) so Stop stays its own control; the container
        // keeps `ask.voice.status` and a real frame on iOS 26.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.voice.status")
        .accessibilityLabel(voice.statusText)
    }

    private func voiceFailureRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button("OK") { voice.dismissFailure() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("ask.voice.dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.voice.error")
    }

    private var retryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(LRColor.mustard)
            Text(BookBotChrome.softFailBanner)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Try again") {
                Task { await session.retryLastQuestion() }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(session.lastUserQuestion == nil)
            .accessibilityIdentifier("ask.retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ask.error")
    }
}
