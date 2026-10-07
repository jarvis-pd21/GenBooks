import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Retrieved evidence, never instructions or a fact-verification decision.
/// Exact retained evidence text; neither scope represents the full article.
struct RetrievedResearchSource: Codable, Equatable, Hashable, Sendable {
    enum Scope: String, Codable, Hashable, Sendable { case wikipediaIntroduction, wikipediaOpeningExcerpt }

    struct ParagraphLocator: Codable, Equatable, Hashable, Sendable {
        let sectionAnchor: String?
        let sectionTitle: String
        /// One-based index among eligible prose paragraphs in this section.
        let paragraphIndex: Int
    }

    struct ExtractionMetadata: Codable, Equatable, Hashable, Sendable {
        static let currentVersion = "wikipedia-opening-paragraphs-v1"
        let extractionVersion: String
        let paragraphLocators: [ParagraphLocator]
        var scopeDescription: String { "Opening article excerpt—not the full article." }
        var renderingCaveat: String {
            "Rendered from the recorded article revision; templates and other transcluded content may reflect later changes."
        }

        func isValid(for text: String) -> Bool {
            let paragraphs = text.components(separatedBy: "\n\n")
            guard extractionVersion == Self.currentVersion, !paragraphLocators.isEmpty,
                  paragraphs.count == paragraphLocators.count,
                  paragraphs.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && $0 == $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }) else { return false }
            var counts: [String: Int] = [:]
            var titles: [String: String] = [:]
            var lastKey: String?
            for locator in paragraphLocators {
                guard !locator.sectionTitle.isEmpty, locator.sectionTitle.count <= 1_000,
                      locator.sectionTitle.rangeOfCharacter(from: .controlCharacters) == nil,
                      locator.sectionAnchor.map({ !$0.isEmpty && $0.count <= 1_000 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) ?? true else { return false }
                let key = locator.sectionAnchor ?? ""
                guard locator.sectionAnchor != nil || locator.sectionTitle == "Introduction",
                      counts[key] == nil || lastKey == key,
                      titles[key] == nil || titles[key] == locator.sectionTitle else { return false }
                let expected = (counts[key] ?? 0) + 1
                guard locator.paragraphIndex == expected else { return false }
                counts[key] = expected; titles[key] = locator.sectionTitle; lastKey = key
            }
            return true
        }
    }

    let requestedTitle: String
    let title: String
    let canonicalURL: URL
    let pageID: Int64
    /// Article revision associated with the retained excerpt; not a template-history snapshot.
    let revisionID: Int64
    let revisionURL: URL
    let revisionTimestamp: Date
    let retrievedAt: Date
    let scope: Scope
    let text: String
    /// SHA-256 of the exact retained plaintext's UTF-8 bytes.
    let textSHA256: String
    let attribution: String
    let attributionURL: URL
    /// Wiki-wide rights metadata reported by siteinfo, not a legal determination.
    let licenseName: String
    let licenseURL: URL
    let extractionMetadata: ExtractionMetadata?

    init(requestedTitle: String, title: String, canonicalURL: URL, pageID: Int64, revisionID: Int64,
         revisionURL: URL, revisionTimestamp: Date, retrievedAt: Date, scope: Scope, text: String,
         textSHA256: String, attribution: String, attributionURL: URL, licenseName: String, licenseURL: URL,
         extractionMetadata: ExtractionMetadata? = nil) {
        self.requestedTitle = requestedTitle; self.title = title; self.canonicalURL = canonicalURL
        self.pageID = pageID; self.revisionID = revisionID; self.revisionURL = revisionURL
        self.revisionTimestamp = revisionTimestamp; self.retrievedAt = retrievedAt; self.scope = scope
        self.text = text; self.textSHA256 = textSHA256; self.attribution = attribution
        self.attributionURL = attributionURL; self.licenseName = licenseName; self.licenseURL = licenseURL
        self.extractionMetadata = extractionMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case requestedTitle, title, canonicalURL, pageID, revisionID, revisionURL, revisionTimestamp,
             retrievedAt, scope, text, textSHA256, attribution, attributionURL, licenseName, licenseURL,
             extractionMetadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedTitle = try c.decode(String.self, forKey: .requestedTitle)
        title = try c.decode(String.self, forKey: .title)
        canonicalURL = try c.decode(URL.self, forKey: .canonicalURL)
        pageID = try c.decode(Int64.self, forKey: .pageID)
        revisionID = try c.decode(Int64.self, forKey: .revisionID)
        revisionURL = try c.decode(URL.self, forKey: .revisionURL)
        revisionTimestamp = try c.decode(Date.self, forKey: .revisionTimestamp)
        retrievedAt = try c.decode(Date.self, forKey: .retrievedAt)
        scope = try c.decode(Scope.self, forKey: .scope)
        text = try c.decode(String.self, forKey: .text)
        textSHA256 = try c.decode(String.self, forKey: .textSHA256)
        attribution = try c.decode(String.self, forKey: .attribution)
        attributionURL = try c.decode(URL.self, forKey: .attributionURL)
        licenseName = try c.decode(String.self, forKey: .licenseName)
        licenseURL = try c.decode(URL.self, forKey: .licenseURL)
        extractionMetadata = try c.decodeIfPresent(ExtractionMetadata.self, forKey: .extractionMetadata)
        if scope == .wikipediaOpeningExcerpt, extractionMetadata?.isValid(for: text) != true {
            throw DecodingError.dataCorruptedError(forKey: .extractionMetadata, in: c,
                debugDescription: "Opening excerpt locators do not match the retained paragraphs.")
        }
    }

    var id: String {
        let legacy = "wikipedia:en:\(pageID):\(revisionID):\(textSHA256)"
        guard scope == .wikipediaOpeningExcerpt else { return legacy }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(extractionMetadata)) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(legacy):\(scope.rawValue):\(digest)"
    }
}

enum WikipediaSourceError: Error, Equatable, LocalizedError {
    case invalidTitle, missingArticle, disambiguation, invalidJSON, invalidIdentity
    case missingLicenseMetadata, emptyExtract, oversizedResponse, oversizedExtract
    case unexpectedRedirect, revisionChanged, timedOut, cancelled
    case invalidExcerptStructure, insufficientExcerpt
    case httpStatus(Int), apiError(String), network(Int)

    var errorDescription: String? {
        switch self {
        case .invalidTitle: return "Enter one Wikipedia article title, not a URL or a list."
        case .missingArticle: return "That Wikipedia article was not found."
        case .disambiguation: return "That title is a disambiguation page. Choose a specific article."
        case .invalidJSON: return "Wikipedia returned an invalid JSON response."
        case .invalidIdentity: return "Wikipedia returned an unexpected article identity."
        case .missingLicenseMetadata: return "Wikipedia did not provide usable license metadata."
        case .emptyExtract: return "Wikipedia did not provide an article introduction."
        case .oversizedResponse: return "The Wikipedia response exceeded its allowed size (256 KiB metadata/introduction or 2 MiB article markup)."
        case .oversizedExtract: return "The Wikipedia introduction exceeded the 20,000-character limit."
        case .unexpectedRedirect: return "Wikipedia returned an unexpected redirect; no redirect was followed."
        case .revisionChanged: return "The article and retrieved source revision did not match. No source was saved."
        case .timedOut: return "The Wikipedia request timed out."
        case .cancelled: return "Wikipedia retrieval was cancelled."
        case .invalidExcerptStructure: return "Wikipedia returned article structure that could not be extracted with reliable paragraph locations."
        case .insufficientExcerpt: return "The opening article excerpt has fewer than 160 usable words. No source was saved."
        case .httpStatus(let code): return "Wikipedia returned HTTP \(code)."
        case .apiError(let code): return "Wikipedia reported an API error (\(code))."
        case .network(let code): return "Wikipedia could not be reached (network error \(code))."
        }
    }
}

/// Two serial, unauthenticated GETs on en.wikipedia.org only. No silent retries.
/// 1. Action API resolves title/redirects and reports identity + wiki license.
/// 2. Summary API supplies plaintext tied to its own revision; drift is rejected.
/// Official contracts: https://www.mediawiki.org/wiki/API:Info,
/// https://www.mediawiki.org/wiki/API:Siteinfo,
/// https://www.mediawiki.org/wiki/Extension:Disambiguator#With_API,
/// https://en.wikipedia.org/api/rest_v1/?spec (page/summary/{title}).
protocol ResearchSourceRetrieving: Sendable {
    func retrieve(articleTitle: String) async throws -> RetrievedResearchSource
}

protocol ResearchExcerptSourceRetrieving: Sendable {
    func retrieveOpeningExcerpt(articleTitle: String) async throws -> RetrievedResearchSource
}

final class WikipediaSourceClient: ResearchSourceRetrieving, ResearchExcerptSourceRetrieving, @unchecked Sendable {
    static let maximumResponseBytes = 256 * 1024
    static let maximumParseResponseBytes = 2 * 1024 * 1024
    static let maximumExtractCharacters = 20_000
    static let requestTimeout: TimeInterval = 15
    private let configuration: URLSessionConfiguration
    private let now: @Sendable () -> Date

    init(configuration: URLSessionConfiguration = .ephemeral,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.now = now
    }

    func retrieve(articleTitle: String) async throws -> RetrievedResearchSource {
        let title = articleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 255, !title.contains("://"),
              title.rangeOfCharacter(from: .controlCharacters) == nil,
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "|#")) == nil else {
            throw WikipediaSourceError.invalidTitle
        }
        let infoURL = try url(path: "/w/api.php", query: [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"), .init(name: "prop", value: "info|pageprops"),
            .init(name: "inprop", value: "url"), .init(name: "ppprop", value: "disambiguation"),
            .init(name: "meta", value: "siteinfo"), .init(name: "siprop", value: "rightsinfo"),
            .init(name: "maxlag", value: "5")
        ])
        let info: InfoResponse = try decode(await get(infoURL))
        if let error = info.error { throw WikipediaSourceError.apiError(String(error.code.prefix(80))) }
        guard let query = info.query, let pages = query.pages, pages.count == 1 else {
            throw WikipediaSourceError.invalidIdentity
        }
        let page = pages[0]
        if page.missing == true { throw WikipediaSourceError.missingArticle }
        if page.invalid == true { throw WikipediaSourceError.invalidTitle }
        if page.pageprops?["disambiguation"] != nil { throw WikipediaSourceError.disambiguation }
        guard page.ns == 0, page.contentmodel == "wikitext", page.pagelanguage == "en",
              let pageID = page.pageid, pageID > 0,
              let revisionID = page.lastrevid, revisionID > 0,
              page.title == (try resolvedTitle(title, query: query)),
              let canonical = page.canonicalurl else { throw WikipediaSourceError.invalidIdentity }
        let canonicalURL = try articleURL(canonical, title: page.title)
        guard let rights = query.rightsinfo, !rights.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let license = URLComponents(string: rights.url), license.scheme == "https",
              license.host != nil, license.user == nil, license.password == nil,
              let licenseURL = license.url else { throw WikipediaSourceError.missingLicenseMetadata }

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        guard let encodedTitle = page.title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: allowed) else { throw WikipediaSourceError.invalidTitle }
        let summaryURL = try url(path: "/api/rest_v1/page/summary/" + encodedTitle,
                                 query: [.init(name: "redirect", value: "false")], percentEncoded: true)
        let summary: SummaryResponse = try decode(await get(summaryURL))
        if summary.type == "disambiguation" { throw WikipediaSourceError.disambiguation }
        if summary.type == "no-extract" { throw WikipediaSourceError.emptyExtract }
        guard summary.type == "standard", summary.namespace.id == 0, summary.lang == "en",
              summary.pageid == pageID, summary.titles.normalized == page.title,
              summary.titles.canonical.replacingOccurrences(of: "_", with: " ") == page.title,
              try articleURL(summary.content_urls.desktop.page, title: page.title) == canonicalURL else {
            throw WikipediaSourceError.invalidIdentity
        }
        guard let summaryRevision = Int64(summary.revision), summaryRevision > 0 else {
            throw WikipediaSourceError.invalidIdentity
        }
        guard summaryRevision == revisionID else { throw WikipediaSourceError.revisionChanged }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.date(from: summary.timestamp) ?? ISO8601DateFormatter().date(from: summary.timestamp)
        guard let timestamp else { throw WikipediaSourceError.invalidIdentity }
        guard !summary.extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WikipediaSourceError.emptyExtract
        }
        guard summary.extract.count <= Self.maximumExtractCharacters else { throw WikipediaSourceError.oversizedExtract }
        let digest = SHA256.hash(data: Data(summary.extract.utf8)).map { String(format: "%02x", $0) }.joined()
        let revisionURL = try url(path: "/w/index.php", query: [.init(name: "oldid", value: String(revisionID))])
        let historyURL = try url(path: "/w/index.php", query: [
            .init(name: "title", value: page.title), .init(name: "action", value: "history")
        ])
        return RetrievedResearchSource(requestedTitle: title, title: page.title, canonicalURL: canonicalURL,
            pageID: pageID, revisionID: revisionID, revisionURL: revisionURL, revisionTimestamp: timestamp,
            retrievedAt: now(), scope: .wikipediaIntroduction, text: summary.extract, textSHA256: digest,
            attribution: "English Wikipedia contributors, “\(page.title)”, revision \(revisionID). Introduction/summary excerpt.",
            attributionURL: historyURL, licenseName: rights.text, licenseURL: licenseURL)
    }

    /// Explicit alternate scope. Never called as fallback from retrieve(articleTitle:).
    /// https://en.wikipedia.org/w/api.php?action=help&modules=parse
    /// https://www.mediawiki.org/wiki/API:Revisions
    func retrieveOpeningExcerpt(articleTitle: String) async throws -> RetrievedResearchSource {
        let title = articleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 255, !title.contains("://"),
              title.rangeOfCharacter(from: .controlCharacters) == nil,
              title.rangeOfCharacter(from: CharacterSet(charactersIn: "|#")) == nil else { throw WikipediaSourceError.invalidTitle }
        let infoURL = try url(path: "/w/api.php", query: [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"), .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"), .init(name: "prop", value: "info|pageprops|revisions"),
            .init(name: "inprop", value: "url"), .init(name: "ppprop", value: "disambiguation"),
            .init(name: "meta", value: "siteinfo"), .init(name: "siprop", value: "rightsinfo"),
            .init(name: "rvprop", value: "ids|timestamp"), .init(name: "rvlimit", value: "1"),
            .init(name: "maxlag", value: "5")
        ])
        let info: InfoResponse = try decode(await get(infoURL))
        if let error = info.error { throw WikipediaSourceError.apiError(String(error.code.prefix(80))) }
        guard let query = info.query, let pages = query.pages, pages.count == 1 else { throw WikipediaSourceError.invalidIdentity }
        let page = pages[0]
        if page.missing == true { throw WikipediaSourceError.missingArticle }
        if page.invalid == true { throw WikipediaSourceError.invalidTitle }
        if page.pageprops?["disambiguation"] != nil { throw WikipediaSourceError.disambiguation }
        guard page.ns == 0, page.contentmodel == "wikitext", page.pagelanguage == "en",
              let pageID = page.pageid, pageID > 0, let revisionID = page.lastrevid, revisionID > 0,
              page.title == (try resolvedTitle(title, query: query)), let canonical = page.canonicalurl,
              let revisions = page.revisions, revisions.count == 1 else { throw WikipediaSourceError.invalidIdentity }
        guard revisions[0].revid == revisionID else { throw WikipediaSourceError.revisionChanged }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let timestamp = formatter.date(from: revisions[0].timestamp)
            ?? ISO8601DateFormatter().date(from: revisions[0].timestamp) else { throw WikipediaSourceError.invalidIdentity }
        let canonicalURL = try articleURL(canonical, title: page.title)
        guard let rights = query.rightsinfo, !rights.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let license = URLComponents(string: rights.url), license.scheme == "https", license.host != nil,
              license.user == nil, license.password == nil, let licenseURL = license.url else { throw WikipediaSourceError.missingLicenseMetadata }
        let parseURL = try url(path: "/w/api.php", query: [
            .init(name: "action", value: "parse"), .init(name: "oldid", value: String(revisionID)),
            .init(name: "prop", value: "text|revid|tocdata"), .init(name: "parser", value: "legacy"),
            .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "disablelimitreport", value: "1"), .init(name: "disableeditsection", value: "1"),
            .init(name: "disabletoc", value: "1"), .init(name: "maxlag", value: "5")
        ])
        let response: ParseResponse = try decode(await get(parseURL, maximumBytes: Self.maximumParseResponseBytes))
        if let error = response.error { throw WikipediaSourceError.apiError(String(error.code.prefix(80))) }
        guard let parsed = response.parse, parsed.pageid == pageID, parsed.title == page.title else { throw WikipediaSourceError.invalidIdentity }
        guard parsed.revid == revisionID else { throw WikipediaSourceError.revisionChanged }
        let excerpt = try WikipediaExcerptExtractor.extract(html: parsed.text, sections: parsed.tocdata.sections, articleTitle: page.title)
        if Task.isCancelled { throw WikipediaSourceError.cancelled }
        let digest = SHA256.hash(data: Data(excerpt.text.utf8)).map { String(format: "%02x", $0) }.joined()
        return RetrievedResearchSource(requestedTitle: title, title: page.title, canonicalURL: canonicalURL,
            pageID: pageID, revisionID: revisionID,
            revisionURL: try url(path: "/w/index.php", query: [.init(name: "oldid", value: String(revisionID))]),
            revisionTimestamp: timestamp, retrievedAt: now(), scope: .wikipediaOpeningExcerpt,
            text: excerpt.text, textSHA256: digest,
            attribution: "English Wikipedia contributors, “\(page.title)”, revision \(revisionID). Opening article excerpt—not the full article.",
            attributionURL: try url(path: "/w/index.php", query: [.init(name: "title", value: page.title), .init(name: "action", value: "history")]),
            licenseName: rights.text, licenseURL: licenseURL, extractionMetadata: excerpt.metadata)
    }

    private func get(_ url: URL, maximumBytes: Int = WikipediaSourceClient.maximumResponseBytes) async throws -> Data {
        if Task.isCancelled { throw WikipediaSourceError.cancelled }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GenBooksResearch/0.1 (https://github.com/jarvis-pd21/GenBooks)", forHTTPHeaderField: "User-Agent")
        do { return try await WikipediaHTTPRead(configuration: configuration, maximumBytes: maximumBytes).data(for: request) }
        catch WikipediaSourceError.httpStatus(404) { throw WikipediaSourceError.missingArticle }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WikipediaSourceError.invalidJSON }
    }

    private func url(path: String, query: [URLQueryItem], percentEncoded: Bool = false) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "en.wikipedia.org"
        if percentEncoded { components.percentEncodedPath = path } else { components.path = path }
        components.queryItems = query
        guard let url = components.url else { throw WikipediaSourceError.invalidIdentity }
        return url
    }

    private func articleURL(_ raw: String, title: String) throws -> URL {
        guard let components = URLComponents(string: raw), components.scheme == "https",
              components.host == "en.wikipedia.org", components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/wiki/" + title.replacingOccurrences(of: " ", with: "_"),
              let url = components.url else { throw WikipediaSourceError.invalidIdentity }
        return url
    }

    private func resolvedTitle(_ title: String, query: InfoResponse.Query) throws -> String {
        var current = title
        let normalized = query.normalized ?? []
        guard normalized.count <= 1 else { throw WikipediaSourceError.invalidIdentity }
        if let change = normalized.first {
            guard change.from == current else { throw WikipediaSourceError.invalidIdentity }
            current = change.to
        }
        var redirects = query.redirects ?? []
        guard redirects.count <= 10 else { throw WikipediaSourceError.unexpectedRedirect }
        while !redirects.isEmpty {
            let matches = redirects.indices.filter { redirects[$0].from == current }
            guard matches.count == 1 else { throw WikipediaSourceError.unexpectedRedirect }
            let change = redirects.remove(at: matches[0])
            guard change.tofragment == nil, change.to != current else { throw WikipediaSourceError.unexpectedRedirect }
            current = change.to
        }
        return current
    }

    private struct InfoResponse: Decodable {
        struct APIError: Decodable { let code: String }
        struct Change: Decodable { let from: String; let to: String; let tofragment: String? }
        struct Rights: Decodable { let url: String; let text: String }
        struct Page: Decodable {
            struct Revision: Decodable { let revid: Int64; let timestamp: String }
            let title: String
            let ns: Int?
            let pageid: Int64?
            let lastrevid: Int64?
            let canonicalurl: String?
            let contentmodel: String?
            let pagelanguage: String?
            let missing: Bool?
            let invalid: Bool?
            let pageprops: [String: String]?
            let revisions: [Revision]?
        }
        struct Query: Decodable {
            let pages: [Page]?
            let normalized: [Change]?
            let redirects: [Change]?
            let rightsinfo: Rights?
        }
        let query: Query?
        let error: APIError?
    }

    private struct ParseResponse: Decodable {
        struct Parsed: Decodable {
            struct TOC: Decodable { let sections: [WikipediaExcerptExtractor.Section] }
            let title: String
            let pageid: Int64
            let revid: Int64
            let text: String
            let tocdata: TOC
        }
        let parse: Parsed?
        let error: InfoResponse.APIError?
    }

    private struct SummaryResponse: Decodable {
        struct Namespace: Decodable { let id: Int }
        struct Titles: Decodable { let canonical: String; let normalized: String }
        struct URLs: Decodable {
            struct Desktop: Decodable { let page: String }
            let desktop: Desktop
        }
        let type: String
        let namespace: Namespace
        let titles: Titles
        let pageid: Int64
        let lang: String
        let revision: String
        let timestamp: String
        let content_urls: URLs
        let extract: String
    }
}

/// Per-request bounded buffer. HTTP redirects are rejected before any follow-up
/// connection. Caller cancellation, response headers and received chunks all
/// terminate this same request; completion resumes the continuation once.
private final class WikipediaHTTPRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.maximumBytes = maximumBytes
        super.init()
    }

    func data(for request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    continuation.resume(throwing: WikipediaSourceError.cancelled)
                    return
                }
                self.continuation = continuation
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.httpAdditionalHeaders = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = WikipediaSourceClient.requestTimeout
                configuration.timeoutIntervalForResource = WikipediaSourceClient.requestTimeout
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.finish(.failure(WikipediaSourceError.cancelled)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(WikipediaSourceError.unexpectedRedirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let failure: WikipediaSourceError?
        if response.url != dataTask.originalRequest?.url { failure = .unexpectedRedirect }
        else if let http = response as? HTTPURLResponse {
            if (300...399).contains(http.statusCode) { failure = .unexpectedRedirect }
            else if http.statusCode != 200 { failure = .httpStatus(http.statusCode) }
            else if http.mimeType != "application/json" { failure = .invalidJSON }
            else if response.expectedContentLength > maximumBytes { failure = .oversizedResponse }
            else { failure = nil }
        } else { failure = .invalidJSON }
        if let failure {
            completionHandler(.cancel)
            finish(.failure(failure))
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - buffer.count else {
            lock.unlock()
            finish(.failure(WikipediaSourceError.oversizedResponse))
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let code = (error as NSError).code
            let mapped: WikipediaSourceError = code == URLError.timedOut.rawValue ? .timedOut
                : code == URLError.cancelled.rawValue ? .cancelled : .network(code)
            finish(.failure(mapped))
        } else {
            lock.lock()
            let data = buffer
            lock.unlock()
            finish(.success(data))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
