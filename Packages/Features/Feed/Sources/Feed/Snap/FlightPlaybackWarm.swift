import CoreModels
import FeedInterface
import Foundation
import UIKit
import MediaCore
import MediaPlayback

/// A post's page player, started before the post opens (#646).
///
/// A map marker flies a low-resolution preview sheet until the page's own
/// video has a frame — measured at +230 ms of a 703 ms flight, most of it the
/// player starting. Nothing used to start before the finger lifted. A finger
/// landing on a video marker is intent enough: this starts the page's player
/// THEN, in the feed's pool, under the post's scope, at the clip time the
/// marker's sheet shows. When the post opens its page asks the pool for the
/// same clip and scope, JOINS this player instead of minting one, and has a
/// frame at once.
///
/// ⚠️ ON AN OFFSCREEN SURFACE, AND ONLY ON INTENT. No player sits behind a
/// marker: the surface is this object's, never on screen, and it lives from a
/// touch-down to an open — or to the touch giving up.
///
/// Ended with `end(opened:)`: an open keeps the player for the page and lets
/// go of this surface once the page has had time to join; anything else stops
/// it and wipes the resume position the stop would otherwise file.
@MainActor
public final class FlightPlaybackWarm: FeedPlaybackWarm {
    private let pool: VideoPlaybackController
    private let url: URL
    private let scope: String
    private let surface = VideoRenderView()
    private var hasEnded = false

    /// How long an opened warm waits before it first asks whether it is alone
    /// on the player — the page's start, at activation, ~70 ms into the
    /// flight, has long joined by then.
    static let handOverGrace: TimeInterval = 3

    init(pool: VideoPlaybackController, url: URL, scope: String) {
        self.pool = pool
        self.url = url
        self.scope = scope
        #if DEBUG
        surface.debugLabel = "flight-warm"
        #endif
    }

    /// Set by a preroll (#654) until the first frame pauses it — or until a
    /// `resume` claims it first.
    private var pausesOnFirstFrame = false

    /// Starts the clip at `seconds` (or where the pool would start it).
    /// `pausedOnFirstFrame`: a PREROLL — it plays to its first decoded frame
    /// and stops there, so nothing decodes while the map is at rest.
    func start(at seconds: TimeInterval?, pausedOnFirstFrame: Bool = false) {
        if let seconds { pool.prepareStart(of: url, scope: scope, at: seconds) }
        pausesOnFirstFrame = pausedOnFirstFrame
        let pool = pool, url = url, scope = scope, surface = surface
        let peakBitRate = MediaPlaybackPolicy.peakBitRate
        Task { [weak self] in
            await pool.play(url, in: surface, peakBitRate: peakBitRate, scope: scope)
            await self?.pauseOnFirstFrameIfPrerolling()
        }
    }

    /// Polls for the first frame — an offscreen surface hears no picture
    /// callback, since nothing is enqueued on it — and pauses on it. Gives up
    /// after `firstFrameLooks` looks, leaving a player that never decoded to
    /// whoever ends this warm.
    private func pauseOnFirstFrameIfPrerolling() async {
        for _ in 0..<Self.firstFrameLooks {
            guard pausesOnFirstFrame, !hasEnded else { return }
            if hasPicture {
                pausesOnFirstFrame = false
                pool.setPaused(true, in: surface)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-zoom-live-log") {
                    print("[zoom-live] preroll \(scope): first frame decoded, paused")
                }
                #endif
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    static let firstFrameLooks = 100

    public func resume(at seconds: TimeInterval?) {
        pausesOnFirstFrame = false
        // Resumed BEFORE the seek: `setPaused(false)` pins a drifted player
        // back to where it paused, which would undo a seek made first.
        pool.setPaused(false, in: surface)
        if let seconds { pool.seek(toSeconds: seconds, in: surface, toleranceSeconds: 0.05) }
    }

    /// Whether a preroll may spend a player now (#654): the viewer's
    /// preloading preference (which covers cellular) and autoplay, and the
    /// device not in Low Power nor under serious thermal pressure. Pure.
    nonisolated static func prerollAllowed(preloads: Bool, autoplays: Bool, lowPower: Bool,
                                           thermal: ProcessInfo.ThermalState) -> Bool {
        preloads && autoplays && !lowPower && thermal != .serious && thermal != .critical
    }

    public var hasPicture: Bool { surface.currentFrameBuffer != nil }

    /// Joins `surface` to this player: it shows the frame decoded last at
    /// once, then plays on with it. The flight card's picture IS the page's
    /// clip from take-off — the page then joins the same player at landing.
    public func mirror(onto surface: UIView) -> Bool {
        guard let view = surface as? VideoRenderView else { return false }
        return pool.attachSurface(view, to: url, scope: scope)
    }

    /// Lets go. `opened`: the post opened and its page is joining this player.
    ///
    /// ⚠️ AN OPENED WARM KEEPS ITS SURFACE WHILE ANYONE ELSE IS ON THE PLAYER.
    /// This surface holds the pool's LOAN; the page and the flight card only
    /// joined, and a joined surface holds none — so stopping this one retires
    /// the player under them (filmed: `RETIRE with 2 joined surface(s)`, the
    /// page going dark three seconds in). It checks once a second and lets go
    /// only when it is alone on the player: the page closed, or moved on.
    public func end(opened: Bool) {
        guard !hasEnded else { return }
        hasEnded = true
        guard opened else { return release(watched: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handOverGrace) { [self] in
            MainActor.assumeIsolated { self.releaseWhenAlone() }
        }
    }

    /// Whether another surface is drawing this player besides this one.
    private var isJoined: Bool { (pool.surfaceCount(for: url) ?? 0) > 1 }
    private var wasJoined = false

    private func releaseWhenAlone() {
        if isJoined {
            wasJoined = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                MainActor.assumeIsolated { self.releaseWhenAlone() }
            }
            return
        }
        release(watched: wasJoined)
    }

    /// Stops the surface. A clip nobody watched also loses what the stop
    /// files — no position to resume, and a start asked for it was never
    /// spent; a watched one keeps where the viewer left it, as any page's does.
    private func release(watched: Bool) {
        pool.stop(surface)
        if !watched { pool.forgetStart(of: url, scope: scope) }
    }

    /// Which clip a post's page plays first, when it is one a warm can start:
    /// the HEAD attachment, when it is a video — a collection opens on its head
    /// page, which plays that clip under the post's scope like a single one.
    /// The URL and the scope the page itself will ask for. Nil for a photo or
    /// a text post, or a collection that starts on a photo. Pure, for tests.
    static func warmableClip(of entry: FeedEntry) -> (url: URL, scope: String)? {
        guard let head = entry.post.attachments.first,
              MediaKind(mimeType: head.mimeType) == .video, let url = head.url else { return nil }
        return (url, entry.post.id.rawValue)
    }
}
