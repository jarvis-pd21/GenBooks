import Foundation

/// Incoming URLs for Canon Open In / Share.
///
/// - `file://` — Files / “Open in GenBooks” / Inbox (document types)
/// - `genbooks://import` — Share Extension finished writing the App Group inbox
enum IncomingCanonURL: Equatable, Sendable {
    case file(URL)
    case shareInbox
    case unsupported

    static let scheme = "genbooks"
    static let importHost = "import"

    static func parse(_ url: URL) -> IncomingCanonURL {
        if url.isFileURL {
            return .file(url)
        }
        guard url.scheme?.lowercased() == scheme else {
            return .unsupported
        }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if host == importHost || path == "/import" || path.hasSuffix("/import") {
            return .shareInbox
        }
        return .unsupported
    }
}
