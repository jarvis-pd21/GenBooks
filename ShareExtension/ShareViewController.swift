import UIKit
import UniformTypeIdentifiers

/// Thin Share Extension: copy EPUB/PDF to the App Group inbox and open the host.
/// No extra confirm when `extensionContext.open` succeeds (the Share-sheet tap is the action).
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "Opening in GenBooks…"
        statusLabel.textColor = UIColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 1)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setTitle("Open in GenBooks", for: .normal)
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openHostTapped), for: .touchUpInside)
        view.addSubview(statusLabel)
        view.addSubview(openButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            openButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        Task { await forwardSharedFile() }
    }

    private func forwardSharedFile() async {
        do {
            let payload = try await firstCanonFile()
            try writeInbox(data: payload.data, filename: payload.filename)
            await MainActor.run {
                openHost(showFallbackOnFailure: true)
            }
        } catch {
            await MainActor.run {
                statusLabel.text = error.localizedDescription
                finish(cancel: true, error: error)
            }
        }
    }

    private func firstCanonFile() async throws -> (data: Data, filename: String) {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if let found = try await loadCanonFile(from: provider) {
                    return found
                }
            }
        }
        throw ShareForwardError.notCanonFile
    }

    private func loadCanonFile(from provider: NSItemProvider) async throws -> (data: Data, filename: String)? {
        for typeID in Self.canonTypeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeID) {
            if let loaded = try await loadItem(provider, typeIdentifier: typeID) {
                return loaded
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           let loaded = try await loadItem(provider, typeIdentifier: UTType.data.identifier),
           Self.isCanonFilename(loaded.filename) {
            return loaded
        }
        return nil
    }

    private func loadItem(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> (data: Data, filename: String)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        continuation.resume(returning: (data, url.lastPathComponent))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let data = item as? Data {
                    let filename = Self.suggestedFilename(for: typeIdentifier)
                    continuation.resume(returning: (data, filename))
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func writeInbox(data: Data, filename: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.jarvis.livingreader"
        ) else {
            throw ShareForwardError.missingAppGroup
        }
        // Keep path/names in sync with Core `CanonShareInbox`.
        let folder = container.appendingPathComponent("IncomingCanon", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("payload"), options: .atomic)
        let meta = ["filename": filename]
        let encoded = try JSONSerialization.data(withJSONObject: meta, options: [])
        try encoded.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    @objc private func openHostTapped() {
        openHost(showFallbackOnFailure: false)
    }

    private func openHost(showFallbackOnFailure: Bool) {
        guard let url = URL(string: "genbooks://import") else { return }
        extensionContext?.open(url) { [weak self] success in
            guard let self else { return }
            if success {
                self.finish(cancel: false, error: nil)
                return
            }
            if showFallbackOnFailure {
                self.statusLabel.text = "Tap to open the book in GenBooks."
                self.openButton.isHidden = false
            } else {
                self.finish(cancel: false, error: nil)
            }
        }
    }

    private func finish(cancel: Bool, error: Error?) {
        guard !didFinish else { return }
        didFinish = true
        if cancel {
            extensionContext?.cancelRequest(withError: error ?? ShareForwardError.notCanonFile)
        } else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private static let canonTypeIdentifiers = [
        "org.idpf.epub-container",
        "org.idpf.epub-zip",
        "com.apple.ibooks.epub",
        UTType.pdf.identifier
    ]

    private static func isCanonFilename(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name.lowercased()).pathExtension
        return ext == "epub" || ext == "pdf"
    }

    private static func suggestedFilename(for typeIdentifier: String) -> String {
        if typeIdentifier == UTType.pdf.identifier { return "shared.pdf" }
        return "shared.epub"
    }
}

private enum ShareForwardError: Error, LocalizedError {
    case notCanonFile
    case missingAppGroup

    var errorDescription: String? {
        switch self {
        case .notCanonFile:
            return "GenBooks can open a DRM-free EPUB or PDF as Canon."
        case .missingAppGroup:
            return "GenBooks Share is missing its App Group. Use Files → Open in GenBooks instead."
        }
    }
}
