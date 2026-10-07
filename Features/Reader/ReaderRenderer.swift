import Foundation
import UIKit

/// Abstraction over the continuous reading surface so TextKit can be replaced later
/// (e.g. TextKit 2 / custom layout) without rewriting chrome, checkpoints, or search.
@MainActor
protocol ContinuousReaderRendering: AnyObject {
    func apply(document: ReaderDocument)
    func apply(typographyBackground: UIColor)
    func scrollToUtf16Location(_ location: Int, animated: Bool)
    /// First fully-visible (or nearest) character index for checkpointing.
    func visibleUtf16Location() -> Int
    func visibleProgress() -> Double
    func highlightSearch(range: NSRange?)
    var contentHeight: CGFloat { get }
}

/// Default factory — swap implementation here when replacing the renderer.
enum ReaderRendererFactory {
    @MainActor
    static func makeTextKitView() -> TextKitReaderUIView {
        TextKitReaderUIView()
    }
}
