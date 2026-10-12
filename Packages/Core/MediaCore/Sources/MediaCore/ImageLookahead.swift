import CacheKit
import Foundation
import Synchronization
import UIKit

/// A window of a list's lookahead, in screens along its scroll axis (#970,
/// Texture's tuning parameters).
public struct LookaheadWindow: Sendable, Equatable {
    /// Screens ahead in the scroll direction.
    public var leading: Double
    /// Screens behind.
    public var trailing: Double

    public init(leading: Double, trailing: Double) {
        self.leading = max(0, leading)
        self.trailing = max(0, trailing)
    }

    public static let none = LookaheadWindow(leading: 0, trailing: 0)
    /// Decoded at the size bucket (P1): 1.0 screen ahead, 0.5 behind.
    public static let display = LookaheadWindow(leading: 1, trailing: 0.5)
    /// Bytes to disk, no decode (P2): 2.5 screens ahead, 1.5 behind.
    public static let preload = LookaheadWindow(leading: 2.5, trailing: 1.5)
    /// A list alive but not the visible one (Texture's minimum).
    public static let hiddenDisplay = LookaheadWindow(leading: 0.25, trailing: 0.25)
    public static let hiddenPreload = LookaheadWindow(leading: 0.5, trailing: 0.25)

    /// The windows a list uses under `policy` (the coordinator's, from Low
    /// Data, Low Power, thermal state and the network). A hidden list never
    /// goes past the minimum windows.
    public static func windows(for policy: PrefetchPolicy, isHidden: Bool = false) -> (display: LookaheadWindow, preload: LookaheadWindow) {
        let display = LookaheadWindow(leading: policy.displayScreens, trailing: policy.displayScreens / 2)
        let preload = policy.preloadScreens > 0
            ? LookaheadWindow(leading: policy.preloadScreens, trailing: policy.preloadScreens * 0.6)
            : .none
        guard isHidden else { return (display, preload) }
        return (display.capped(at: .hiddenDisplay), preload.capped(at: .hiddenPreload))
    }

    /// The rect the window covers around `visible`, along `axis`, facing the
    /// scroll direction (`forward`: towards larger offsets). Leading and
    /// trailing swap when the scroll reverses.
    public func rect(around visible: CGRect, axis: NSLayoutConstraint.Axis, forward: Bool = true) -> CGRect {
        let length = axis == .vertical ? visible.height : visible.width
        let ahead = CGFloat(leading) * length
        let behind = CGFloat(trailing) * length
        let before = forward ? behind : ahead
        let after = forward ? ahead : behind
        switch axis {
        case .vertical:
            return CGRect(x: visible.minX, y: visible.minY - before, width: visible.width, height: visible.height + before + after)
        default:
            return CGRect(x: visible.minX - before, y: visible.minY, width: visible.width + before + after, height: visible.height)
        }
    }

    private func capped(at limit: LookaheadWindow) -> LookaheadWindow {
        LookaheadWindow(leading: min(leading, limit.leading), trailing: min(trailing, limit.trailing))
    }
}

/// One list's image lookahead (#970): a feed, a grid, a rail, each with its
/// own `CacheOwner` over the pipeline's shared, deduplicated fills.
///
/// The list says which images sit in its display window (decoded at their
/// bucket, P1) and which in its preload window (bytes to disk without
/// decoding, P2), every time its windows move. The lookahead turns that into
/// interests:
///
/// - an image entering a window is requested once; one leaving every window
///   is released, which cancels its fill unless another list (or a visible
///   load) still wants it;
/// - an image moving from preload to display keeps its download running and
///   raises it, then decodes; one moving back drops the decode and keeps the
///   bytes;
/// - while the list flings (`setFlinging(true)`), or while it is alive but
///   hidden (`setHidden(true)`), the display window downloads without
///   decoding; a hidden list's interests are also capped at P2;
/// - `revoke()`, when the list leaves the screen, drops everything it held.
///   Final: a list shown again makes a new lookahead.
///
/// Thread-safe; every call is cheap (no fetch, no decode runs inside).
public final class ImageLookahead: Sendable {
    /// The scroll speed, in screens per second, above which a list counts as
    /// flinging and skips decoding (proposal, to tune with `-cache-audit`).
    public static let flingScreensPerSecond: CGFloat = 4

    /// Whether `velocity` (points per second) along a viewport `length`
    /// points long is a fling.
    public static func isFling(velocity: CGFloat, viewportLength: CGFloat) -> Bool {
        viewportLength > 0 && abs(velocity) > viewportLength * flingScreensPerSecond
    }

    private struct Entry {
        var window: ImagePrefetchWindow
        var decode: CacheFillInterest?
        var bytes: CacheFillInterest?
        var askedBytes = false
    }

    private struct State {
        var display: [ImageRequest] = []
        var preload: [ImageRequest] = []
        var entries: [ImageRequest: Entry] = [:]
        var isFlinging = false
        var isHidden = false
        var isRevoked = false
    }

    private let pipeline: ImagePipeline
    private let owner: CacheOwner
    private let state = Mutex(State())

    public init(pipeline: ImagePipeline, name: String) {
        self.pipeline = pipeline
        owner = CacheOwner(name)
    }

    deinit { revoke() }

    /// The list's windows moved: `display` holds what should be decoded,
    /// `preload` what should only be on disk (an image in both is displayed).
    public func update(display: [ImageRequest], preload: [ImageRequest]) {
        state.withLock { state in
            state.display = display
            state.preload = preload
            replan(&state)
        }
    }

    /// While flinging, the display window downloads without decoding; it
    /// decodes again once the scroll slows.
    public func setFlinging(_ flinging: Bool) {
        state.withLock { state in
            guard state.isFlinging != flinging else { return }
            state.isFlinging = flinging
            replan(&state)
        }
    }

    /// A list alive under another one: no decode, P2 at most.
    public func setHidden(_ hidden: Bool) {
        owner.setPriorityCeiling(hidden ? .speculative : .visible)
        state.withLock { state in
            guard state.isHidden != hidden else { return }
            state.isHidden = hidden
            replan(&state)
        }
    }

    /// The list left the screen: every interest it held is dropped. Final.
    public func revoke() {
        owner.revoke()
        state.withLock { state in
            state.isRevoked = true
            state.entries.removeAll()
            state.display = []
            state.preload = []
        }
    }

    /// The window `request` is planned in, `nil` if none.
    public func window(of request: ImageRequest) -> ImagePrefetchWindow? {
        state.withLock { $0.entries[request]?.window }
    }

    /// Interests still waiting for their fill.
    public var activeInterestCount: Int { owner.interestCount }

    /// Turns the windows into interests. Runs under the lock: the pipeline
    /// and the fills never call back into a lookahead, so nothing re-enters.
    private func replan(_ state: inout State) {
        guard !state.isRevoked else { return }
        var desired: [ImageRequest: ImagePrefetchWindow] = [:]
        for request in state.preload { desired[request] = .preload }
        let decodes = !state.isFlinging && !state.isHidden
        for request in state.display { desired[request] = decodes ? .display : .preload }

        for (request, entry) in state.entries where desired[request] == nil {
            entry.decode?.release()
            entry.bytes?.release()
            state.entries[request] = nil
        }
        for (request, window) in desired {
            var entry = state.entries[request] ?? Entry(window: window)
            let isNew = state.entries[request] == nil
            if isNew || entry.window != window {
                entry.window = window
                switch window {
                case .display:
                    // The download keeps running (raised to P1); the decode
                    // joins it instead of starting over.
                    entry.bytes?.setPriority(.next)
                    entry.decode = pipeline.prefetch(request.url, size: request.size, window: .display, owner: owner)
                case .preload:
                    entry.decode?.release()
                    entry.decode = nil
                    if entry.askedBytes {
                        entry.bytes?.setPriority(.speculative)
                    } else {
                        entry.askedBytes = true
                        entry.bytes = pipeline.prefetch(request.url, size: request.size, window: .preload, owner: owner)
                    }
                }
            }
            state.entries[request] = entry
        }
    }
}
