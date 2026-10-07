import Foundation

/// EPUB is ingest only. Callers pass the extracted string to `ManuscriptImporter`.
/// Text is taken verbatim from the spine XHTML — no AI rewrite (Canon).
enum EPUBTextExtractor {
    struct Extract: Equatable, Sendable {
        var title: String?
        var author: String?
        var plainText: String
    }

    static func extract(from url: URL) throws -> Extract {
        let data = try Data(contentsOf: url)
        return try extract(from: data)
    }

    static func extract(from data: Data) throws -> Extract {
        let files = try MinimalZipArchive.fileMap(from: data)
        guard !files.isEmpty else { throw CreateBookError.emptySource }
        try assertNoDRM(in: files)

        let containerXML = try stringFile(files, names: [
            "META-INF/container.xml",
            "meta-inf/container.xml"
        ])
        let opfPath = try rootfilePath(in: containerXML)
        let opfXML = try stringFile(files, names: [opfPath])
        let opfDirectory = directory(of: opfPath)

        let title = firstXMLValue(tag: "dc:title", in: opfXML)
        let author = firstXMLValue(tag: "dc:creator", in: opfXML)
        let chapters = spineChapterHrefs(in: opfXML)

        var blocks: [String] = []
        for href in chapters {
            let resolved = join(opfDirectory, href)
            guard let htmlData = Self.data(in: files, named: resolved) else { continue }
            let html = String(decoding: htmlData, as: UTF8.self)
            let markdown = xhtmlToMarkdown(html)
            if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(markdown)
            }
        }
        let joined = blocks.joined(separator: "\n\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreateBookError.emptySource }
        return Extract(title: emptyToNil(title), author: emptyToNil(author), plainText: trimmed)
    }

    /// Fail closed: encryption.xml / Adobe rights / FairPlay sinf means we will not unpack text.
    static func assertNoDRM(in files: [String: Data]) throws {
        for rawName in files.keys {
            let name = rawName.lowercased().replacingOccurrences(of: "\\", with: "/")
            if name.hasSuffix("meta-inf/encryption.xml")
                || name.hasSuffix("meta-inf/rights.xml")
                || name.hasSuffix("meta-inf/sinf.xml")
                || name.hasSuffix("/encryption.xml") {
                throw CreateBookError.drmProtected
            }
        }
    }

    // MARK: - OPF

    private static func rootfilePath(in containerXML: String) throws -> String {
        let pattern = #"full-path\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: containerXML, range: NSRange(location: 0, length: (containerXML as NSString).length)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: containerXML)
        else {
            throw CreateBookError.epubUnreadable("Missing EPUB container rootfile.")
        }
        return String(containerXML[range])
    }

    private static func spineChapterHrefs(in opf: String) -> [String] {
        let ids = attributeValues("idref", in: opf, elementHint: "itemref")
        let items = manifestItems(in: opf)
        if !ids.isEmpty {
            return ids.compactMap { id in
                guard let item = items.first(where: { $0.id == id }) else { return nil }
                if shouldSkipManifest(item) { return nil }
                return item.href
            }
        }
        return items.compactMap { item in
            shouldSkipManifest(item) ? nil : item.href
        }
    }

    private struct ManifestItem {
        var id: String
        var href: String
        var mediaType: String
    }

    private static func manifestItems(in opf: String) -> [ManifestItem] {
        guard let regex = try? NSRegularExpression(pattern: #"<item\b[^>]*>"#, options: .caseInsensitive) else {
            return []
        }
        let ns = opf as NSString
        return regex.matches(in: opf, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let tag = ns.substring(with: match.range)
            guard let id = attribute("id", in: tag), let href = attribute("href", in: tag) else { return nil }
            let media = attribute("media-type", in: tag) ?? attribute("mediaType", in: tag) ?? ""
            return ManifestItem(id: id, href: href, mediaType: media)
        }
    }

    private static func shouldSkipManifest(_ item: ManifestItem) -> Bool {
        let media = item.mediaType.lowercased()
        if !media.isEmpty,
           !media.contains("html"),
           !media.contains("xml") {
            return true
        }
        let hay = (item.id + " " + item.href).lowercased()
        if hay.contains("ncx") || hay.contains("nav") && hay.contains("toc") {
            return true
        }
        if hay.contains("cover") && (media.contains("image") || hay.hasSuffix(".jpg") || hay.hasSuffix(".png")) {
            return true
        }
        return false
    }

    // MARK: - XHTML → markdown-ish text (verbatim words)

    static func xhtmlToMarkdown(_ html: String) -> String {
        var text = html
        if let body = slice(text, after: "<body", until: "</body>") {
            if let innerStart = body.firstIndex(of: ">") {
                text = String(body[body.index(after: innerStart)...])
            } else {
                text = body
            }
        }
        text = stripTagBlocks(text, tag: "script")
        text = stripTagBlocks(text, tag: "style")
        text = replaceBlockTags(text, tags: ["h1"], prefix: "# ")
        text = replaceBlockTags(text, tags: ["h2"], prefix: "## ")
        text = replaceBlockTags(text, tags: ["h3"], prefix: "### ")
        text = text.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(
            of: "</(p|div|li|blockquote|section|h[1-6])>",
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !blank, !collapsed.isEmpty {
                    collapsed.append("")
                    blank = true
                }
            } else {
                collapsed.append(line)
                blank = false
            }
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func stringFile(_ files: [String: Data], names: [String]) throws -> String {
        for name in names {
            if let data = data(in: files, named: name) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        throw CreateBookError.epubUnreadable("EPUB is missing \(names[0]).")
    }

    private static func data(in files: [String: Data], named name: String) -> Data? {
        if let exact = files[name] { return exact }
        let lowered = name.lowercased()
        for (key, value) in files where key.lowercased() == lowered {
            return value
        }
        let trimmed = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let exact = files[trimmed] { return exact }
        return files.first(where: { $0.key.lowercased().hasSuffix(lowered) })?.value
    }

    private static func directory(of path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[..<slash])
        }
        return ""
    }

    private static func join(_ directory: String, _ href: String) -> String {
        let clean = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? href
        if clean.hasPrefix("/") { return String(clean.dropFirst()) }
        if directory.isEmpty { return clean }
        if clean.hasPrefix("../") {
            let parent = directory.split(separator: "/").dropLast().joined(separator: "/")
            return join(parent, String(clean.dropFirst(3)))
        }
        return directory + "/" + clean
    }

    private static func firstXMLValue(tag: String, in xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)\\b[^>]*>([\\s\\S]*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: xml)
        else { return nil }
        return decodeEntities(String(xml[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attributeValues(_ name: String, in xml: String, elementHint: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(elementHint)\\b[^>]*>",
            options: .caseInsensitive
        ) else { return [] }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            attribute(name, in: ns.substring(with: match.range))
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\#(name)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    private static func slice(_ text: String, after start: String, until end: String) -> String? {
        guard let startRange = text.range(of: start, options: .caseInsensitive),
              let endRange = text.range(of: end, options: .caseInsensitive, range: startRange.upperBound..<text.endIndex)
        else { return nil }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func stripTagBlocks(_ html: String, tag: String) -> String {
        let pattern = "<\(tag)\\b[\\s\\S]*?</\(tag)>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func replaceBlockTags(_ html: String, tags: [String], prefix: String) -> String {
        var result = html
        for tag in tags {
            let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let inner = decodeEntities(ns.substring(with: match.range(at: 1)))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = "\n\(prefix)\(inner)\n"
                result.replaceSubrange(Range(match.range, in: result)!, with: replacement)
            }
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                if let range = Range(match.range(at: 1), in: result),
                   let value = Int(result[range]),
                   let scalar = UnicodeScalar(value) {
                    result.replaceSubrange(Range(match.range, in: result)!, with: String(Character(scalar)))
                }
            }
        }
        return result
    }

    private static func emptyToNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
