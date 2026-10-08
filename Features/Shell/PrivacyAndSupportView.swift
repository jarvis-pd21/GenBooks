import SwiftUI

/// Bundled text keeps privacy and help readable without a network request.
struct PrivacyAndSupportView: View {
    enum Page {
        case privacy
        case support

        var title: String { self == .privacy ? "Privacy Policy" : "Help & Support" }
        var identifier: String { self == .privacy ? "privacy" : "support" }
        var publishedURL: URL {
            URL(string: "https://github.com/jarvis-pd21/GenBooks/blob/main/docs/\(identifier).md")!
        }
    }

    let page: Page

    var body: some View {
        List {
            ForEach(page == .privacy ? NativeHelpContent.privacy : NativeHelpContent.support) { section in
                Section {
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text(section.title)
                        .textCase(nil)
                }
            }
            if page == .privacy {
                Section("Provider information") {
                    ForEach(NativeHelpContent.providerLinks, id: \.title) { link in
                        Link(link.title, destination: link.url)
                    }
                }
            }
            Section {
                Link("Email jarvis@agi-jarvis.com", destination: URL(string: "mailto:jarvis@agi-jarvis.com")!)
                    .accessibilityIdentifier("\(page.identifier).email")
                Link("Read the published version", destination: page.publishedURL)
                    .accessibilityIdentifier("\(page.identifier).published")
            } footer: {
                Text("This page is available offline. Website links need an internet connection; email opens your mail app.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(LRColor.background)
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .genBooksNavigationBar()
        .accessibilityIdentifier("\(page.identifier).screen")
    }
}

private enum NativeHelpContent {
    struct Section: Identifiable {
        let title: String
        let paragraphs: [String]
        var id: String { title }
    }

    struct ProviderLink {
        let title: String
        let url: URL
    }

    static let privacy: [Section] = [
        .init(title: "About this policy", paragraphs: [
            "This policy covers the native GenBooks iPhone app, published by JARVIS. Contact jarvis@agi-jarvis.com for privacy questions or requests. Policy date: October 7, 2026.",
            "The iPhone app does not create a GenBooks account or sync with the GenBooks website. The website has separate account storage and privacy information. Reading saved books and the included Physics course does not require sign-in or an AI connection."
        ]),
        .init(title: "What stays on your iPhone", paragraphs: [
            "Books, preserved source PDFs, revisions, reading positions, highlights, notes, bookmarks, saved words, writing drafts, downloaded narration and learning records are stored in app-owned files. Original-page positions are stored separately from text-reading positions. Display preferences and your OpenAI permission choice are stored in app settings. Your optional OpenAI API key is stored in Keychain, protected storage managed by iOS.",
            "The Share extension temporarily stages a file you choose in storage shared with GenBooks so the app can import it. Device or computer backups may include app data, depending on your backup settings. Local storage does not mean that backups cannot contain a copy.",
            "The native app has no advertising or analytics SDKs and does not sell your information or upload your library to a GenBooks sync service."
        ]),
        .init(title: "Optional OpenAI requests", paragraphs: [
            "Before an OpenAI request, GenBooks requires your explicit permission in Settings → BookBot. Saving a key does not grant permission. An existing key from an earlier version does not grant permission either. You can turn permission off there; this blocks new OpenAI requests but cannot recall requests already sent.",
            "When you choose BookBot or AI word help, the request can include your question, selected and surrounding text, chapter or book details, notes and supplied preferences. Generation and adaptation can send your brief, relevant manuscript text, preferences and source records. New narration sends the text being spoken. These requests go directly to OpenAI using your key; GenBooks does not route them through its own server.",
            "OpenAI also receives the request metadata needed to deliver its service, including your network address and the API credential that identifies your provider account. Your provider account may be charged for usage. Permission is optional: saved reading, local notes, the Physics course and already downloaded narration remain available without it.",
            "OpenAI controls its processing and retention under the terms and settings of your provider account. GenBooks does not control or verify that account’s retention settings and does not promise immediate deletion or zero retention. Removing local data, a key or permission does not delete earlier provider records. See OpenAI’s API data controls and privacy information below."
        ]),
        .init(title: "Speech and source lookup", paragraphs: [
            "Voice dictation asks for microphone and speech-recognition permission. GenBooks requests on-device recognition when the device supports it; otherwise Apple’s speech service can process the audio. GenBooks does not save a microphone recording. A question you submit after dictation follows the OpenAI path described above. You can turn microphone and speech permissions off in iOS Settings.",
            "When you request a Wikipedia source preview, GenBooks sends the requested article title to Wikipedia. Wikipedia receives ordinary connection metadata, including your network address. The retained source excerpt and authoring or review prompts go to OpenAI only with your permission. Opening a website or email link also invokes that service and its privacy terms."
        ]),
        .init(title: "Retention and your controls", paragraphs: [
            "Local records persist across normal launches. Archiving a book keeps the book and its notes; it does not delete them. The current app does not offer permanent deletion of an entire book or a complete library export. Keep the original files you import.",
            "You can delete individual notes and bookmarks through their editing controls. For a fully downloaded chapter and selected voice, open Listen and choose Remove download. Other voices, revisions or partial downloads may remain. In Settings → BookBot, Remove API key deletes the saved key from this app’s Keychain entry; it does not revoke the key at OpenAI.",
            "To remove the app’s local documents, delete the app in iOS rather than offloading it. Remove your API key first because Keychain entries can survive app deletion. App deletion does not erase your original imported files, backups or earlier provider records. Manage backups through Apple’s controls and provider records through the provider.",
            "If you contact support, your email address and the information you choose to send enter our support mailbox so we can respond. Do not send API keys or a private book. You may ask us to delete support correspondence; we retain only what is needed for an unresolved request or a legal obligation."
        ]),
        .init(title: "Policy changes and contact", paragraphs: [
            "The app includes this policy so it can be read offline. The published version is linked below. Material changes to the scope of OpenAI sharing require renewed permission in the app. Email jarvis@agi-jarvis.com with a privacy question, a request concerning support correspondence, or a report of a privacy problem."
        ])
    ]

    static let support: [Section] = [
        .init(title: "Get help", paragraphs: [
            "Email jarvis@agi-jarvis.com. Include your GenBooks version from Settings, your iOS version, what you tried and the exact error. A screenshot is useful after you remove private text. Never send an API key or a complete private book.",
            "Your saved books are local to this iPhone. Support cannot remotely inspect or restore that library. Keep the original files you import and a device backup before reinstalling the app."
        ]),
        .init(title: "Read or import a book", paragraphs: [
            "Open Library and choose a book. Use Learning for the included Physics readings and optional practice. Notebook collects your notes and saved words. Saved reading and the Physics course work offline.",
            "In Library, choose New Book → Existing Books, then choose an EPUB or PDF, or paste text. You can also use a file’s Share or Open In action to send a supported file to GenBooks. New PDF imports retain the complete supplied file and open in Original pages. Pinch to zoom, use Contents or search, and jump to a PDF page.",
            "Original pages preserves the supplied PDF’s tables, figures, equations and layout, including scanned pages. It cannot improve missing or low-resolution source material. PDF page numbers identify positions in that file, which may differ from printed page numbers. Search requires a text layer; GenBooks does not perform text recognition.",
            "Text view keeps the existing notes, BookBot and reading tools, with a separate saved position. Extracted text and EPUB imports can lose tables, images, links and formatting; they are not facsimiles. Switch to Original pages for complete PDF content. There is no in-app tool to attach a PDF to an older text-only import. Import its PDF as a new book to gain Original pages; existing notes stay on the earlier text copy. Protected EPUBs and encrypted PDFs are unsupported. Keep your original files."
        ]),
        .init(title: "Use optional BookBot and narration", paragraphs: [
            "Open Settings → BookBot to review the OpenAI sharing explanation, choose whether to allow requests and save your own OpenAI API key. AI features require internet access, an eligible provider account and access to the selected model. OpenAI may charge your account for usage; GenBooks does not include provider credit.",
            "If a request fails, check the message, connection, permission choice, saved key and provider account. Reading saved content does not depend on the request succeeding. Do not send a key to support. Remove or replace it in Settings → BookBot.",
            "Voice questions also require iOS microphone and speech permissions. You can type if voice is unavailable. Downloaded narration can play offline; making new narration sends the relevant text to OpenAI with your permission. Listen → Remove download removes the currently selected fully downloaded chapter and voice, not every audio file.",
            "BookBot can be wrong. Ordinary answers are not independently fact-checked. Source-backed writing currently supports an opening preview and limited continuation using a retained source; it is not a fully verified generated textbook. The Physics check score describes results on designated questions, not measured mastery of physics."
        ]),
        .init(title: "Find an archived book or manage data", paragraphs: [
            "Archiving keeps a book and its notes. Open Archive from Library to restore it. This is different from deleting a note, bookmark, downloaded chapter or API key.",
            "The current native app has no permanent whole-book deletion or complete-library export. Deleting the app removes local app documents; offloading preserves them. Keychain entries and backups are separate. Read Privacy Policy before removing the app, and keep your original book files."
        ]),
        .init(title: "iPhone and web are separate", paragraphs: [
            "The GenBooks website can save an account library across browsers signed into the same account. The native iPhone app has its own local library and does not sync with that web account. A book added on one surface will not automatically appear on the other.",
            "Appearance, navigation and import support differ between the two versions. Use the website’s Settings for its privacy information and data export; use the iPhone app’s Settings for its local version and OpenAI controls."
        ])
    ]

    static let providerLinks: [ProviderLink] = [
        .init(title: "OpenAI API data controls", url: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!),
        .init(title: "OpenAI privacy policy", url: URL(string: "https://openai.com/policies/privacy-policy/")!),
        .init(title: "Apple speech and dictation privacy", url: URL(string: "https://www.apple.com/legal/privacy/data/en/ask-siri-dictation/")!),
        .init(title: "Wikimedia privacy policy", url: URL(string: "https://foundation.wikimedia.org/wiki/Policy:Privacy_policy")!)
    ]
}
