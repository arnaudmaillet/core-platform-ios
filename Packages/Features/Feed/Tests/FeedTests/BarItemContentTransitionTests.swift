import Testing
import UIKit
@testable import Feed

/// THE BAR PILLS' CONTENT BLURS ACROSS, INSIDE ONE ITEM.
///
/// `BarItemContentTransition` is what replaced iOS 26's native item morph for
/// the feed's author pill and audio capsule: the old content fades into a
/// blurred still of itself, the change is applied at the midpoint, and the new
/// content comes back sharp out of a blurred still of ITSELF. These pin the
/// timeline's contract — when the change lands, what is on the host meanwhile,
/// and that nothing is left behind.
@MainActor
struct BarItemContentTransitionTests {
    /// A host with one label in an edge-pinned content container — the pills'
    /// own structure.
    @MainActor
    private final class Host {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 36))
        let content = UIView()
        let label = UILabel()
        let transition: BarItemContentTransition

        init() {
            content.frame = view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(content)
            label.text = "Old"
            label.frame = content.bounds
            content.addSubview(label)
            transition = BarItemContentTransition(host: view, content: content)
        }

        /// The stills: whatever the transition added to the host beside the
        /// content.
        var stills: [UIView] { view.subviews.filter { $0 !== content } }
    }

    private static func window(showing host: Host) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.addSubview(host.view)
        window.isHidden = false
        return window
    }

    private static func settle(_ host: Host) async throws {
        for _ in 0..<200 where host.transition.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Off screen there is nothing to see: the change lands in this turn.
    @Test func anOffscreenChangeLandsAtOnce() {
        let host = Host()
        var applied = 0
        host.transition.didApply = { applied += 1 }

        host.transition.perform(animated: true) { host.label.text = "New" }

        #expect(host.label.text == "New")
        #expect(applied == 1)
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
        #expect(host.transition.isRunning == false)
    }

    /// On screen the OLD content is what fades: the change waits for the
    /// midpoint, and the content is left sharp and alone at the end.
    @Test func anOnScreenChangeLandsAtTheMidpointAndLeavesNothingBehind() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }

        #expect(host.label.text == "Old", "the change landed before the old content had faded")
        #expect(host.transition.isRunning)
        #expect(host.content.alpha == 0, "the live content is not the thing fading out")
        if !UIAccessibility.isReduceMotionEnabled {
            #expect(host.stills.count == 1, "no blurred still of the old content")
        }

        try await Self.settle(host)

        #expect(host.label.text == "New")
        #expect(host.stills.isEmpty, "a still outlived its transition")
        #expect(host.content.alpha == 1)
    }

    /// Everything asked for while the old content fades lands in ONE swap —
    /// how a new author and their follow badge arrive together.
    @Test func changesAskedForDuringTheFadeLandInOneSwap() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }
        var applied = 0
        host.transition.didApply = { applied += 1 }

        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.perform(animated: true) { host.label.textAlignment = .right }
        try await Self.settle(host)

        #expect(host.label.text == "New")
        #expect(host.label.textAlignment == .right)
        #expect(applied == 1)
    }

    /// A late arrival for the new content (a fetched face) waits for the swap
    /// rather than landing on the old content mid-fade.
    @Test func aLateArrivalWaitsForTheSwap() async throws {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }
        var order: [String] = []
        host.transition.afterSwap { order.append(host.label.text ?? "") }
        #expect(order.isEmpty)
        try await Self.settle(host)

        #expect(order == ["New"])
    }

    /// Interrupted, a transition jumps to its end: the pending change applied,
    /// no still left, the content opaque.
    @Test func finishJumpsToTheEnd() {
        let host = Host()
        let window = Self.window(showing: host)
        defer { window.isHidden = true }

        host.transition.perform(animated: true) { host.label.text = "New" }
        host.transition.finish()

        #expect(host.label.text == "New")
        #expect(host.stills.isEmpty)
        #expect(host.content.alpha == 1)
        #expect(host.transition.isRunning == false)
    }

    /// The still is the view's bounds grown by the blur's reach, so the blur
    /// fades out instead of being cut at the view's edge.
    @Test func theStillCoversTheBlursReach() throws {
        let host = Host()
        let (image, frame) = try #require(
            BarItemContentTransition.blurredSnapshot(of: host.content, radius: 4)
        )

        #expect(frame.contains(host.content.bounds))
        #expect(frame.width > host.content.bounds.width)
        #expect(abs(image.size.width - frame.width) < 0.5)
        #expect(abs(image.size.height - frame.height) < 0.5)
    }
}
