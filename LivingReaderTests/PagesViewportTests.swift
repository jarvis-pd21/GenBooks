import SwiftUI
import UIKit
import XCTest
@testable import LivingReader

/// Exercises the real SwiftUI -> UIKit sizing boundary, not page arithmetic alone.
@MainActor
final class PagesViewportTests: XCTestCase {
    func testColdPagesKeepsPhoneViewportAndTurnsActualArgentinaTextForwardAndBack() async throws {
        let host = try makeHost(mode: .pages)
        defer { host.close() }
        let renderer = try await renderer(in: host)

        let publishedMultiplePages = await waitUntil(host) {
            (host.state.pageState?.count ?? 1) > 1
        }
        attachGeometry(renderer, host: host, name: "Cold Pages")
        XCTAssertTrue(publishedMultiplePages, geometry(renderer, host: host))
        XCTAssertGreaterThan(renderer.currentPageChromeState().count, 1)
        XCTAssertLessThanOrEqual(renderer.bounds.height, host.controller.view.bounds.height + 1,
                                 "The reader must remain a phone-sized viewport, not grow to the manuscript.")
        XCTAssertGreaterThan(renderer.contentHeight, renderer.textView.bounds.height)

        let initialOffset = renderer.textView.contentOffset.y
        let initialLocation = renderer.visibleUtf16Location()
        renderer.turnPage(by: 1, animated: false)
        let movedForward = await waitUntil(host) {
            renderer.textView.contentOffset.y > initialOffset + 1
                && renderer.visibleUtf16Location() > initialLocation
                && host.state.pageState?.index == 1
        }
        attachGeometry(renderer, host: host, name: "After Next")
        XCTAssertTrue(movedForward, "Next must move actual text and publish page 2. " + geometry(renderer, host: host))

        renderer.turnPage(by: -1, animated: false)
        let movedBack = await waitUntil(host) {
            abs(renderer.textView.contentOffset.y - initialOffset) < 1
                && renderer.visibleUtf16Location() == initialLocation
                && host.state.pageState?.index == 0
        }
        XCTAssertTrue(movedBack, "Previous must return to the same text. " + geometry(renderer, host: host))
    }

    func testScrollToPagesKeepsViewportAndRestoresFreePanWhenReturningToScroll() async throws {
        let host = try makeHost(mode: .scroll)
        defer { host.close() }
        let renderer = try await renderer(in: host)
        let laidOutLongText = await waitUntil(host) {
            renderer.contentHeight > renderer.textView.bounds.height
        }
        XCTAssertTrue(laidOutLongText, geometry(renderer, host: host))
        let scrollHeight = renderer.textView.bounds.height
        XCTAssertTrue(renderer.textView.isScrollEnabled)
        XCTAssertTrue(renderer.textView.panGestureRecognizer.isEnabled)

        host.state.mode = .pages
        let pagesReady = await waitUntil(host) {
            renderer.scrollMode == .pages && (host.state.pageState?.count ?? 1) > 1
        }
        attachGeometry(renderer, host: host, name: "Scroll to Pages")
        XCTAssertTrue(pagesReady, geometry(renderer, host: host))
        XCTAssertEqual(renderer.textView.bounds.height, scrollHeight, accuracy: 1,
                       "Changing reading mode must not resize the viewport to fit all text.")
        XCTAssertFalse(renderer.textView.isScrollEnabled && renderer.textView.panGestureRecognizer.isEnabled,
                       "Pages must suppress free vertical dragging while preserving page turns.")

        renderer.turnPage(by: 1, animated: false)
        let moved = await waitUntil(host) { renderer.textView.contentOffset.y > 1 }
        XCTAssertTrue(moved, "Pages must remain navigable after switching from Scroll.")

        host.state.mode = .scroll
        let scrollingReady = await waitUntil(host) {
            renderer.scrollMode == .scroll
                && renderer.textView.isScrollEnabled
                && renderer.textView.panGestureRecognizer.isEnabled
        }
        XCTAssertTrue(scrollingReady, "Switching back must restore the native scrolling gesture.")
        XCTAssertEqual(renderer.textView.bounds.height, scrollHeight, accuracy: 1)
    }

    func testFullBookRestoreThenChapterStartJumpStaysOnPageOneAfterModeUpdate() async throws {
        let host = try makeHost(mode: .scroll, wholeBook: true, restoringChapterID: ArgentinaFixtureIDs.chapter2)
        defer { host.close() }
        let renderer = try await renderer(in: host)
        let restore = try XCTUnwrap(host.state.restoreLocation)
        let restored = await waitUntil(host) {
            host.state.lastLocation?.chapterId == restore.chapterId
                && renderer.textView.contentOffset.y > renderer.textView.bounds.height
        }
        attachGeometry(renderer, host: host, name: "Full book restored C2")
        XCTAssertTrue(restored, geometry(renderer, host: host))
        XCTAssertGreaterThan(host.document.chapterStarts.count, 1)
        XCTAssertEqual(host.document.chapterStarts.first?.utf16Location, 0)

        host.state.jump(to: 0, animated: true)
        let reachedStart = await waitUntil(host) { abs(renderer.textView.contentOffset.y) < 1 }
        attachGeometry(renderer, host: host, name: "Full book TOC jump before mode change")
        XCTAssertTrue(reachedStart, "The explicit chapter-start jump must reach the rendered start. " + geometry(renderer, host: host))

        host.state.mode = .pages
        let pagesReady = await waitUntil(host) {
            renderer.scrollMode == .pages && host.state.pageState != nil
        }
        await drainPendingUpdates(host)
        attachGeometry(renderer, host: host, name: "Full book TOC jump after mode change")
        XCTAssertTrue(pagesReady, geometry(renderer, host: host))
        XCTAssertEqual(renderer.textView.contentOffset.y, 0, accuracy: 1, geometry(renderer, host: host))
        XCTAssertEqual(renderer.currentPageChromeState().index, 0, geometry(renderer, host: host))
        XCTAssertEqual(host.state.pageState?.index, 0, geometry(renderer, host: host))
    }

    func testInitialExplicitJumpSupersedesRestoreAcrossNextRepresentableUpdate() async throws {
        let host = try makeHost(
            mode: .scroll, wholeBook: true,
            restoringChapterID: ArgentinaFixtureIDs.chapter2, initialJumpUtf16: 0
        )
        defer { host.close() }
        let renderer = try await renderer(in: host)
        let originalToken = try XCTUnwrap(host.state.jumpToken)
        let originalRestore = try XCTUnwrap(host.state.restoreLocation)
        XCTAssertEqual(originalRestore.chapterId, ArgentinaFixtureIDs.chapter2)

        // The first update chooses the explicit jump. The next update has the
        // same token plus the old restore location and must not replay it.
        await drainPendingUpdates(host)
        attachGeometry(renderer, host: host, name: "Simultaneous restore and explicit jump")
        XCTAssertEqual(renderer.textView.contentOffset.y, 0, accuracy: 1, geometry(renderer, host: host))
        host.state.mode = .pages
        let pagesReady = await waitUntil(host) {
            renderer.scrollMode == .pages && host.state.pageState != nil
        }
        await drainPendingUpdates(host)
        attachGeometry(renderer, host: host, name: "Simultaneous jump after second update")
        XCTAssertTrue(pagesReady, geometry(renderer, host: host))
        XCTAssertEqual(host.state.jumpToken, originalToken)
        XCTAssertEqual(host.state.restoreLocation, originalRestore)
        XCTAssertEqual(renderer.textView.contentOffset.y, 0, accuracy: 1, geometry(renderer, host: host))
        XCTAssertEqual(renderer.currentPageChromeState().index, 0, geometry(renderer, host: host))
        XCTAssertEqual(host.state.pageState?.index, 0, geometry(renderer, host: host))
    }

    func testChapterBoundaryCheckpointStaysInSavedChapterAfterRendererSettles() async throws {
        let host = try makeHost(mode: .scroll, wholeBook: true,
                                restoringChapterID: ArgentinaFixtureIDs.chapter2,
                                restoringChapterOffset: 0)
        defer { host.close() }
        let renderer = try await renderer(in: host)
        let saved = try XCTUnwrap(host.state.restoreLocation)
        let published = await waitUntil(host) { host.state.lastLocation != nil }
        XCTAssertTrue(published, "The native renderer must publish its settled reading position")
        await drainPendingUpdates(host)

        attachGeometry(renderer, host: host, name: "Checkpoint at C2 boundary")
        let settled = try XCTUnwrap(host.state.lastLocation)
        XCTAssertEqual(settled.chapterId, saved.chapterId,
                       "Reopening a chapter heading must not save the preceding chapter")
        XCTAssertEqual(settled.blockId, saved.blockId,
                       "The saved heading must remain at the reader's checkpoint line")
        let rendered = try XCTUnwrap(host.document.location(atUtf16: renderer.visibleUtf16Location()))
        XCTAssertEqual(rendered.chapterId, saved.chapterId, geometry(renderer, host: host))
        XCTAssertEqual(rendered.blockId, saved.blockId, geometry(renderer, host: host))
    }

    func testRepeatedBodyCheckpointRestoresKeepTheSameRenderedLine() async throws {
        var nextCheckpoint: ReaderLocation?
        var originalCheckpoint: ReaderLocation?
        for reopening in 1...3 {
            let host = try makeHost(mode: .scroll, wholeBook: true,
                                    restoringChapterID: ArgentinaFixtureIDs.chapter2,
                                    checkpoint: nextCheckpoint)
            defer { host.close() }
            let renderer = try await renderer(in: host)
            if originalCheckpoint == nil { originalCheckpoint = host.state.restoreLocation }
            let original = try XCTUnwrap(originalCheckpoint)
            let published = await waitUntil(host) { host.state.lastLocation != nil }
            XCTAssertTrue(published, "Reopening \(reopening) must publish the native reading position")
            await drainPendingUpdates(host)

            attachGeometry(renderer, host: host, name: "Body checkpoint reopening \(reopening)")
            let settled = try XCTUnwrap(host.state.lastLocation)
            XCTAssertEqual(settled.chapterId, original.chapterId)
            XCTAssertEqual(settled.blockId, original.blockId,
                           "Repeated reopening must not walk backward through paragraphs")
            let expectedOffset = try XCTUnwrap(host.document.utf16Location(for: original))
            let expectedLine = try glyphRect(at: expectedOffset, in: renderer.textView)
            let actualLine = try glyphRect(at: renderer.visibleUtf16Location(), in: renderer.textView)
            XCTAssertEqual(actualLine.minY, expectedLine.minY, accuracy: 1,
                           "Reopening must retain the saved rendered line. " + geometry(renderer, host: host))
            nextCheckpoint = settled
        }
    }

    func testFarChapterCheckpointUsesLaidOutPrefixAtAppTextSize() async throws {
        let host = try makeHost(mode: .scroll, wholeBook: true,
                                restoringChapterID: ArgentinaFixtureIDs.chapter2,
                                restoringChapterOffset: 0,
                                bodyPointSize: 18,
                                viewportSize: CGSize(width: 402, height: 758))
        defer { host.close() }
        let renderer = try await renderer(in: host)
        let saved = try XCTUnwrap(host.state.restoreLocation)
        let target = try XCTUnwrap(host.document.utf16Location(for: saved))
        XCTAssertGreaterThan(target, 20_000, "The target must be beyond the initially laid-out viewport")
        XCTAssertEqual(renderer.textView.bounds.width, 402, accuracy: 1)
        XCTAssertEqual(renderer.textView.bounds.height, 758, accuracy: 1)
        let published = await waitUntil(host) { host.state.lastLocation != nil }
        XCTAssertTrue(published)
        await drainPendingUpdates(host)

        attachGeometry(renderer, host: host, name: "Far checkpoint at app text size")
        let settled = try XCTUnwrap(host.state.lastLocation)
        XCTAssertEqual(settled.chapterId, saved.chapterId,
                       "Estimated offscreen heights must not move Continue into the preceding chapter")
        XCTAssertEqual(settled.blockId, saved.blockId)
        let expectedLine = try glyphRect(at: target, in: renderer.textView)
        let actualLine = try glyphRect(at: renderer.visibleUtf16Location(), in: renderer.textView)
        XCTAssertEqual(actualLine.minY, expectedLine.minY, accuracy: 1,
                       "The actual displayed reading line must contain the saved anchor. " + geometry(renderer, host: host))
    }

    private func makeHost(
        mode: ReaderScrollMode,
        wholeBook: Bool = false,
        restoringChapterID: UUID? = nil,
        restoringChapterOffset: Int = 1200,
        checkpoint: ReaderLocation? = nil,
        initialJumpUtf16: Int? = nil,
        bodyPointSize: CGFloat = 19,
        viewportSize: CGSize? = nil
    ) throws -> Host {
        var book = try BundleFixtureLoader.loadArgentinaMinimal()
        let firstChapter = try XCTUnwrap(book.chapters.sorted { $0.orderIndex < $1.orderIndex }.first)
        if !wholeBook { book.chapters = [firstChapter] }
        var revisions: [UUID: ChapterRevision] = [:]
        for chapter in book.chapters {
            revisions[chapter.id] = try XCTUnwrap(chapter.activeRevision)
        }
        let typography = ReaderTypography.make(bodyPointSize: bodyPointSize, colorScheme: .light)
        let document = ReaderDocumentBuilder.build(
            book: book,
            readableRevisions: revisions,
            typography: typography
        )
        XCTAssertGreaterThan(document.length, 10_000, "This regression requires the long real Argentina C1.")
        var restoreLocation = checkpoint
        if restoreLocation == nil, let restoringChapterID {
            let start = try XCTUnwrap(document.chapterStarts.first { $0.chapterId == restoringChapterID })
            let end = document.chapterStarts.first { $0.utf16Location > start.utf16Location }?.utf16Location ?? document.length
            let offset = start.utf16Location + min(restoringChapterOffset, (end - start.utf16Location) / 2)
            restoreLocation = try XCTUnwrap(document.location(atUtf16: offset))
        }
        let state = HostState(mode: mode, restoreLocation: restoreLocation, initialJumpUtf16: initialJumpUtf16)
        let controller = UIHostingController(rootView: HostView(
            state: state, document: document, typography: typography, viewportSize: viewportSize
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: viewportSize?.width ?? 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        let host = Host(window: window, controller: controller, state: state, document: document)
        host.layout()
        return host
    }

    private func renderer(in host: Host) async throws -> TextKitReaderUIView {
        let appeared = await waitUntil(host) {
            self.findRenderer(in: host.controller.view)?.textView.bounds.height ?? 0 > 1
        }
        XCTAssertTrue(appeared, "Expected the real TextKit reader inside the SwiftUI host.")
        return try XCTUnwrap(findRenderer(in: host.controller.view))
    }

    private func findRenderer(in view: UIView) -> TextKitReaderUIView? {
        if let renderer = view as? TextKitReaderUIView { return renderer }
        return view.subviews.lazy.compactMap { self.findRenderer(in: $0) }.first
    }

    private func glyphRect(at utf16: Int, in text: UITextView) throws -> CGRect {
        let start = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: utf16))
        let end = try XCTUnwrap(text.position(from: start, offset: 1))
        let range = try XCTUnwrap(text.textRange(from: start, to: end))
        let rect = text.firstRect(for: range)
        XCTAssertFalse(rect.isNull || rect.isInfinite || rect.isEmpty, "Expected a real laid-out text line")
        return rect
    }

    private func waitUntil(_ host: Host, condition: () -> Bool) async -> Bool {
        // Drain SwiftUI layout and the renderer's delayed settle publication,
        // with one bounded deadline rather than trusting a single layout pass.
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layout()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        host.layout()
        return condition()
    }

    private func geometry(_ renderer: TextKitReaderUIView, host: Host) -> String {
        let text = renderer.textView
        let glyphZero: CGRect?
        if let start = text.position(from: text.beginningOfDocument, offset: 0),
           let end = text.position(from: start, offset: 1),
           let range = text.textRange(from: start, to: end) {
            glyphZero = text.firstRect(for: range)
        } else {
            glyphZero = nil
        }
        return "host=\(host.controller.view.bounds.size), renderer=\(renderer.bounds.size), "
            + "textBounds=\(renderer.textView.bounds.size), content=\(renderer.textView.contentSize), "
            + "offset=\(renderer.textView.contentOffset), length=\(renderer.appliedDocumentLength), "
            + "adjustedInset=\(text.adjustedContentInset), glyphZero=\(String(describing: glyphZero)), "
            + "visibleUTF16=\(renderer.visibleUtf16Location()), "
            + "restoreUTF16=\(String(describing: host.state.restoreLocation.flatMap { host.document.utf16Location(for: $0) })), "
            + "jumpUTF16=\(String(describing: host.state.jumpUtf16)), jumpToken=\(String(describing: host.state.jumpToken)), "
            + "actualPages=\(renderer.currentPageChromeState().displayLabel), "
            + "publishedPages=\(host.state.pageState?.displayLabel ?? "none"), "
            + "scrollEnabled=\(renderer.textView.isScrollEnabled), "
            + "panEnabled=\(renderer.textView.panGestureRecognizer.isEnabled)"
    }

    private func drainPendingUpdates(_ host: Host) async {
        // Observe beyond the renderer's 0.05/0.18-second callbacks so a transient
        // page-one state cannot pass before a queued stale restoration executes.
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            host.layout()
            try? await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        host.layout()
    }

    private func attachGeometry(_ renderer: TextKitReaderUIView, host: Host, name: String) {
        let details = geometry(renderer, host: host)
        print("PagesViewport \(name): \(details)")
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: details)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    @MainActor
    private final class HostState: ObservableObject {
        @Published var mode: ReaderScrollMode
        @Published var pageState: ReaderPageChromeState?
        @Published var jumpToken: UUID?
        @Published var jumpUtf16: Int?
        var jumpAnimated = false
        let restoreLocation: ReaderLocation?
        var lastLocation: ReaderLocation?

        init(mode: ReaderScrollMode, restoreLocation: ReaderLocation?, initialJumpUtf16: Int?) {
            self.mode = mode
            self.restoreLocation = restoreLocation
            self.jumpUtf16 = initialJumpUtf16
            self.jumpToken = initialJumpUtf16 == nil ? nil : UUID()
        }

        func jump(to utf16: Int, animated: Bool) {
            jumpAnimated = animated
            jumpUtf16 = utf16
            jumpToken = UUID()
        }
    }

    private struct HostView: View {
        @ObservedObject var state: HostState
        let document: ReaderDocument
        let typography: ReaderTypography
        let viewportSize: CGSize?

        var body: some View {
            ZStack {
                Color.clear
                TextKitReaderRepresentable(
                    document: document,
                    typography: typography,
                    scrollMode: state.mode,
                    restoreLocation: state.restoreLocation,
                    jumpToken: state.jumpToken,
                    jumpUtf16: state.jumpUtf16,
                    jumpAnimated: state.jumpAnimated,
                    documentEpoch: 1,
                    persistentHighlights: [],
                    highlightEpoch: 1,
                    bottomChromeHeight: 92,
                    onLocationChange: { state.lastLocation = $0 },
                    onSelectionChange: { _ in },
                    onPageStateChange: { state.pageState = $0 }
                )
                .frame(width: viewportSize?.width, height: viewportSize?.height)
            }
        }
    }

    @MainActor
    private final class Host {
        let window: UIWindow
        let controller: UIHostingController<HostView>
        let state: HostState
        let document: ReaderDocument

        init(window: UIWindow, controller: UIHostingController<HostView>, state: HostState, document: ReaderDocument) {
            self.window = window
            self.controller = controller
            self.state = state
            self.document = document
        }

        func layout() {
            window.layoutIfNeeded()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            controller.view.removeFromSuperview()
        }
    }
}
