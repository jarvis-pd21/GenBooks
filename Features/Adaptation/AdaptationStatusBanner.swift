import SwiftUI

struct AdaptationStatusBanner: View {
    let state: AdaptationPhaseState
    let message: String?

    var body: some View {
        if let label = labelText {
            HStack(spacing: 8) {
                if state == .planning || state == .applying {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("adapt.status.banner")
        }
    }

    private var labelText: String? {
        switch state {
        case .idle, .awaitingFeedback, .planReady:
            return message
        case .planning:
            return message ?? "Planning adaptation…"
        case .applying:
            return message ?? "Applying adaptation…"
        case .applied:
            return message ?? "Future chapters updated"
        case .failed:
            return message ?? "Adaptation failed — book unchanged"
        case .cancelled:
            return message ?? "Adaptation cancelled"
        }
    }
}
