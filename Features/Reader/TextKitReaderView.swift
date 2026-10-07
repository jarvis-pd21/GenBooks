import SwiftUI
import UIKit

/// Bottom text padding so last lines clear the home indicator and measured chrome.
enum ReaderChromeMetrics {
    static let fallbackHomeIndicator: CGFloat = 34
    static let clearance: CGFloat = 12

    static func textBottomInset(chromeHeight: CGFloat, homeIndicator: CGFloat) -> CGFloat {
        let chrome = max(0, chromeHeight)
        let home = homeIndicator > 0 ? homeIndicator : fallbackHomeIndicator
        if chrome <= 0 {
            return home + 8
        }
        return chrome + home + clearance
    }
}

/// UITextView that never presents Apple’s system edit menu (Copy / Look Up / Translate / …).
/// Living Reader owns selection chrome via `SelectionActionsSheet` / Change-from-here.
final class ReaderSelectableTextView: UITextView {
    /// Returning nil suppresses the menu while preserving the selection highlight.
    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        // Intentionally empty — do not inherit standardEdit / lookup / translate.
    }
}

/// UITextView-backed continuous vertical reader (TextKit via UITextView).
final class TextKitReaderUIView: UIView, ContinuousReaderRendering, UITextViewDelegate, UIGestureRecognizerDelegate {
    let textView: ReaderSelectableTextView = {
        let tv = ReaderSelectableTextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        if #available(iOS 18.0, *) {
            // Writing Tools is separate from edit menus; manuscript text is app-owned.
            tv.writingToolsBehavior = .none
        }
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 22, bottom: 92, right: 22)
        tv.textContainer.lineFragmentPadding = 0
        tv.alwaysBounceVertical = true
        tv.showsVerticalScrollIndicator = true
        tv.adjustsFontForContentSizeCategory = false
        tv.contentInsetAdjustmentBehavior = .automatic
        return tv
    }()

    var onScrollSettled: ((Int, Double) -> Void)?
    var onSelectionChanged: ((NSRange?) -> Void)?
    /// Plain tap on the page, reported as a document UTF-16 offset. Notes use it to reopen
    /// the note sitting on the tapped words.
    var onTapAtUtf16Offset: ((Int) -> Void)?
    private var settleWorkItem: DispatchWorkItem?
    private(set) var appliedDocumentLength: Int = 0
    private var baseAttributedText: NSAttributedString?
    private var persistentHighlightRanges: [(NSRange, UIColor)] = []
    private var searchRange: NSRange?
    private(set) var scrollMode: ReaderScrollMode = .scroll
    private var pageSwipeLeft: UISwipeGestureRecognizer?
    private var pageSwipeRight: UISwipeGestureRecognizer?
    private var pageEdgeTap: UITapGestureRecognizer?
    private weak var configuredContentPopGesture: UIGestureRecognizer?
    private var noteTap: UITapGestureRecognizer?
    private var lastPagedViewportHeight: CGFloat = 0
    private let topPageCover = UIView()
    private let bottomPageCover = UIView()
    /// Published to SwiftUI for "N of M" / go-to-page chrome.
    var onPageStateChange: ((ReaderPageChromeState) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        textView.delegate = self
        accessibilityIdentifier = "reader.textkit.view"
        textView.accessibilityIdentifier = "reader.textkit.text"
        textView.accessibilityLabel = "Book text"
        configurePageCovers()
        installNoteTapGesture()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            // A retained navigation failure dependency must not wait on a detached reader.
            removePageGestures()
            return
        }
        configureScrollModeGestures()
    }

    /// Additive by design: `cancelsTouchesInView = false` plus simultaneous recognition
    /// keeps TextKit selection, page edge taps and the SwiftUI chrome toggle intact.
    private func installNoteTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleNoteTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        noteTap = tap
    }

    @objc private func handleNoteTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // Never fight an active selection or a page turn.
        guard textView.selectedRange.length == 0 else { return }
        if scrollMode == .pages,
           ReaderPageGeometry.edgeTapDirection(x: gesture.location(in: self).x, width: bounds.width) != nil {
            return
        }
        let point = gesture.location(in: textView)
        guard let position = textView.closestPosition(to: point) else { return }
        onTapAtUtf16Offset?(textView.offset(from: textView.beginningOfDocument, to: position))
    }

    private func configurePageCovers() {
        for cover in [topPageCover, bottomPageCover] {
            cover.translatesAutoresizingMaskIntoConstraints = false
            cover.isUserInteractionEnabled = false
            cover.isHidden = true
            cover.accessibilityElementsHidden = true
            insertSubview(cover, aboveSubview: textView)
        }
        NSLayoutConstraint.activate([
            topPageCover.topAnchor.constraint(equalTo: topAnchor),
            topPageCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            topPageCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            topPageCover.heightAnchor.constraint(equalToConstant: 2),
            bottomPageCover.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomPageCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomPageCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPageCover.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(document: ReaderDocument) {
        baseAttributedText = document.attributedText
        appliedDocumentLength = document.length
        reapplyOverlays()
    }

    func apply(typographyBackground: UIColor) {
        backgroundColor = typographyBackground
        textView.backgroundColor = typographyBackground
        topPageCover.backgroundColor = typographyBackground
        bottomPageCover.backgroundColor = typographyBackground
    }

    /// Fallback when chrome has not been measured yet (progress bar only).
    static let bottomInset: CGFloat = 92

    func applyInsets(horizontal: CGFloat, bottomChrome: CGFloat? = nil) {
        let home = textView.safeAreaInsets.bottom
        let chrome = bottomChrome ?? Self.bottomInset
        let bottom = ReaderChromeMetrics.textBottomInset(chromeHeight: chrome, homeIndicator: home)
        textView.textContainerInset = UIEdgeInsets(top: 24, left: horizontal, bottom: bottom, right: horizontal)
        if scrollMode == .pages {
            // Insets change the usable page; re-snap after layout.
            setNeedsLayout()
        }
    }

    func apply(scrollMode: ReaderScrollMode) {
        let changed = self.scrollMode != scrollMode
        self.scrollMode = scrollMode
        configureScrollModeGestures()
        if changed || scrollMode == .pages {
            layoutIfNeeded()
            if scrollMode == .pages {
                snapToNearestPage(animated: false)
            }
        }
    }

    private func configureScrollModeGestures() {
        switch scrollMode {
        case .scroll:
            textView.isScrollEnabled = true
            textView.panGestureRecognizer.isEnabled = true
            textView.alwaysBounceVertical = true
            textView.showsVerticalScrollIndicator = true
            textView.clipsToBounds = true
            topPageCover.isHidden = true
            bottomPageCover.isHidden = true
            removePageGestures()
        case .pages:
            // Free vertical drag off — edge taps + L/R swipes turn pages (Codex-style).
            // Keep TextKit's scroll-backed content size: disabling scrolling can
            // collapse contentSize to the viewport and report "1 of 1" for long text.
            // Suppress only free dragging; page turns still set contentOffset.
            textView.isScrollEnabled = true
            textView.panGestureRecognizer.isEnabled = false
            textView.alwaysBounceVertical = false
            textView.showsVerticalScrollIndicator = false
            textView.clipsToBounds = true
            topPageCover.isHidden = false
            bottomPageCover.isHidden = false
            installPageGestures()
        }
    }

    private func installPageGestures() {
        if pageSwipeLeft == nil {
            let left = UISwipeGestureRecognizer(target: self, action: #selector(handlePageSwipe(_:)))
            left.direction = .left
            left.delegate = self
            addGestureRecognizer(left)
            pageSwipeLeft = left
        }
        if pageSwipeRight == nil {
            let right = UISwipeGestureRecognizer(target: self, action: #selector(handlePageSwipe(_:)))
            right.direction = .right
            right.delegate = self
            addGestureRecognizer(right)
            pageSwipeRight = right
        }
        if pageEdgeTap == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handlePageEdgeTap(_:)))
            tap.numberOfTapsRequired = 1
            tap.delegate = self
            // Let selection / chrome center-tap win when not on an edge.
            tap.cancelsTouchesInView = false
            addGestureRecognizer(tap)
            pageEdgeTap = tap
        }
        let active = window != nil && scrollMode == .pages
        pageSwipeLeft?.isEnabled = active
        pageSwipeRight?.isEnabled = active
        pageEdgeTap?.isEnabled = active
        prioritizePageSwipeOverContentBack()
    }

    private func prioritizePageSwipeOverContentBack() {
        guard #available(iOS 26.0, *), window != nil, scrollMode == .pages,
              let right = pageSwipeRight else { return }
        var responder: UIResponder? = self
        while let current = responder {
            let navigation = (current as? UINavigationController)
                ?? (current as? UIViewController)?.navigationController
            if let contentPop = navigation?.interactiveContentPopGestureRecognizer {
                if configuredContentPopGesture !== contentPop {
                    // iOS 26 Back can begin anywhere in the content, not just at the edge.
                    // Let Pages own its rightward swipe; leave edge Back and the button alone.
                    contentPop.require(toFail: right)
                    configuredContentPopGesture = contentPop
                }
                return
            }
            responder = current.next
        }
    }

    private func removePageGestures() {
        pageSwipeLeft?.isEnabled = false
        pageSwipeRight?.isEnabled = false
        pageEdgeTap?.isEnabled = false
    }

    @objc private func handlePageSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard scrollMode == .pages else { return }
        // Don't steal an active text selection.
        guard textView.selectedRange.length == 0 else { return }
        switch gesture.direction {
        case .left:
            turnPage(by: 1, animated: true)
        case .right:
            turnPage(by: -1, animated: true)
        default:
            break
        }
    }

    @objc private func handlePageEdgeTap(_ gesture: UITapGestureRecognizer) {
        guard scrollMode == .pages, gesture.state == .ended else { return }
        guard textView.selectedRange.length == 0 else { return }
        let x = gesture.location(in: self).x
        guard let delta = ReaderPageGeometry.edgeTapDirection(x: x, width: bounds.width) else {
            return // center tap → SwiftUI chrome toggle
        }
        turnPage(by: delta, animated: true)
    }

    func turnPage(by delta: Int, animated: Bool) {
        guard scrollMode == .pages, delta != 0 else { return }
        textView.layoutIfNeeded()
        let ph = currentPageHeight()
        let maxY = ReaderPageGeometry.maxOffsetY(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let current = ReaderPageGeometry.pageIndex(offsetY: textView.contentOffset.y, pageHeight: ph)
        let target = ReaderPageGeometry.offsetY(
            forPage: current + delta,
            pageHeight: ph,
            maxOffsetY: maxY
        )
        guard abs(target - textView.contentOffset.y) > 0.5 else { return }
        textView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        scheduleSettleCallback(delay: animated ? 0.28 : 0.05)
    }

    func snapToNearestPage(animated: Bool) {
        guard scrollMode == .pages else { return }
        textView.layoutIfNeeded()
        let ph = currentPageHeight()
        let maxY = ReaderPageGeometry.maxOffsetY(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let page = ReaderPageGeometry.pageIndex(offsetY: textView.contentOffset.y, pageHeight: ph)
        let target = ReaderPageGeometry.offsetY(forPage: page, pageHeight: ph, maxOffsetY: maxY)
        if abs(target - textView.contentOffset.y) > 0.5 {
            textView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        }
        lastPagedViewportHeight = textView.bounds.height
        scheduleSettleCallback(delay: animated ? 0.28 : 0.05)
    }

    private func snapToPageContaining(contentY: CGFloat, animated: Bool) {
        guard scrollMode == .pages else { return }
        let ph = currentPageHeight()
        let maxY = ReaderPageGeometry.maxOffsetY(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let page = ReaderPageGeometry.pageIndexContaining(contentY: contentY, pageHeight: ph)
        let target = ReaderPageGeometry.offsetY(forPage: page, pageHeight: ph, maxOffsetY: maxY)
        textView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        lastPagedViewportHeight = textView.bounds.height
        scheduleSettleCallback(delay: animated ? 0.28 : 0.05)
    }

    private func currentPageHeight() -> CGFloat {
        ReaderPageGeometry.pageHeight(viewportHeight: textView.bounds.height)
    }

    private func scheduleSettleCallback(delay: TimeInterval) {
        settleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onScrollSettled?(self.visibleUtf16Location(), self.visibleProgress())
            self.publishPageState()
        }
        settleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func goToPage(indexZeroBased: Int, animated: Bool) {
        guard scrollMode == .pages else { return }
        textView.layoutIfNeeded()
        let ph = currentPageHeight()
        let maxY = ReaderPageGeometry.maxOffsetY(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let count = ReaderPageGeometry.pageCount(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let clamped = min(max(0, indexZeroBased), max(0, count - 1))
        let target = ReaderPageGeometry.offsetY(forPage: clamped, pageHeight: ph, maxOffsetY: maxY)
        textView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        lastPagedViewportHeight = textView.bounds.height
        scheduleSettleCallback(delay: animated ? 0.28 : 0.05)
    }

    func currentPageChromeState() -> ReaderPageChromeState {
        textView.layoutIfNeeded()
        let ph = currentPageHeight()
        let count = ReaderPageGeometry.pageCount(
            contentHeight: textView.contentSize.height,
            viewportHeight: textView.bounds.height
        )
        let index = ReaderPageGeometry.pageIndex(offsetY: textView.contentOffset.y, pageHeight: ph)
        return ReaderPageChromeState(index: min(index, max(0, count - 1)), count: count)
    }

    private func publishPageState() {
        guard scrollMode == .pages else { return }
        onPageStateChange?(currentPageChromeState())
    }

    func setPersistentHighlights(_ ranges: [(NSRange, UIColor)]) {
        persistentHighlightRanges = ranges
        reapplyOverlays()
    }

    func scrollToUtf16Location(_ location: Int, animated: Bool) {
        scrollToUtf16Location(location, animated: animated, restoringCheckpoint: false)
    }

    /// Resume at the reading point used to save a checkpoint. Contextual jumps
    /// place text farther down the screen and would save an earlier location.
    func restoreToUtf16Location(_ location: Int) {
        scrollToUtf16Location(location, animated: false, restoringCheckpoint: true)
    }

    private var readingPointInset: CGFloat { textView.textContainerInset.top + 8 }

    private func scrollToUtf16Location(_ location: Int, animated: Bool, restoringCheckpoint: Bool) {
        let length = textView.attributedText?.length ?? 0
        guard length > 0 else { return }
        let clamped = min(max(0, location), length - 1)
        textView.layoutIfNeeded()
        // Offscreen TextKit 2 coordinates may include estimated paragraph heights.
        // Resolve the prefix through this anchor before choosing a scroll offset;
        // ordinary scrolling does not force layout of the document prefix.
        if let layout = textView.textLayoutManager,
           let content = layout.textContentManager,
           let end = content.location(content.documentRange.location, offsetBy: clamped + 1),
           let prefix = NSTextRange(location: content.documentRange.location, end: end) {
            layout.ensureLayout(for: prefix)
        }
        if clamped == 0 {
            // The document start has an exact offset. Animating a glyph rect
            // while TextKit refines a long book's height can leave a residual
            // offset, hiding the first line after a chapter-start jump.
            textView.setContentOffset(.zero, animated: false)
            scheduleSettleCallback(delay: 0.05)
            return
        }
        if let start = textView.position(from: textView.beginningOfDocument, offset: clamped),
           let end = textView.position(from: start, offset: 1),
           let textRange = textView.textRange(from: start, to: end) {
            let rect = textView.firstRect(for: textRange)
            if !rect.isNull && !rect.isInfinite {
                if scrollMode == .pages {
                    // Bring the target onto a snapped page (top of page containing the glyph).
                    snapToPageContaining(contentY: rect.origin.y, animated: animated)
                } else {
                    let inset = restoringCheckpoint ? readingPointInset : textView.bounds.height * 0.18
                    // Hit testing on a line's top edge can choose the preceding line.
                    // Put the saved glyph's vertical center at the checkpoint probe.
                    let anchorY = restoringCheckpoint ? rect.midY : rect.minY
                    let targetY = max(0, anchorY - inset)
                    textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
                }
                return
            }
        }
        if scrollMode == .pages {
            // Fallback: enable scroll briefly to use TextKit range scrolling, then snap.
            let wasEnabled = textView.isScrollEnabled
            textView.isScrollEnabled = true
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 1))
            textView.isScrollEnabled = wasEnabled
            snapToNearestPage(animated: animated)
        } else {
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 1))
        }
    }

    func visibleUtf16Location() -> Int {
        textView.layoutIfNeeded()
        let point = CGPoint(
            x: textView.bounds.midX,
            y: textView.contentOffset.y + readingPointInset
        )
        if let pos = textView.closestPosition(to: point) {
            return textView.offset(from: textView.beginningOfDocument, to: pos)
        }
        return 0
    }

    func visibleProgress() -> Double {
        let maxY = max(1, textView.contentSize.height - textView.bounds.height)
        return min(1, max(0, Double(textView.contentOffset.y / maxY)))
    }

    func highlightSearch(range: NSRange?) {
        searchRange = range
        reapplyOverlays()
    }

    private func reapplyOverlays() {
        guard let base = baseAttributedText else { return }
        let mutable = NSMutableAttributedString(attributedString: base)
        for (range, color) in persistentHighlightRanges {
            if NSMaxRange(range) <= mutable.length {
                mutable.addAttributes([.backgroundColor: color], range: range)
            }
        }
        if let searchRange, NSMaxRange(searchRange) <= mutable.length {
            mutable.addAttributes([
                .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.45)
            ], range: searchRange)
        }
        textView.attributedText = mutable
    }

    var contentHeight: CGFloat { textView.contentSize.height }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scheduleSettleCallback(delay: 0.18)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard scrollMode == .pages else { return }
        let height = textView.bounds.height
        guard height > 1 else { return }
        if abs(height - lastPagedViewportHeight) > 0.5 {
            snapToNearestPage(animated: false)
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let range = textView.selectedRange
        if range.length > 0 {
            onSelectionChanged?(range)
        } else {
            onSelectionChanged?(nil)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow page swipes alongside TextKit selection gestures.
        true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pageEdgeTap {
            let x = gestureRecognizer.location(in: self).x
            return ReaderPageGeometry.edgeTapDirection(x: x, width: bounds.width) != nil
        }
        return true
    }
}

struct TextKitReaderRepresentable: UIViewRepresentable {
    var document: ReaderDocument
    var typography: ReaderTypography
    var scrollMode: ReaderScrollMode = .scroll
    var restoreLocation: ReaderLocation?
    var searchHighlight: NSRange?
    var jumpToken: UUID?
    var jumpUtf16: Int?
    var jumpAnimated: Bool = true
    var pageJumpToken: UUID?
    var pageJumpIndex: Int?
    var documentEpoch: Int
    var persistentHighlights: [(NSRange, UIColor)]
    var highlightEpoch: Int
    /// Measured height of the bottom reading chrome (0 when hidden).
    var bottomChromeHeight: CGFloat = TextKitReaderUIView.bottomInset
    var onLocationChange: (ReaderLocation) -> Void
    var onSelectionChange: (NSRange?) -> Void
    var onPageStateChange: (ReaderPageChromeState) -> Void = { _ in }
    var onTapAtOffset: (Int) -> Void = { _ in }

    func makeUIView(context: Context) -> TextKitReaderUIView {
        let view = ReaderRendererFactory.makeTextKitView()
        context.coordinator.bind(
            view: view,
            document: document,
            onLocationChange: onLocationChange,
            onSelectionChange: onSelectionChange
        )
        return view
    }

    func updateUIView(_ uiView: TextKitReaderUIView, context: Context) {
        context.coordinator.bind(
            view: uiView,
            document: document,
            onLocationChange: onLocationChange,
            onSelectionChange: onSelectionChange
        )
        uiView.apply(typographyBackground: typography.backgroundColor)
        uiView.applyInsets(horizontal: typography.horizontalInset, bottomChrome: bottomChromeHeight)
        let effectiveMode = ReaderScrollMode.effective(
            scrollMode,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning
        )
        uiView.apply(scrollMode: effectiveMode)
        uiView.onPageStateChange = onPageStateChange
        uiView.onTapAtUtf16Offset = onTapAtOffset

        if context.coordinator.lastDocumentEpoch != documentEpoch {
            context.coordinator.lastDocumentEpoch = documentEpoch
            uiView.apply(document: document)
            uiView.setPersistentHighlights(persistentHighlights)
            context.coordinator.lastHighlightEpoch = highlightEpoch
            uiView.highlightSearch(range: searchHighlight)
            context.coordinator.lastHighlight = searchHighlight
        } else {
            if context.coordinator.lastHighlightEpoch != highlightEpoch {
                context.coordinator.lastHighlightEpoch = highlightEpoch
                uiView.setPersistentHighlights(persistentHighlights)
            }
            if context.coordinator.lastHighlight != searchHighlight {
                uiView.highlightSearch(range: searchHighlight)
                context.coordinator.lastHighlight = searchHighlight
            }
        }

        if context.coordinator.lastJumpToken != jumpToken, let jumpUtf16 {
            context.coordinator.lastJumpToken = jumpToken
            // An explicit navigation request supersedes the launch checkpoint.
            // A later update must not replay that older restoration over the jump.
            context.coordinator.didRestore = true
            let animated = jumpAnimated
            DispatchQueue.main.async {
                uiView.scrollToUtf16Location(jumpUtf16, animated: animated)
            }
        } else if !context.coordinator.didRestore, let restoreLocation,
                  let utf16 = document.utf16Location(for: restoreLocation) {
            context.coordinator.didRestore = true
            DispatchQueue.main.async {
                uiView.restoreToUtf16Location(utf16)
            }
        }

        if context.coordinator.lastPageJumpToken != pageJumpToken, let pageJumpIndex {
            context.coordinator.lastPageJumpToken = pageJumpToken
            DispatchQueue.main.async {
                uiView.goToPage(indexZeroBased: pageJumpIndex, animated: true)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didRestore = false
        var lastJumpToken: UUID?
        var lastPageJumpToken: UUID?
        var lastDocumentEpoch: Int = -1
        var lastHighlightEpoch: Int = -1
        var lastHighlight: NSRange?

        func bind(
            view: TextKitReaderUIView,
            document: ReaderDocument,
            onLocationChange: @escaping (ReaderLocation) -> Void,
            onSelectionChange: @escaping (NSRange?) -> Void
        ) {
            view.onScrollSettled = { utf16, _ in
                // UTF-16 fraction, not viewport offset — same space the scrubber commits into.
                if let location = document.location(atUtf16: utf16) {
                    onLocationChange(location)
                }
            }
            view.onSelectionChanged = { range in
                onSelectionChange(range)
            }
        }
    }
}
