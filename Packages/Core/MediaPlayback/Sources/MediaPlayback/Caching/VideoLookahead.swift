import CacheKit
import CoreMedia
import Foundation

/// A clip the vertical feed may need next: its media URL and the post it
/// plays for (the pool's identity rule: asset AND post).
public struct VideoLookaheadItem: Hashable, Sendable {
    public let url: URL
    public let scope: String

    public init(url: URL, scope: String) {
        self.url = url
        self.scope = scope
    }
}

/// How far the playing item has buffered ahead of its playhead.
public struct VideoBufferStatus: Sendable, Equatable {
    /// Seconds loaded past the playhead, in the loaded range that holds it.
    public var bufferedAhead: Double
    /// The item's duration; not finite while unknown.
    public var duration: Double
    /// Whether that range reaches the end of the item.
    public var isComplete: Bool

    public init(bufferedAhead: Double, duration: Double, isComplete: Bool) {
        self.bufferedAhead = bufferedAhead
        self.duration = duration
        self.isComplete = isComplete
    }

    /// Reads an item's `loadedTimeRanges` at its playhead.
    init(current: Double, duration: Double, loaded: [CMTimeRange]) {
        let playhead = current.isFinite ? current : 0
        let ranges = loaded
            .map { ($0.start.seconds, ($0.start + $0.duration).seconds) }
            .filter { $0.0.isFinite && $0.1.isFinite }
        // The range the playhead sits in; a range starting a hair after it
        // (a seek still landing) counts too.
        let end = ranges.first { $0.0 <= playhead + 0.5 && $0.1 >= playhead }?.1 ?? playhead
        bufferedAhead = max(0, end - playhead)
        self.duration = duration
        isComplete = duration.isFinite && duration > 0 && end >= duration - 0.25
    }
}

/// Where the vertical feed's playing clip stands, as its lookahead reads it.
public enum VideoPlayingState: Sendable, Equatable {
    /// No player yet, or its item is not ready to play.
    case notReady
    /// The item failed: it will never buffer, and competes with nothing.
    case failed
    /// Playing (or paused) with this much buffered.
    case ready(VideoBufferStatus)
}

/// The rules that decide when the vertical feed's speculative preload may
/// start (#895, from BytePlus' shipped recipe and Media3, #970).
public enum VideoLookaheadGate {
    /// P2 (+2/+3 head ranges) starts only once the playing video has buffered
    /// more than this ahead, or completely.
    public static let speculativeStartSeconds: Double = 20
    /// The threshold for a clip shorter than `shortClipDuration`: half, or a
    /// 15 s clip could never start its neighbours' preload before its end.
    public static let shortClipStartSeconds: Double = 10
    public static let shortClipDuration: Double = 20
    /// Below this ahead, the playing video is under-buffered: no P2 fill
    /// starts anywhere in the app (`CacheCoordinator.setPlaybackUnderBuffered`)
    /// and the +1 player is not warmed yet, so nothing competes with the
    /// picture the viewer is looking at.
    public static let underBufferedSeconds: Double = 3
    /// How long a playing clip that is not ready yet counts as under-buffered.
    /// Past it the app-wide P2 pause is released and +1 is warmed: an item
    /// stuck before ready must not hold every list's prefetch for as long as
    /// the viewer stays on its page.
    public static let notReadyGraceSeconds: Double = 5

    public static func allowsSpeculative(_ status: VideoBufferStatus) -> Bool {
        if status.isComplete { return true }
        let short = status.duration.isFinite && status.duration > 0 && status.duration < shortClipDuration
        return status.bufferedAhead > (short ? shortClipStartSeconds : speculativeStartSeconds)
    }

    public static func isUnderBuffered(_ status: VideoBufferStatus) -> Bool {
        !status.isComplete && status.bufferedAhead < underBufferedSeconds
    }
}

/// Calls a tick on the main actor at an interval until the tick says stop.
/// Injected, so a test moves time by hand.
@MainActor
protocol VideoLookaheadClock: AnyObject {
    var now: Date { get }
    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool)
}

/// The app's clock: a main-actor task sleeping between ticks.
@MainActor
final class TaskLookaheadClock: VideoLookaheadClock {
    var now: Date { Date() }

    func schedule(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard tick() else { return }
            }
        }
    }
}

/// The vertical feed's video preload (#895, policy from #970).
///
/// Around the page the viewer settled on:
///
/// - **+1 (P1):** a warm player — its first frame decoded and ~5 s read ahead
///   (`VideoPlaybackController.setLookahead`), started once the playing video
///   is no longer under-buffered.
/// - **+2, +3 (P2):** only the head range (1 MB) written to disk, with no
///   player (`VideoByteCache.preloadHead`), started once the playing video has
///   buffered more than 20 s or completely (10 s for a clip under 20 s).
/// - **−1:** its player is kept, paused where it was left.
/// - **A swipe** cancels every P2 (the owner is revoked) and plans again.
///
/// Depth follows the coordinator's `PrefetchPolicy`: Wi-Fi 3, cellular 2
/// (+1 warm and +2's head), Low Data Mode / Low Power / serious thermal 1
/// (+1 warm only, no P2), offline or critical thermal 0. The feed's own data
/// saver (`allowsPreload: false`) is 0. The policy is read again on every
/// tick, so a condition that changes takes effect at once.
///
/// Main actor: it is driven by the feed's settles and reads the pool.
@MainActor
public final class VideoLookahead {
    /// How often the playing item's buffer is read.
    public static let tickInterval: TimeInterval = 0.5

    public typealias Apply = @MainActor (_ next: VideoLookaheadItem?, _ previous: VideoLookaheadItem?, _ warmNext: Bool) -> Void

    private let cache: VideoByteCache
    private let name: String
    private let policy: @MainActor () -> PrefetchPolicy
    private let probe: @MainActor (VideoLookaheadItem) -> VideoPlayingState
    private let resolve: @Sendable (URL) async -> URL?
    private let apply: Apply
    /// Gives back what `apply` set, if nothing else set something since.
    private let release: @MainActor () -> Void
    private let clock: any VideoLookaheadClock

    private var owner: CacheOwner
    private var page: String?
    private var playing: VideoLookaheadItem?
    private var ahead: [VideoLookaheadItem?] = []
    private var behind: VideoLookaheadItem?
    private var allowsPreload = true
    /// Latched per page: the playing video buffered enough once.
    private var speculativeOpen = false
    /// Since when the playing clip has been `.notReady` on this page.
    private var notReadySince: Date?
    /// Head preloads asked for on this page: an interest, or nil when there
    /// was nothing to fetch (already on disk, not cacheable).
    private var heads: [VideoLookaheadItem: CacheFillInterest?] = [:]
    private var resolving: Set<VideoLookaheadItem> = []
    private var reportedUnderBuffered = false
    private var isTicking = false

    /// Who set the pool's lookahead: one token per lookahead.
    private final class Client {}

    convenience init(playback: VideoPlaybackController, cache: VideoByteCache, name: String) {
        let client = Client()
        let id = ObjectIdentifier(client)
        self.init(
            cache: cache, name: name,
            policy: { cache.prefetchPolicy },
            probe: { [weak playback] item in playback?.playingState(of: item.url, scope: item.scope) ?? .notReady },
            resolve: { [weak playback] url in try? await playback?.playableURL(for: url) },
            apply: { [weak playback] next, previous, warmNext in
                // The token lives as long as this closure, so its identifier
                // is never reused while the pool may compare it.
                withExtendedLifetime(client) {
                    playback?.setLookahead(next: next, previous: previous, warmNext: warmNext, client: id)
                }
            },
            release: { [weak playback] in playback?.clearLookahead(for: id) },
            clock: TaskLookaheadClock()
        )
    }

    init(
        cache: VideoByteCache, name: String,
        policy: @escaping @MainActor () -> PrefetchPolicy,
        probe: @escaping @MainActor (VideoLookaheadItem) -> VideoPlayingState,
        resolve: @escaping @Sendable (URL) async -> URL?,
        apply: @escaping Apply,
        release: @escaping @MainActor () -> Void = {},
        clock: any VideoLookaheadClock
    ) {
        self.cache = cache
        self.name = name
        self.policy = policy
        self.probe = probe
        self.resolve = resolve
        self.apply = apply
        self.release = release
        self.clock = clock
        owner = CacheOwner(name)
    }

    /// The feed settled on `page`.
    ///
    /// - Parameters:
    ///   - playing: the page's clip; nil when the page is not a video (then
    ///     nothing competes, and the window starts at once).
    ///   - ahead: the pages after it, +1 first; nil for a page with no clip.
    ///   - behind: the page before it (−1), if it is a video.
    ///   - allowsPreload: false under the feed's data saver: nothing ahead.
    public func update(
        page: String, playing: VideoLookaheadItem?, ahead: [VideoLookaheadItem?],
        behind: VideoLookaheadItem?, allowsPreload: Bool = true
    ) {
        if page != self.page {
            // A swipe: every P2 of the page left is cancelled (BytePlus), so
            // none slows the new video's first frame.
            owner.revoke()
            owner = CacheOwner(name)
            heads.removeAll()
            resolving.removeAll()
            speculativeOpen = false
            notReadySince = nil
            if self.page != nil { VideoCacheAudit.emit("lookahead swipe -> cancel P2") }
            let video: String = playing?.url.absoluteString ?? "-"
            VideoCacheAudit.emit("lookahead settle page=\(page) video=\(video)")
        }
        self.page = page
        self.playing = playing
        self.ahead = ahead
        self.behind = behind
        self.allowsPreload = allowsPreload
        evaluate()
        startTicking()
    }

    /// The feed left the screen: everything goes.
    public func stop() {
        owner.revoke()
        owner = CacheOwner(name)
        heads.removeAll()
        resolving.removeAll()
        page = nil
        playing = nil
        ahead = []
        behind = nil
        speculativeOpen = false
        notReadySince = nil
        release()
        reportUnderBuffered(false)
    }

    // MARK: - Introspection (tests, audit)

    /// The clips whose head preload this page asked for (or is resolving).
    var requestedHeads: Set<VideoLookaheadItem> { Set(heads.keys).union(resolving) }

    var activeHeadInterests: Int { heads.values.compactMap { $0 }.filter(\.isActive).count }

    // MARK: - Planning

    private var depth: Int { allowsPreload ? max(0, policy().videoPreloadDepth) : 0 }

    private func startTicking() {
        guard !isTicking else { return }
        isTicking = true
        clock.schedule(every: Self.tickInterval) { [weak self] in
            guard let self, page != nil else {
                self?.isTicking = false
                return false
            }
            evaluate()
            return true
        }
    }

    /// Re-reads the playing item's buffer and the policy, and moves the
    /// window to match.
    func evaluate() {
        guard page != nil else { return }
        let depth = depth
        let state = playing.map(probe)
        var status: VideoBufferStatus?
        let underBuffered: Bool
        switch state {
        case nil, .failed?:
            // Nothing plays, or what plays will never buffer: nothing to protect.
            notReadySince = nil
            underBuffered = false
        case .ready(let buffered)?:
            notReadySince = nil
            status = buffered
            underBuffered = VideoLookaheadGate.isUnderBuffered(buffered)
        case .notReady?:
            // Starting: under-buffered, for a few seconds at most.
            let now = clock.now
            let since = notReadySince ?? now
            notReadySince = since
            underBuffered = now.timeIntervalSince(since) < VideoLookaheadGate.notReadyGraceSeconds
        }
        reportUnderBuffered(underBuffered)

        let next = depth >= 1 ? ahead.first ?? nil : nil
        apply(next, behind, next != nil && !underBuffered)

        let wanted = depth >= 2 ? Array(ahead.dropFirst().prefix(depth - 1).compactMap { $0 }) : []
        for (item, interest) in heads where !wanted.contains(item) {
            interest?.release()
            heads[item] = nil
        }
        resolving = resolving.filter { wanted.contains($0) }
        if !speculativeOpen {
            speculativeOpen = playing == nil || state == .failed
                || status.map(VideoLookaheadGate.allowsSpeculative) ?? false
            if speculativeOpen, !wanted.isEmpty { VideoCacheAudit.emit("lookahead P2 open depth=\(depth)") }
        }
        guard speculativeOpen else { return }
        for item in wanted where heads[item] == nil && !resolving.contains(item) {
            requestHead(item)
        }
    }

    private func requestHead(_ item: VideoLookaheadItem) {
        resolving.insert(item)
        let owner = owner
        let resolve = resolve
        Task { @MainActor [weak self] in
            let resolved = await resolve(item.url)
            guard let self, owner === self.owner, resolving.remove(item) != nil else { return }
            let interest = resolved.flatMap { cache.preloadHead(of: $0, priority: .speculative, owner: owner) }
            heads[item] = .some(interest)
        }
    }

    private func reportUnderBuffered(_ underBuffered: Bool) {
        guard underBuffered != reportedUnderBuffered else { return }
        reportedUnderBuffered = underBuffered
        cache.setPlaybackUnderBuffered(underBuffered)
    }
}
