import AVFoundation
import CacheKit
import CoreMedia
import Foundation
import UIKit

// Test hooks (DEBUG)
extension VideoPlaybackController {
    // MARK: - Test hooks

    #if DEBUG
    /// What rung an adaptive stream actually settled on, for QA.
    ///
    /// `preferred` is the ceiling we asked for; `indicated` is the declared
    /// bitrate of the variant AVFoundation chose. Comparing them is the only
    /// direct evidence that a cap did anything — byte counting can't tell a
    /// capped ladder from a progressive file, which ignores the cap entirely.
    /// `nil` when nothing is playing or the stream has produced no access log
    /// yet (progressive assets never do).
    public struct BitRateReport: Sendable {
        public let preferred: Double
        public let indicated: Double
        public let observed: Double
    }

    public func debugBitRateReport(in view: VideoRenderView) -> BitRateReport? {
        guard let item = activePlayers[ObjectIdentifier(view)]?.currentItem,
              let event = item.accessLog()?.events.last
        else { return nil }
        return BitRateReport(
            preferred: item.preferredPeakBitRate,
            indicated: event.indicatedBitrate,
            observed: event.observedBitrate
        )
    }

    var idlePlayerCount: Int { idlePlayers.count }

    /// The byte-cache pin a parked return player holds, for the tests.
    func debugReturnPin(of url: URL, scope: String, owner: ObjectIdentifier? = nil) -> VideoRangePin? {
        returnPlaybacks.first { $0.key == ReturnKey(scope: scope, url: url, owner: owner) }?.pin
    }

    /// A parked frame, kept as a capture would keep it: the grid's tests have
    /// no clip to decode one from.
    public func debugKeepReturnStill(_ image: UIImage, at seconds: Double, of url: URL, scope: String, owner: ObjectIdentifier? = nil) {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        returnStills.removeAll { $0.key == key }
        returnStills.append((key, ReturnStill(image: image, seconds: seconds)))
    }

    /// The start position filed for the next fresh player of `url` under
    /// `scope` (`prepareStart`), without spending it.
    public func debugFiledStart(of url: URL, scope: String) -> Double? {
        resumeTimes[ResumeKey(scope: scope, url: url)]?.seconds
    }

    /// `-sound-log`'s census: every player bound or parked, whether it is
    /// muted and moving, and which surfaces own it — one line each.
    ///
    /// ⚠️ A RECORDING HAS NO SOUND TRACK, so a clip heard where it should not
    /// be is invisible to every video QA this app has. This is the evidence
    /// instead: after a feed closes, every advancing player reads `muted=1`.
    func debugSoundCensus() -> [String] {
        var owners: [ObjectIdentifier: [String]] = [:]
        var players: [ObjectIdentifier: AVPlayer] = [:]
        for (key, player) in activePlayers {
            let id = ObjectIdentifier(player)
            players[id] = player
            owners[id, default: []].append(surfaces[key]?.view?.debugProducerName ?? "dead")
        }
        if let parked {
            players[ObjectIdentifier(parked.player)] = parked.player
            owners[ObjectIdentifier(parked.player), default: []].append("parked")
        }
        return players.map { id, player in
            "\(VideoProducerLog.name(player)) muted=\(player.isMuted ? 1 : 0)"
                + " rate=\(player.rate) heard=\(surfaceHeardPlayer === player ? 1 : 0)"
                + " owners=\(owners[id, default: []].sorted())"
        }.sorted()
    }

    /// Census of the tables that must not outlive what they describe. Public
    /// because the hero-transition audit reads them from the app target; each
    /// is a leak the moment it exceeds the live state it mirrors.
    public var debugPausedAnchorCount: Int { pausedAnchors.count }
    /// Internal for tests: how many players have a seek in flight.
    public var debugSeeksInFlight: Int { seeking.count }
    /// Internal for tests: how many players are recorded as running an
    /// arrangement — a table keyed by player, which must shrink with the pool.
    var debugLoopEntryCount: Int { looping.count }
    /// Internal for tests: how many positions are queued behind a seek.
    /// ⚠️ **Internal for tests: the position QUEUED behind the seek in flight.**
    /// The count of the dictionary is one entry per PLAYER and can never exceed
    /// one with a single-player fixture, so asserting it is structurally true —
    /// a real backlog regression would change `Chase` to an array and the outer
    /// count would still read 1. The queued target can actually be wrong.
    /// Internal for tests: the rate the player is running at, and the rate its
    /// next `play()` will use.
    ///
    /// ⚠️ **TWO NUMBERS, AND THE DIFFERENCE IS THE WHOLE POINT.** Assigning
    /// `rate` starts playback; `defaultRate` states the speed without deciding
    /// whether anything is moving. A test that read only one of them could not
    /// tell "set the speed" from "start playing at that speed".
    /// The item `view` is running — what a test observes notifications on.
    /// The composition drawing what `view` shows: the one its renderer reads,
    /// or on the legacy path the one its item carries.
    public func debugComposition(in view: VideoRenderView) -> AVVideoComposition? {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return nil }
        return renderer(for: player)?.composedVideo?.composition ?? player.currentItem?.videoComposition
    }

    public func debugItem(in view: VideoRenderView) -> AVPlayerItem? {
        watchedPlayer(in: view)?.currentItem
    }

    public func debugRates(in view: VideoRenderView) -> (rate: Float, next: Float)? {
        guard let player = watchedPlayer(in: view) else { return nil }
        return (player.rate, player.defaultRate)
    }

    public func debugChasedTarget(in view: VideoRenderView) -> Double? {
        guard let player = watchedPlayer(in: view) else { return nil }
        return chased[ObjectIdentifier(player)]?.target.seconds
    }
    /// Internal for tests: seeks that ran to completion.
    public var debugSeeksLanded: Int { seeksLanded }
    /// ⚠️ **Internal for tests: the tolerance the LAST seek was asked with.** An
    /// adapter that accepts a tolerance and forwards nothing compiles without a
    /// warning and is invisible to any test that reads the value off a stub —
    /// which is exactly what happened. This is what an adapter can be asked.
    public var debugLastSeekToleranceSeconds: Double? { lastSeekTolerance }
    /// ⚠️ **Internal for tests: seeks KILLED BY A LATER ONE.** This is the whole
    /// measurement behind the chase pattern — a scrub asking sixty times a second
    /// without it cancels almost every request it makes, and the picture sits
    /// still and then jumps.
    public var debugSeeksCancelled: Int { seeksCancelled }
    public var debugStallObserverCount: Int { stallObservers.count }
    public var debugGenerationEntryCount: Int { generation.count }
    public var debugIdlePlayerCount: Int { idlePlayers.count }

    func activePlayer(in view: VideoRenderView) -> AVPlayer? { activePlayers[ObjectIdentifier(view)] }
    func peakBitRate(in view: VideoRenderView) -> Double? {
        activePlayers[ObjectIdentifier(view)]?.currentItem?.preferredPeakBitRate
    }
    func currentItem(in view: VideoRenderView) -> AVPlayerItem? {
        activePlayers[ObjectIdentifier(view)]?.currentItem
    }
    /// Internal for tests: the renderer drawing `view` — whose current frame is
    /// what the surface shows.
    func debugRenderer(in view: VideoRenderView) -> VideoFrameRenderer? {
        watchedPlayer(in: view).flatMap { renderers[ObjectIdentifier($0)] }
    }
    #endif
}
