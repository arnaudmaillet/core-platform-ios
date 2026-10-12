import CacheKit
import QuartzCore
import UIKit

/// The kinds of feed list (#970). Every list is its own, with its own owner
/// and its own policy, even when two of them show the same posts.
public enum LookaheadListKind: String, Sendable, CaseIterable {
    /// The vertical full-screen feed: one post per screen, planned by item
    /// (+1 decoded, +2/+3 on disk), its next page asked by posts left.
    case verticalPages
    /// A mosaic or a grid of tiles: For You's, Discover's, a profile's, a
    /// search's, the sound sheet's.
    case grid
    /// A vertical list of cards: For You's Following list, a place's activity.
    case card
    /// A horizontal row: the Friends faces, the Following cards.
    case rail

    /// The axis the list scrolls along, the one its windows are measured on.
    public var axis: NSLayoutConstraint.Axis { self == .rail ? .horizontal : .vertical }
}

/// When a list asks for its next page (#970): one rule per kind, so every
/// list pages the same way and the numbers are tested in one place.
///
/// - Vertical feed: at 5 posts left or fewer (a page is 10).
/// - Grids, cards, rails: at 2 screens from the end (Texture's
///   `leadingScreensForBatching`), 3 while the viewer flings.
///
/// One page in flight per list is the view model's (`pagingLoad`,
/// `pageLoad`): it ignores a call while one is out. The page it fetches goes
/// to the LocalStore with its cursor (#893) and its posts to the EntityStore
/// (#896), one entity per post id whichever list carried it.
public enum LookaheadPaging {
    /// The vertical feed asks for its next page at this many posts left.
    public static let verticalPostsLeft = 5
    /// A grid, card list or rail asks this many screens from its end.
    public static let screensFromEnd: CGFloat = 2
    /// The same while flinging: a throw outruns two screens of lead.
    public static let flingScreensFromEnd: CGFloat = 3
    /// The lead before the first layout, when the viewport is still zero.
    public static let minimumLead: CGFloat = 800

    /// Whether the vertical feed, settled on `index` of `count` posts, asks
    /// for the next page.
    public static func wantsNextPage(index: Int, count: Int) -> Bool {
        count > 0 && index >= count - verticalPostsLeft
    }

    /// Whether a list with `remaining` points of content past its viewport
    /// (`viewportLength` long) asks for the next page.
    public static func wantsNextPage(remaining: CGFloat, viewportLength: CGFloat, isFlinging: Bool) -> Bool {
        remaining < lead(viewportLength: viewportLength, isFlinging: isFlinging)
    }

    /// How far from the end the next page is asked for, in points.
    public static func lead(viewportLength: CGFloat, isFlinging: Bool) -> CGFloat {
        max(minimumLead, viewportLength * (isFlinging ? flingScreensFromEnd : screensFromEnd))
    }
}

/// Reads a list's scroll speed and direction from its offsets, so a
/// lookahead tells a fling from a drag without the scroll view's gesture.
public struct ScrollVelocityTracker: Sendable {
    /// A pause longer than this starts the speed again from zero.
    static let restInterval: CFTimeInterval = 0.12

    /// Points per second along the axis; positive towards larger offsets.
    public private(set) var velocity: CGFloat = 0
    /// Whether the last move was towards larger offsets (down, or right).
    public private(set) var isForward = true
    private var last: (offset: CGFloat, time: CFTimeInterval)?

    public init() {}

    /// Records the offset at `time` and returns the speed.
    @discardableResult
    public mutating func track(offset: CGFloat, at time: CFTimeInterval) -> CGFloat {
        defer { last = (offset, time) }
        guard let last else { return velocity }
        let delta = offset - last.offset
        let elapsed = time - last.time
        if abs(delta) > 0.5 { isForward = delta > 0 }
        guard elapsed > 0 else { return velocity }
        let instant = delta / CGFloat(elapsed)
        // Smoothed over a few frames: one dropped frame would read as a spike.
        velocity = elapsed > Self.restInterval ? instant : velocity * 0.5 + instant * 0.5
        return velocity
    }

    /// The scroll stopped.
    public mutating func rest() {
        velocity = 0
        last = nil
    }
}

/// Which items of a list fall in its display window and which in its
/// preload window. Pure, so the windows are tested without a screen.
public enum LookaheadPlanner {
    /// Splits `items` (each with its frame in content coordinates) by the
    /// windows around `visible`, facing the scroll direction. An item in both
    /// windows is in `display`. Items keep their order.
    public static func partition<Item>(
        _ items: [(item: Item, frame: CGRect)], visible: CGRect, axis: NSLayoutConstraint.Axis,
        forward: Bool, display: LookaheadWindow, preload: LookaheadWindow
    ) -> (display: [Item], preload: [Item]) {
        let displayRect = display.rect(around: visible, axis: axis, forward: forward)
        let preloadRect = preload.rect(around: visible, axis: axis, forward: forward)
        var inDisplay: [Item] = []
        var inPreload: [Item] = []
        for (item, frame) in items {
            if display != .none, frame.intersects(displayRect) {
                inDisplay.append(item)
            } else if preload != .none, frame.intersects(preloadRect) {
                inPreload.append(item)
            }
        }
        return (inDisplay, inPreload)
    }
}

/// One list's lookahead on screen (#970): a collection view's windows turned
/// into an `ImageLookahead`'s interests, plus its next-page trigger.
///
/// The host calls it from its own delegate (the list's scroll delegate is
/// often busy with other work) and tells it what each item shows:
///
/// - `setOnScreen(true)` when the list joins a window: a new `CacheOwner`
///   for this stay; `setOnScreen(false)` when it leaves: the owner is
///   revoked, which cancels what only this list wanted. Shared fills keep
///   running for the other lists.
/// - `setHidden(true)` while the list is alive under another one (a feed
///   presented over a grid): Texture's minimum windows, no decode, P2 at
///   most; and, after a memory warning, nothing at all until it is shown.
/// - `scrollViewDidScroll()` re-plans once the list moved a quarter screen,
///   turned, or started or stopped flinging; `scrollViewDidEndScrolling()`
///   ends a fling; `setNeedsPlan()` re-plans after a data change.
///
/// Windows come from the coordinator's `PrefetchPolicy` (Wi-Fi: display
/// 1.0/0.5 screens decoded at the bucket, preload 2.5/1.5 bytes to disk;
/// Low Data / Low Power: no preload), and re-plan when it changes.
@MainActor
public final class ScrollLookahead {
    public typealias Images = @MainActor (IndexPath) -> [ImageRequest]

    /// The share of a screen the list must move before the windows move.
    public static let replanFraction: CGFloat = 0.25

    public let kind: LookaheadListKind
    public let name: String
    private let pipeline: ImagePipeline
    private let images: Images
    private let now: () -> CFTimeInterval
    private weak var collectionView: UICollectionView?
    private var lookahead: ImageLookahead?
    private var tracker = ScrollVelocityTracker()
    private var isHidden = false
    private var isInParentWindow = true
    private var droppedForMemory = false
    private var lastPlan: PlanKey?
    private var planPending = false
    /// Plans asked before the list had a size, retried a few turns later.
    private var sizeRetries = 0
    static let maximumSizeRetries = 40
    private var observations: [CacheObservation] = []

    /// What the last plan was made from: a new one is due when it changes.
    private struct PlanKey: Equatable {
        var offset: CGFloat
        var size: CGSize
        var forward: Bool
        var flinging: Bool
    }

    /// - Parameters:
    ///   - name: the owner's name, in the audit and in tests.
    ///   - images: what the item at an index path shows, at the size its
    ///     cell asks for; empty for a text post or an index the host no
    ///     longer holds.
    public init(
        pipeline: ImagePipeline, name: String, kind: LookaheadListKind,
        now: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        images: @escaping Images
    ) {
        self.pipeline = pipeline
        self.name = name
        self.kind = kind
        self.now = now
        self.images = images
        let memory = pipeline.observeMemoryPressure { [weak self] in
            Task { @MainActor [weak self] in self?.memoryPressure() }
        }
        let policy = pipeline.observePrefetchPolicy { [weak self] _ in
            Task { @MainActor [weak self] in self?.replan(force: true) }
        }
        observations = [memory, policy].compactMap { $0 }
    }

    /// The list this lookahead plans for. Held weakly.
    public func attach(to collectionView: UICollectionView) {
        self.collectionView = collectionView
        setNeedsPlan()
    }

    // MARK: - Lifecycle

    /// Whether the list is in a window. Joining starts a new stay with a new
    /// owner; leaving revokes it.
    public func setOnScreen(_ onScreen: Bool) {
        if onScreen {
            guard lookahead == nil else { return }
            let fresh = ImageLookahead(pipeline: pipeline, name: name)
            fresh.setHidden(isHidden)
            lookahead = fresh
            lastPlan = nil
            setNeedsPlan()
        } else {
            lookahead?.revoke()
            lookahead = nil
            lastPlan = nil
            tracker.rest()
        }
    }

    /// Alive but covered by another list: minimum windows, P2 at most.
    public func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if !hidden { droppedForMemory = false }
        lookahead?.setHidden(hidden)
        replan(force: true)
    }

    /// A rail inside a scrolling parent: outside the parent's display window
    /// it plans nothing.
    public func setInParentWindow(_ inside: Bool) {
        guard inside != isInParentWindow else { return }
        isInParentWindow = inside
        replan(force: true)
    }

    // MARK: - Scrolling

    /// The list scrolled: re-plans when it moved far enough, turned, or
    /// started or stopped flinging.
    public func scrollViewDidScroll() {
        guard let collectionView else { return }
        let offset = axisOffset(of: collectionView)
        tracker.track(offset: offset, at: now())
        replan(force: false)
    }

    /// The scroll came to rest: a fling is over and the display window decodes.
    public func scrollViewDidEndScrolling() {
        tracker.rest()
        replan(force: false)
    }

    /// The content changed (a reload, a page appended): re-plans on the next
    /// turn of the run loop, once the layout knows the new items.
    public func setNeedsPlan() {
        guard !planPending else { return }
        planPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            planPending = false
            replan(force: true)
        }
    }

    // MARK: - Reading

    /// Whether the list scrolls faster than `ImageLookahead.flingScreensPerSecond`.
    public var isFlinging: Bool {
        guard let collectionView else { return false }
        return ImageLookahead.isFling(velocity: tracker.velocity, viewportLength: viewportLength(of: collectionView))
    }

    /// Whether the list is close enough to its end to ask for the next page:
    /// 2 screens, 3 while flinging (`LookaheadPaging`).
    public var wantsNextPage: Bool {
        guard let collectionView else { return false }
        let remaining: CGFloat = switch kind.axis {
        case .horizontal: collectionView.contentSize.width - collectionView.bounds.maxX
        default: collectionView.contentSize.height - collectionView.bounds.maxY
        }
        return LookaheadPaging.wantsNextPage(
            remaining: remaining, viewportLength: viewportLength(of: collectionView), isFlinging: isFlinging
        )
    }

    /// The images planned in each window by the last plan, for tests and the audit.
    public private(set) var planned: (display: [ImageRequest], preload: [ImageRequest]) = ([], [])

    /// The window `request` is planned in for this stay, `nil` if none
    /// (a fling or a hidden list downloads its display window: `.preload`).
    public func window(of request: ImageRequest) -> ImagePrefetchWindow? {
        lookahead?.window(of: request)
    }

    /// The owner's interests still waiting for their fill.
    public var activeInterestCount: Int { lookahead?.activeInterestCount ?? 0 }

    /// Whether the list holds an owner (it is on screen).
    public var isOnScreen: Bool { lookahead != nil }

    /// The windows the list plans with now.
    public var windows: (display: LookaheadWindow, preload: LookaheadWindow) {
        if !isInParentWindow || droppedForMemory { return (.none, .none) }
        return LookaheadWindow.windows(for: pipeline.prefetchPolicy, isHidden: isHidden)
    }

    // MARK: - Planning

    private func memoryPressure() {
        guard isHidden, !droppedForMemory else { return }
        droppedForMemory = true
        replan(force: true)
    }

    private func replan(force: Bool) {
        guard let lookahead, let collectionView else { return }
        let viewport = collectionView.bounds
        let length = viewportLength(of: collectionView)
        guard length > 0 else {
            // Content can land before the first layout gives the list a
            // size, and nothing else would ask again while it sits still.
            guard sizeRetries < Self.maximumSizeRetries else { return }
            sizeRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.setNeedsPlan() }
            return
        }
        sizeRetries = 0
        let flinging = isFlinging
        let key = PlanKey(
            offset: axisOffset(of: collectionView), size: viewport.size,
            forward: tracker.isForward, flinging: flinging
        )
        if !force, let lastPlan, lastPlan.size == key.size, lastPlan.forward == key.forward,
           lastPlan.flinging == key.flinging,
           abs(lastPlan.offset - key.offset) < length * Self.replanFraction {
            return
        }
        lastPlan = key
        let (display, preload) = windows
        let reach = display.rect(around: viewport, axis: kind.axis, forward: key.forward)
            .union(preload.rect(around: viewport, axis: kind.axis, forward: key.forward))
        var items: [(item: IndexPath, frame: CGRect)] = []
        if display != .none || preload != .none {
            let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: reach) ?? []
            items = attributes
                .filter { $0.representedElementCategory == .cell }
                .map { (item: $0.indexPath, frame: $0.frame) }
        }
        let split = LookaheadPlanner.partition(
            items, visible: viewport, axis: kind.axis, forward: key.forward, display: display, preload: preload
        )
        let displayed = Self.unique(split.display.flatMap(images))
        let shown = Set(displayed)
        let preloaded = Self.unique(split.preload.flatMap(images)).filter { !shown.contains($0) }
        planned = (displayed, preloaded)
        lookahead.setFlinging(flinging)
        lookahead.update(display: displayed, preload: preloaded)
        #if DEBUG
        if Self.audits {
            let state: String = isHidden ? "hidden" : (flinging ? "fling" : "rest")
            print("[cache-audit] lookahead \(name) \(state) display=\(displayed.count) preload=\(preloaded.count)")
        }
        #endif
    }

    #if DEBUG
    private static let audits = ProcessInfo.processInfo.arguments.contains("-cache-audit")
    #endif

    private static func unique(_ requests: [ImageRequest]) -> [ImageRequest] {
        var seen = Set<ImageRequest>()
        return requests.filter { seen.insert($0).inserted }
    }

    private func axisOffset(of collectionView: UICollectionView) -> CGFloat {
        kind.axis == .horizontal ? collectionView.contentOffset.x : collectionView.contentOffset.y
    }

    private func viewportLength(of collectionView: UICollectionView) -> CGFloat {
        kind.axis == .horizontal ? collectionView.bounds.width : collectionView.bounds.height
    }
}
