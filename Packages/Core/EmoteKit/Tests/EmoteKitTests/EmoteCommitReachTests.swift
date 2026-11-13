import QuartzCore
import Synchronization
import Testing
import UIKit
@testable import EmoteKit

/// What a Core Animation commit lays out, measured on iOS 27.2 (2026-11-13),
/// for #1603's probe (`EmoteOffMainLayoutProbe`).
///
/// - A commit made on a background thread does NOT lay out a view the main
///   thread marked in a window. That pending layout belongs to the main
///   thread's transaction, and the main thread's commit lays it out.
/// - A tree in no window is laid out by no commit at all, on any thread. A
///   navigation controller that outlives its window keeps a pending floating
///   bar forever, and that is harmless.
///
/// If an iOS update flips either one, the park's reasoning in
/// `EmoteMainPark` changes, and this fails first.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteCommitReachTests {
    final class Witness: UIView {
        let onMain = Atomic<Int>(0)
        let offMain = Atomic<Int>(0)

        override func layoutSubviews() {
            super.layoutSubviews()
            if Thread.isMainThread {
                onMain.add(1, ordering: .relaxed)
            } else {
                offMain.add(1, ordering: .relaxed)
            }
        }

        var layouts: (onMain: Int, offMain: Int) {
            (onMain.load(ordering: .relaxed), offMain.load(ordering: .relaxed))
        }
    }

    /// Commits a transaction of its own on a background thread, while the main
    /// thread waits (so the main thread commits nothing in between).
    static func commitOnABackgroundThread() {
        DispatchQueue.global(qos: .userInitiated).sync {
            CATransaction.begin()
            let own = CALayer()
            own.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
            CATransaction.commit()
        }
    }

    @Test func aBackgroundCommitLaysOutNothingTheMainThreadMarked() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let witness = Witness(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        window.addSubview(witness)
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        let before = witness.layouts

        witness.setNeedsLayout()
        Self.commitOnABackgroundThread()

        #expect(witness.layouts.offMain == 0, "a background commit laid out the main thread's mark")
        #expect(witness.layer.needsLayout(), "the mark is still the main thread's to lay out")

        // The main thread's own turn lays it out.
        try await Task.sleep(for: .milliseconds(100))
        #expect(witness.layouts.onMain > before.onMain)
        #expect(!witness.layer.needsLayout())
    }

    @Test func aTreeInNoWindowIsLaidOutByNoCommit() async throws {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let witness = Witness(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        root.addSubview(witness)
        root.layoutIfNeeded()
        let before = witness.layouts

        witness.setNeedsLayout()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        Self.commitOnABackgroundThread()

        #expect(witness.layouts.onMain == before.onMain, "the main thread's commit laid out a tree in no window")
        #expect(witness.layouts.offMain == 0, "a background commit laid out a tree in no window")
        #expect(witness.layer.needsLayout())
        withExtendedLifetime(root) {}
    }
}
