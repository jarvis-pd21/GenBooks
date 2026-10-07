import SwiftUI
import UIKit

/// Kept in memory for one open reader, never in saved reading preferences.
struct ReaderOrientationPolicy {
    private(set) var isReaderActive = false
    private(set) var lockedOrientation: UIInterfaceOrientation?

    var supportedOrientations: UIInterfaceOrientationMask {
        guard isReaderActive else { return .portrait }
        return lockedOrientation.flatMap(Self.mask) ?? .allButUpsideDown
    }

    mutating func enterReader() {
        isReaderActive = true
        lockedOrientation = nil
    }

    @discardableResult
    mutating func lock(to orientation: UIInterfaceOrientation) -> Bool {
        guard isReaderActive, Self.mask(orientation) != nil else { return false }
        lockedOrientation = orientation
        return true
    }

    mutating func unlock() { lockedOrientation = nil }

    mutating func leaveReader() {
        lockedOrientation = nil
        isReaderActive = false
    }

    private static func mask(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}

@MainActor
protocol ReaderOrientationGeometryControlling: AnyObject {
    var currentOrientation: UIInterfaceOrientation { get }
    func invalidateSupportedOrientations()
    func requestOrientations(_ orientations: UIInterfaceOrientationMask, onFailure: @escaping @MainActor () -> Void)
}

@MainActor
final class ReaderOrientationController: ObservableObject {
    static let shared = ReaderOrientationController()

    @Published private(set) var policy = ReaderOrientationPolicy()
    @Published private(set) var notice: String?
    private weak var readerScene: UIWindowScene?
    private var readerOwner: UUID?
    private var geometry: (any ReaderOrientationGeometryControlling)?
    private var requestGeneration: UInt64 = 0

    var isLocked: Bool { policy.lockedOrientation != nil }
    var isAvailable: Bool { policy.isReaderActive && geometry != nil }
    var orientationDescription: String {
        switch policy.lockedOrientation {
        case .portrait: "Locked in portrait"
        case .landscapeLeft, .landscapeRight: "Locked in landscape"
        default: "Reader rotation unlocked"
        }
    }

    func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let readerScene else { return .portrait }
        // UIKit may query the application mask without specifying a window.
        guard window == nil || window?.windowScene === readerScene else { return .portrait }
        return policy.supportedOrientations
    }

    func attach(to scene: UIWindowScene, owner: UUID) {
        guard readerOwner != owner || readerScene !== scene else { return }
        readerScene = scene
        enterReader(owner: owner, geometry: SceneOrientationGeometry(scene: scene))
    }

    // Injectable geometry makes system denials and delayed errors testable offline.
    func enterReader(owner: UUID, geometry: any ReaderOrientationGeometryControlling) {
        guard readerOwner != owner || self.geometry !== geometry else { return }
        readerOwner = owner
        self.geometry = geometry
        policy.enterReader()
        requestUpdate(lockRequested: false)
    }

    func setLocked(_ locked: Bool) {
        guard let geometry, isAvailable, locked != isLocked else { return }
        if locked {
            guard policy.lock(to: geometry.currentOrientation) else {
                notice = "The screen orientation is not ready. Hold your iPhone upright or sideways and try again."
                return
            }
        } else {
            policy.unlock()
        }
        requestUpdate(lockRequested: locked)
    }

    private func requestUpdate(lockRequested: Bool) {
        guard let geometry else { return }
        notice = nil
        requestGeneration &+= 1
        let generation = requestGeneration
        geometry.invalidateSupportedOrientations()
        geometry.requestOrientations(policy.supportedOrientations) { [weak self] in
            guard let self, self.requestGeneration == generation, self.policy.isReaderActive else { return }
            // A denied rotation must not leave a falsely-on or sticky session lock.
            self.policy.unlock()
            self.geometry?.invalidateSupportedOrientations()
            self.notice = lockRequested
                ? "iOS could not apply the lock. Rotation is unlocked; close this sheet and try again."
                : "Rotation is unlocked, but iOS did not rotate the screen. Turn your iPhone again."
        }
    }

    func leaveReader(owner: UUID) {
        guard readerOwner == owner else { return }
        requestGeneration &+= 1
        let oldGeometry = geometry
        policy.leaveReader()
        notice = nil
        readerOwner = nil
        readerScene = nil
        geometry = nil
        oldGeometry?.invalidateSupportedOrientations()
        // Restore the existing Library policy. A navigation-time denial cannot
        // retain the reader mask: future rotations already query portrait above.
        oldGeometry?.requestOrientations(.portrait, onFailure: {})
    }
}

@MainActor
private final class SceneOrientationGeometry: ReaderOrientationGeometryControlling {
    private weak var scene: UIWindowScene?
    init(scene: UIWindowScene) { self.scene = scene }
    var currentOrientation: UIInterfaceOrientation { scene?.interfaceOrientation ?? .unknown }

    func invalidateSupportedOrientations() {
        for window in scene?.windows ?? [] {
            if let root = window.rootViewController { invalidate(root) }
        }
    }

    func requestOrientations(_ orientations: UIInterfaceOrientationMask, onFailure: @escaping @MainActor () -> Void) {
        guard let scene else { onFailure(); return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in
            Task { @MainActor in onFailure() }
        }
    }

    private func invalidate(_ controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children { invalidate(child) }
        if let presented = controller.presentedViewController { invalidate(presented) }
    }
}

@MainActor
final class LivingReaderAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderOrientationController.shared.supportedOrientations(for: window)
    }
}

/// Attaches to the reader's actual scene. Presenting settings does not end the
/// session; SwiftUI dismantles this bridge when the reader leaves navigation.
struct ReaderOrientationObserver: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> OrientationObserverViewController {
        OrientationObserverViewController()
    }
    func updateUIViewController(_ controller: OrientationObserverViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: OrientationObserverViewController, coordinator: ()) {
        ReaderOrientationController.shared.leaveReader(owner: controller.owner)
    }
}

@MainActor
final class OrientationObserverViewController: UIViewController {
    let owner = UUID()
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let scene = view.window?.windowScene else { return }
        ReaderOrientationController.shared.attach(to: scene, owner: owner)
    }
}
