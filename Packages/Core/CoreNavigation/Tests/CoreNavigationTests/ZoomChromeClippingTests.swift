import Testing
import UIKit
@testable import CoreNavigation

/// #539: the destination's chrome replica rides inside the card's CLIPPING
/// container, so its legibility scrim can never draw past the window's
/// rounded corners — a pin's root clips nothing (its ring overhangs).
@MainActor
struct ZoomChromeClippingTests {
    private let pageFrame = CGRect(x: 0, y: 0, width: 402, height: 874)

    @Test func theReplicaRidesTheCardsClippingContainer() throws {
        let card = OverhangingCard()
        let built = ZoomFlight.build(
            source: ClipSource(card: card), destination: ClipDestination(),
            sourceFrame: CGRect(x: 40, y: 300, width: 64, height: 64), pageFrame: pageFrame
        )
        let chrome = try #require(built.chrome)
        #expect(chrome.superview === card.contentView, "inside the clipping content view, not the card's root")
        #expect(card.contentView.clipsToBounds)
        // The resting chrome lives on the root above the content view, so the
        // replica stays under it — the source end still reads as the source's.
        let root = card.subviews
        let contentIndex = try #require(root.firstIndex(of: card.contentView))
        let restingIndex = try #require(root.firstIndex(of: card.restingChromeView))
        #expect(contentIndex < restingIndex)
        #expect(chrome.bounds.size == pageFrame.size, "posed in the card's own coordinate space")
    }

    /// A card that clips at its root keeps the old placement: below its
    /// resting chrome, on the card itself.
    @Test func aCardWithoutAContainerKeepsTheReplicaOnItself() throws {
        let card = ClippingCard()
        let built = ZoomFlight.build(
            source: ClipSource(card: card), destination: ClipDestination(),
            sourceFrame: CGRect(x: 40, y: 300, width: 64, height: 64), pageFrame: pageFrame
        )
        let chrome = try #require(built.chrome)
        #expect(chrome.superview === card)
        let index = try #require(card.subviews.firstIndex(of: chrome))
        let restingIndex = try #require(card.subviews.firstIndex(of: card.restingChromeView))
        #expect(index < restingIndex, "below the resting chrome")
    }
}

// MARK: - Stage doubles

/// Like the map's pin: the root lets furniture overhang and clips nothing;
/// a rounded content view clips; the resting chrome sits on the root above it.
private final class OverhangingCard: UIView, ZoomFlightCard {
    let contentView = UIView()
    let restingChromeView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = true
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)
        addSubview(restingChromeView)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { restingChromeView }
    var zoomChromeContainer: UIView { contentView }
    func setZoomCornerRadius(_ radius: CGFloat) {
        layer.cornerRadius = radius
        contentView.layer.cornerRadius = radius
    }
}

/// A card that clips at its root and names no container.
private final class ClippingCard: UIView, ZoomFlightCard {
    let restingChromeView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(restingChromeView)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var zoomRestingCornerRadius: CGFloat { 12 }
    var zoomRestingChrome: UIView? { restingChromeView }
    func setZoomCornerRadius(_ radius: CGFloat) { layer.cornerRadius = radius }
}

private final class ClipSource: NSObject, ZoomTransitionSource {
    private let card: any ZoomFlightCard
    init(card: any ZoomFlightCard) { self.card = card }
    func zoomHeroFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    var zoomSourceIsOnScreen: Bool { true }
    func makeZoomFlightCard() -> any ZoomFlightCard { card }
    func setZoomSourceHidden(_ hidden: Bool) {}
}

private final class ClipDestination: NSObject, ZoomTransitionDestination {
    func zoomTargetFrame(in container: UICoordinateSpace) -> CGRect { .zero }
    func zoomFlightChrome() -> UIView? { UIView() }
    func setZoomContentHidden(_ hidden: Bool) {}
    func zoomTransitionDidEnd() {}
    var isReadyForInteractiveDismissal: Bool { true }
    func setContentScrollEnabled(_ enabled: Bool) {}
}
