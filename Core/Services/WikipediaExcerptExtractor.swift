import Foundation
import SwiftSoup

/// A non-rendering, paragraph-only projection of an already downloaded string.
/// No URL parser overload, browser, asset fetch, script execution or wikitext expansion.
enum WikipediaExcerptExtractor {
    static let maximumCharacters = 8_000
    static let minimumWords = 160
    static let maximumHTMLBytes = 2 * 1024 * 1024

    /// https://www.mediawiki.org/wiki/API:Parsing_wikitext/TOCData
    /// Optional API fields are decoded as optional; anchors are used, never invented.
    struct Section: Codable, Equatable, Sendable {
        let anchor: String?
        let line: String?
        let hLevel: Int?
        let fromTitle: String?
    }

    struct Excerpt: Equatable, Sendable {
        let text: String
        let metadata: RetrievedResearchSource.ExtractionMetadata
    }

    static func extract(html: String, sections: [Section], articleTitle: String) throws -> Excerpt {
        guard html.utf8.count <= maximumHTMLBytes else { throw WikipediaSourceError.oversizedResponse }
        guard sections.count <= 2_000 else { throw WikipediaSourceError.invalidExcerptStructure }
        do {
            // Force HTML parsing, even if untrusted input starts with an XML declaration.
            let document = try SwiftSoup.parseHTML(html)
            let roots = try document.select("div.mw-parser-output")
            guard roots.size() == 1, let root = roots.first(), let body = document.body(),
                  root.parent() === body else { throw WikipediaSourceError.invalidExcerptStructure }
            for node in body.getChildNodes() where node !== root {
                guard node is Comment || (node as? TextNode)?.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
                    throw WikipediaSourceError.invalidExcerptStructure
                }
            }
            var anchors = Set<String>()
            var paragraphs: [String] = []
            var locators: [RetrievedResearchSource.ParagraphLocator] = []
            var activeAnchor: String?
            var activeTitle = "Introduction"
            var paragraphIndex = 0
            var headingIndex = 0
            var stopped = false
            var length = 0
            var nodes = 0
            // Iterative traversal avoids recursive stack growth on untrusted markup.
            var stack: [(Node, Int)] = root.getChildNodes().reversed().map { ($0, 1) }
            while let (node, depth) = stack.popLast() {
                nodes += 1
                guard nodes <= 100_000, depth <= 128 else { throw WikipediaSourceError.invalidExcerptStructure }
                if Task.isCancelled { throw WikipediaSourceError.cancelled }
                if node is Comment { continue }
                if let text = node as? TextNode {
                    guard text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw WikipediaSourceError.invalidExcerptStructure
                    }
                    continue
                }
                guard let element = node as? Element else { throw WikipediaSourceError.invalidExcerptStructure }
                if try excluded(element) { continue }
                let tag = element.tagNameNormal()
                if let level = headingLevel(tag) {
                    // Validate metadata only when its heading is reached. A later
                    // section is not evidence for this bounded opening excerpt.
                    guard headingIndex < sections.count else { throw WikipediaSourceError.invalidExcerptStructure }
                    let section = sections[headingIndex]
                    guard let anchor = section.anchor, !anchor.isEmpty, anchor.count <= 1_000,
                          anchor.rangeOfCharacter(from: .controlCharacters) == nil, anchors.insert(anchor).inserted,
                          let line = section.line, line.utf8.count <= 8_000,
                          section.hLevel == level,
                          section.fromTitle == nil || section.fromTitle?.replacingOccurrences(of: "_", with: " ") == articleTitle else {
                        throw WikipediaSourceError.invalidExcerptStructure
                    }
                    let heading = try SwiftSoup.parseHTML("<body>\(line)</body>")
                    guard let headingBody = heading.body() else { throw WikipediaSourceError.invalidExcerptStructure }
                    let title = try inlineText(headingBody)
                    guard !title.isEmpty, title.count <= 1_000 else { throw WikipediaSourceError.invalidExcerptStructure }
                    let ids = try element.select("[id]").array().map { try $0.attr("id") }
                    guard ids.filter({ $0 == anchor }).count == 1,
                          try inlineText(element) == title else { throw WikipediaSourceError.invalidExcerptStructure }
                    headingIndex += 1
                    activeAnchor = anchor; activeTitle = title; paragraphIndex = 0
                    if ["references", "notes", "footnotes", "bibliography", "external links", "further reading", "see also"].contains(title.lowercased()) {
                        stopped = true
                        break
                    }
                } else if tag == "p" {
                    let text = try inlineText(element)
                    if text.isEmpty { continue }
                    paragraphIndex += 1
                    let nextLength = length + (paragraphs.isEmpty ? 0 : 2) + text.count
                    if nextLength > maximumCharacters { stopped = true; break }
                    paragraphs.append(text)
                    locators.append(.init(sectionAnchor: activeAnchor, sectionTitle: activeTitle, paragraphIndex: paragraphIndex))
                    length = nextLength
                    if length == maximumCharacters { stopped = true; break }
                } else if tag == "div" || tag == "section" {
                    stack.append(contentsOf: element.getChildNodes().reversed().map { ($0, depth + 1) })
                } else {
                    throw WikipediaSourceError.invalidExcerptStructure
                }
            }
            // At natural EOF all headings must match. At an explicit boundary,
            // unconsumed headings and prose must not veto the saved prefix.
            guard stopped || headingIndex == sections.count else { throw WikipediaSourceError.invalidExcerptStructure }
            let text = paragraphs.joined(separator: "\n\n")
            guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { throw WikipediaSourceError.insufficientExcerpt }
            let metadata = RetrievedResearchSource.ExtractionMetadata(
                extractionVersion: RetrievedResearchSource.ExtractionMetadata.currentVersion, paragraphLocators: locators)
            guard metadata.isValid(for: text) else { throw WikipediaSourceError.invalidExcerptStructure }
            return Excerpt(text: text, metadata: metadata)
        } catch let error as WikipediaSourceError { throw error }
        catch { throw WikipediaSourceError.invalidExcerptStructure }
    }

    private static func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.first == "h", let level = Int(tag.dropFirst()), (2...6).contains(level) else { return nil }
        return level
    }

    private static func excluded(_ element: Element) throws -> Bool {
        let tags: Set<String> = ["script", "style", "link", "meta", "table", "figure", "figcaption", "nav", "aside", "footer", "header", "form", "iframe", "object", "embed", "svg", "img", "picture", "video", "audio", "noscript", "template", "ul", "ol", "dl"]
        if tags.contains(element.tagNameNormal()) { return true }
        let classes = Set(try element.classNames())
        if !classes.isDisjoint(with: ["hatnote", "navbox", "vertical-navbox", "infobox", "sidebar", "metadata", "ambox", "ombox", "tmbox", "fmbox", "cmbox", "imbox", "sistersitebox", "thumb", "tright", "tleft", "mw-editsection", "reference", "references", "reflist", "toc", "shortdescription", "noprint", "mw-empty-elt"]) { return true }
        return try element.hasAttr("hidden") || element.attr("aria-hidden") == "true"
    }

    private static func inlineText(_ root: Element) throws -> String {
        var result = ""
        var nodes = 0
        var stack: [(Node, Int)] = root.getChildNodes().reversed().map { ($0, 1) }
        let allowed: Set<String> = ["a", "span", "b", "strong", "i", "em", "small", "sup", "sub", "abbr", "bdi", "bdo", "q", "cite", "code", "mark", "s", "time", "samp", "var", "u"]
        while let (node, depth) = stack.popLast() {
            nodes += 1
            guard nodes <= 100_000, depth <= 128 else { throw WikipediaSourceError.invalidExcerptStructure }
            if let text = node as? TextNode { result += text.getWholeText(); continue }
            if node is Comment { continue }
            guard let element = node as? Element else { throw WikipediaSourceError.invalidExcerptStructure }
            let classes = Set(try element.classNames())
            if !classes.isDisjoint(with: ["reference", "mw-editsection"]) { continue }
            // Inline assets/math can carry meaning. Reject rather than silently deleting it.
            if element.tagNameNormal() == "br" { result += " "; continue }
            guard allowed.contains(element.tagNameNormal()), !element.hasAttr("hidden"),
                  try element.attr("aria-hidden") != "true" else { throw WikipediaSourceError.invalidExcerptStructure }
            stack.append(contentsOf: element.getChildNodes().reversed().map { ($0, depth + 1) })
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
