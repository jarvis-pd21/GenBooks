import XCTest
import UIKit
@testable import LivingReader

@MainActor
final class ReaderOrientationTests: XCTestCase {
    func testInactivePolicyKeepsLibraryPortraitAndCannotLock() {
        var policy = ReaderOrientationPolicy()

        XCTAssertFalse(policy.isReaderActive)
        XCTAssertNil(policy.lockedOrientation)
        XCTAssertEqual(policy.supportedOrientations, .portrait)
        XCTAssertFalse(policy.lock(to: .landscapeLeft))
        XCTAssertNil(policy.lockedOrientation)
    }

    func testEnteringReaderStartsUnlockedAndAllowsPortraitAndBothLandscapes() {
        let controller = ReaderOrientationController()
        let geometry = GeometrySpy()

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(controller.notice)
        controller.enterReader(owner: UUID(), geometry: geometry)

        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.policy.isReaderActive)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
        XCTAssertEqual(geometry.requests.last?.mask, .allButUpsideDown)
        XCTAssertGreaterThan(geometry.invalidations, 0)
    }

    func testLockCapturesEachActualInterfaceOrientation() {
        let cases: [(UIInterfaceOrientation, UIInterfaceOrientationMask)] = [
            (.portrait, .portrait),
            (.landscapeLeft, .landscapeLeft),
            (.landscapeRight, .landscapeRight)
        ]
        for (orientation, mask) in cases {
            let controller = ReaderOrientationController()
            let geometry = GeometrySpy(orientation: orientation)
            controller.enterReader(owner: UUID(), geometry: geometry)

            controller.setLocked(true)

            XCTAssertTrue(controller.isLocked, "Orientation: \(orientation.rawValue)")
            XCTAssertEqual(controller.policy.lockedOrientation, orientation)
            XCTAssertEqual(controller.policy.supportedOrientations, mask)
            XCTAssertEqual(geometry.requests.last?.mask, mask)
            XCTAssertNil(controller.notice)

            // Physical rotation cannot silently change the captured interface lock.
            geometry.currentOrientation = orientation == .portrait ? .landscapeLeft : .portrait
            controller.setLocked(true)
            XCTAssertEqual(controller.policy.supportedOrientations, mask)
        }
    }

    func testUnknownAndUnsupportedOrientationsDoNotInventALock() {
        for orientation in [UIInterfaceOrientation.unknown, .portraitUpsideDown] {
            let controller = ReaderOrientationController()
            let geometry = GeometrySpy(orientation: orientation)
            controller.enterReader(owner: UUID(), geometry: geometry)
            let requestCount = geometry.requests.count

            controller.setLocked(true)

            XCTAssertFalse(controller.isLocked)
            XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
            XCTAssertEqual(geometry.requests.count, requestCount)
            XCTAssertNotNil(controller.notice)
        }
    }

    func testUnlockRemovesTheExactLockWithoutEndingReaderSession() {
        let controller = ReaderOrientationController()
        let geometry = GeometrySpy(orientation: .landscapeRight)
        controller.enterReader(owner: UUID(), geometry: geometry)
        controller.setLocked(true)

        controller.setLocked(false)

        XCTAssertTrue(controller.isAvailable)
        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(controller.policy.lockedOrientation)
        XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
        XCTAssertEqual(geometry.requests.last?.mask, .allButUpsideDown)
        XCTAssertNil(controller.notice)
    }

    func testPolicyKeepsCapturedLockUntilExplicitUnlockOrSessionReset() {
        var policy = ReaderOrientationPolicy()
        policy.enterReader()
        XCTAssertTrue(policy.lock(to: .landscapeLeft))

        XCTAssertFalse(policy.lock(to: .unknown))
        XCTAssertEqual(policy.lockedOrientation, .landscapeLeft)
        XCTAssertEqual(policy.supportedOrientations, .landscapeLeft)

        policy.unlock()
        XCTAssertNil(policy.lockedOrientation)
        XCTAssertEqual(policy.supportedOrientations, .allButUpsideDown)
        XCTAssertTrue(policy.lock(to: .portrait))
        policy.leaveReader()
        XCTAssertFalse(policy.isReaderActive)
        XCTAssertNil(policy.lockedOrientation)
        XCTAssertEqual(policy.supportedOrientations, .portrait)
        policy.enterReader()
        XCTAssertNil(policy.lockedOrientation)
        XCTAssertEqual(policy.supportedOrientations, .allButUpsideDown)
    }

    func testSameOwnerAndGeometryReattachmentPreservesExistingLock() {
        let controller = ReaderOrientationController()
        let owner = UUID()
        let geometry = GeometrySpy(orientation: .landscapeLeft)
        controller.enterReader(owner: owner, geometry: geometry)
        controller.setLocked(true)
        let requestCount = geometry.requests.count

        controller.enterReader(owner: owner, geometry: geometry)

        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.policy.lockedOrientation, .landscapeLeft)
        XCTAssertEqual(controller.policy.supportedOrientations, .landscapeLeft)
        XCTAssertEqual(geometry.requests.count, requestCount)
    }

    func testLeavingReaderRestoresLibraryPortraitAndReopeningStartsUnlocked() {
        let controller = ReaderOrientationController()
        let owner = UUID()
        let geometry = GeometrySpy(orientation: .landscapeLeft)
        controller.enterReader(owner: owner, geometry: geometry)
        controller.setLocked(true)

        controller.leaveReader(owner: owner)

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(controller.policy.isReaderActive)
        XCTAssertEqual(controller.policy.supportedOrientations, .portrait)
        XCTAssertEqual(geometry.requests.last?.mask, .portrait)
        XCTAssertNil(controller.notice)

        controller.enterReader(owner: UUID(), geometry: geometry)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
        XCTAssertNil(ReaderOrientationController().policy.lockedOrientation)
    }

    func testOldOwnerCleanupCannotEndANewerReaderSession() {
        let controller = ReaderOrientationController()
        let oldOwner = UUID()
        let newOwner = UUID()
        let oldGeometry = GeometrySpy(orientation: .portrait)
        let newGeometry = GeometrySpy(orientation: .landscapeRight)
        controller.enterReader(owner: oldOwner, geometry: oldGeometry)
        controller.setLocked(true)
        controller.enterReader(owner: newOwner, geometry: newGeometry)
        XCTAssertFalse(controller.isLocked)
        controller.setLocked(true)
        let currentRequestCount = newGeometry.requests.count

        controller.leaveReader(owner: oldOwner)

        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.policy.lockedOrientation, .landscapeRight)
        XCTAssertEqual(newGeometry.requests.count, currentRequestCount)
    }

    func testDeniedLockReleasesLockAndExplainsFailure() throws {
        let controller = ReaderOrientationController()
        let geometry = GeometrySpy()
        controller.enterReader(owner: UUID(), geometry: geometry)
        controller.setLocked(true)
        let request = try XCTUnwrap(geometry.requests.last)
        let previousInvalidations = geometry.invalidations

        request.onFailure()

        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
        XCTAssertGreaterThan(geometry.invalidations, previousInvalidations)
        XCTAssertFalse(try XCTUnwrap(controller.notice).isEmpty)
    }

    func testDeniedImmediateUnlockRotationDoesNotReinstateStickyLock() throws {
        let controller = ReaderOrientationController()
        let geometry = GeometrySpy(orientation: .landscapeLeft)
        controller.enterReader(owner: UUID(), geometry: geometry)
        controller.setLocked(true)
        controller.setLocked(false)
        let request = try XCTUnwrap(geometry.requests.last)

        request.onFailure()

        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.policy.supportedOrientations, .allButUpsideDown)
        XCTAssertFalse(try XCTUnwrap(controller.notice).isEmpty)
    }

    func testLateFailureCannotUndoNewerOrientationRequest() throws {
        let controller = ReaderOrientationController()
        let geometry = GeometrySpy(orientation: .portrait)
        controller.enterReader(owner: UUID(), geometry: geometry)
        controller.setLocked(true)
        let oldLockRequest = try XCTUnwrap(geometry.requests.last)
        controller.setLocked(false)
        let oldUnlockRequest = try XCTUnwrap(geometry.requests.last)
        geometry.currentOrientation = .landscapeRight
        controller.setLocked(true)

        oldLockRequest.onFailure()
        oldUnlockRequest.onFailure()

        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.policy.lockedOrientation, .landscapeRight)
        XCTAssertNil(controller.notice)
    }

    func testLateFailureAfterExitOrNewOwnerCannotRestoreOldSession() throws {
        let controller = ReaderOrientationController()
        let oldOwner = UUID()
        let geometry = GeometrySpy()
        controller.enterReader(owner: oldOwner, geometry: geometry)
        controller.setLocked(true)
        let oldRequest = try XCTUnwrap(geometry.requests.last)
        controller.leaveReader(owner: oldOwner)

        oldRequest.onFailure()
        XCTAssertFalse(controller.isAvailable)
        XCTAssertEqual(controller.policy.supportedOrientations, .portrait)
        XCTAssertNil(controller.notice)

        let newGeometry = GeometrySpy(orientation: .landscapeLeft)
        controller.enterReader(owner: UUID(), geometry: newGeometry)
        controller.setLocked(true)
        oldRequest.onFailure()

        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.policy.lockedOrientation, .landscapeLeft)
        XCTAssertNil(controller.notice)
    }

    @MainActor
    private final class GeometrySpy: ReaderOrientationGeometryControlling {
        struct Request {
            let mask: UIInterfaceOrientationMask
            let onFailure: @MainActor () -> Void
        }

        var currentOrientation: UIInterfaceOrientation
        private(set) var invalidations = 0
        private(set) var requests: [Request] = []

        init(orientation: UIInterfaceOrientation = .portrait) {
            currentOrientation = orientation
        }

        func invalidateSupportedOrientations() {
            invalidations += 1
        }

        func requestOrientations(
            _ orientations: UIInterfaceOrientationMask,
            onFailure: @escaping @MainActor () -> Void
        ) {
            requests.append(Request(mask: orientations, onFailure: onFailure))
        }
    }
}
