import AVFoundation
import CacheKit
import CoreMedia
import Foundation
import UIKit

// Return playback (#923): the players parked for a way back, and the still they leave
extension VideoPlaybackController {
    // MARK: - Return playback (#923)

    /// How many return players may be parked at once, across the whole app.
    ///
    /// A return player is a second player on a clip that is already playing
    /// somewhere else, so it is paid for in decoders. Two covers the case that
    /// matters, a post opened from a tile and a second one opened from inside
    /// it. A deeper stack evicts the oldest, and that close lands on the
    /// tile's still instead of its clip.
    public static let returnPlaybackCapacity = 2

    /// A post's clip, as a return player is keyed: the same asset AND the same
    /// post, for the reason `playingScope` gives — and the same OWNER (#951).
    ///
    /// ⚠️ TWO SURFACES CAN PARK ONE POST. A Following card opens a video, the
    /// sound sheet opened from it shows the same post as a tile, and that tile
    /// opens it again: keyed by post alone, the second park replaced the
    /// first, and either close could resume — or release — the other's player.
    struct ReturnKey: Hashable {
        let scope: String
        let url: URL
        let owner: ObjectIdentifier?
    }

    /// One parked return player.
    struct ReturnPlayback {
        let key: ReturnKey
        let player: AVPlayer
        /// Where the clip was parked: the frame its still is taken at.
        let parkedAt: CMTime
        /// A surface outside any window that keeps the renderer pulling until
        /// the parked frame is decoded, so a landing surface joining later is
        /// primed with it rather than waiting for a decode. Let go once the
        /// frame is there: an idle renderer must not keep the frame clock
        /// running.
        var holder: VideoRenderView?
        /// The byte cache's hold on the clip's ranges around the parked
        /// playhead (#895): a budget cut while the post is open cannot drop
        /// what the close will read. Released with the entry.
        var pin: VideoRangePin?
    }

    /// The frame a park showed, and where in the clip it is (#895, the #923
    /// follow-up).
    public struct ReturnStill {
        public let image: UIImage
        public let seconds: Double
    }

    /// How many parked frames are kept: twice the players, so the frame of a
    /// player a deeper stack evicted is still there for its close.
    public static let returnStillCapacity = 4
    /// The longest side of a kept frame, in pixels: a tile's picture, not the
    /// clip's.
    nonisolated static let returnStillMaxPixels: CGFloat = 720


    /// The frame parked for `url` under `scope`, if one was captured and is
    /// still kept.
    public func returnStill(of url: URL, scope: String, owner: ObjectIdentifier? = nil) -> ReturnStill? {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        return returnStills.last { $0.key == key }?.still
    }

    private func keepReturnStill(_ still: ReturnStill, for key: ReturnKey, token: Int) {
        guard returnStillTokens[key] == token else { return }
        returnStillTokens[key] = nil
        returnStills.removeAll { $0.key == key }
        returnStills.append((key, still))
        while returnStills.count > Self.returnStillCapacity { returnStills.removeFirst() }
        VideoProducerLog.emit("RETURN STILL \(key.url.lastPathComponent)"
            + String(format: " at=%.2fs", still.seconds))
    }

    private func dropReturnStill(for key: ReturnKey) {
        returnStillTokens[key] = nil
        returnStills.removeAll { $0.key == key }
    }

    /// Captures the parked frame of `player`: the renderer's own buffer when
    /// it holds the parked frame (free, and exactly what was drawn), else one
    /// image from the asset at the parked time (no renderer under
    /// `-avplayer-render`, or a decode that missed the holder's ceiling).
    private func captureReturnStill(of player: AVPlayer, for key: ReturnKey, at parkedAt: CMTime) {
        guard let token = returnStillTokens[key] else { return }
        if let renderer = renderers[ObjectIdentifier(player)], let frameTime = renderer.currentFrameTime,
           frameTime.isValid, abs(frameTime.seconds - parkedAt.seconds) < 0.5,
           let buffer = renderer.currentFrameBuffer,
           let image = VideoStillCapture.image(from: buffer, maxPixels: Self.returnStillMaxPixels) {
            keepReturnStill(ReturnStill(image: image, seconds: frameTime.seconds), for: key, token: token)
            return
        }
        guard let asset = player.currentItem?.asset else {
            returnStillTokens[key] = nil
            return
        }
        // As DRAWN: the sample-buffer path does not apply the track's
        // transform (`VideoRenderView.currentFrameBuffer`), a player layer does.
        let upright = !VideoRenderFlags.usesSampleBufferLayer
        let source = ReturnStillSource(asset: asset)
        Task { @MainActor [weak self] in
            guard let frame = await Self.frame(of: source, at: parkedAt, upright: upright) else {
                // Nothing to show for this park: its token goes, not kept for good.
                if self?.returnStillTokens[key] == token { self?.returnStillTokens[key] = nil }
                return
            }
            let still = ReturnStill(image: UIImage(cgImage: frame.image), seconds: frame.seconds)
            self?.keepReturnStill(still, for: key, token: token)
        }
    }

    /// One frame of `asset` at `time`, at a kept frame's size, off the main
    /// actor (the cached asset reads through the byte cache's queue).
    private nonisolated static func frame(
        of source: ReturnStillSource, at time: CMTime, upright: Bool
    ) async -> (image: CGImage, seconds: Double)? {
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = upright
        generator.maximumSize = CGSize(width: returnStillMaxPixels, height: returnStillMaxPixels)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let generated = try? await generator.image(at: time) else { return nil }
        return (generated.image, generated.actualTime.seconds)
    }


    /// How many return players are parked right now.
    public var returnPlaybackCount: Int { returnPlaybacks.count }

    /// Whether a return player is parked for `url` under `scope`.
    public func hasReturnPlayback(of url: URL, scope: String, owner: ObjectIdentifier? = nil) -> Bool {
        returnPlaybacks.contains { $0.key == ReturnKey(scope: scope, url: url, owner: owner) }
    }

    /// Parks a dedicated, paused player on `url` at `seconds`, for a close to
    /// resume later. Replaces any player already parked for the same clip, and
    /// evicts the oldest parked player beyond `returnPlaybackCapacity`.
    ///
    /// With a byte cache (#895), the clip's cached ranges around `seconds`
    /// are pinned while it is parked (`VideoByteCache.pinRanges`), and the
    /// parked frame is kept past the player (`returnStill(of:scope:owner:)`).
    ///
    /// - Parameter duration: the clip's length, to place `seconds` in the
    ///   file for the pin. Nil reads it from a player of this pool already
    ///   playing the clip (the tile's, at the tap).
    ///
    /// Returns whether a player was parked: false when the asset could not be
    /// resolved, or when a release or newer park overtook this one.
    @discardableResult
    public func parkReturnPlayback(
        of url: URL, scope: String, owner: ObjectIdentifier? = nil,
        at seconds: Double, duration: Double? = nil, peakBitRate: Double = 0
    ) async -> Bool {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        releaseReturnPlayback(of: url, scope: scope, owner: owner)
        let token = nextGenerationToken()
        returnParkTokens[key] = token
        // Read now, while the tile's player is certainly still running.
        let length = duration ?? playingDuration(of: url, scope: scope)
        let resolved: URL
        do {
            resolved = try await source.playableURL(for: url)
        } catch {
            VideoPlaybackTrace.emit("return park resolve FAILED \(url.lastPathComponent): \(error)")
            if returnParkTokens[key] == token { returnParkTokens[key] = nil }
            return false
        }
        guard returnParkTokens[key] == token else { return false }
        returnParkTokens[key] = nil
        let item = makeItem(for: resolved, priority: .next)
        item.preferredPeakBitRate = peakBitRate
        let player = idlePlayers.popLast() ?? AVPlayer()
        itemCreations += 1
        installLoop(for: player, item: item)
        settle(nil, on: item, of: player)
        player.replaceCurrentItem(with: item)
        let parkedAt = CMTime(seconds: seconds.isFinite ? max(seconds, 0) : 0, preferredTimescale: 600)
        if parkedAt.seconds > 0 {
            player.seek(to: parkedAt, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        renderer(for: player)?.setItem(item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        var holder: VideoRenderView?
        if VideoRenderFlags.usesSampleBufferLayer {
            let view = VideoRenderView()
            #if DEBUG
            view.debugLabel = "return-holder"
            #endif
            bind(player, to: view)
            holder = view
        }
        // Play-then-pause, as `prewarm` does and for its reason: a player that
        // never ran has decoded nothing, so there would be no frame to prime a
        // landing surface with.
        player.play()
        // The anchor is where the clip was PARKED, stated rather than read
        // back: the seek above may still be in flight.
        pausedAnchors[ObjectIdentifier(player)] = parkedAt
        player.pause()
        let fraction: Double? = length.flatMap { $0 > 0 && $0.isFinite ? parkedAt.seconds / $0 : nil }
        let pin = byteCache?.pinRanges(of: resolved, near: fraction)
        returnPlaybacks.append(ReturnPlayback(key: key, player: player, parkedAt: parkedAt, holder: holder, pin: pin))
        returnStillTokens[key] = token
        VideoProducerLog.emit("RETURN PARK \(VideoProducerLog.name(player)) \(url.lastPathComponent)"
            + String(format: " at=%.2fs", seconds))
        while returnPlaybacks.count > Self.returnPlaybackCapacity {
            let evicted = returnPlaybacks.removeFirst()
            VideoProducerLog.emit("RETURN EVICT \(VideoProducerLog.name(evicted.player)) "
                + evicted.key.url.lastPathComponent)
            retireKeepingStill(evicted)
        }
        if holder != nil {
            releaseHolderOnceDecoded(player, at: parkedAt)
        } else {
            // No renderer to wait for (`-avplayer-render`): from the asset.
            captureReturnStill(of: player, for: key, at: parkedAt)
        }
        return true
    }

    /// The length of the clip a surface of this pool is playing for `url`
    /// under `scope`, if any is and its item knows it.
    private func playingDuration(of url: URL, scope: String) -> Double? {
        for (key, player) in activePlayers where playingURL[key] == url && playingScope[key] == scope {
            guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { continue }
            return seconds
        }
        return nil
    }

    /// Lets the holder go once the PARKED frame exists (not the item's first
    /// frame, decoded before the seek lands), or after a ceiling.
    /// Shared by the return ledger and the lookahead ledger (#895): both keep
    /// a paused player behind a holder until its frame exists.
    func releaseHolderOnceDecoded(_ player: AVPlayer, at parkedAt: CMTime) {
        Task { @MainActor [weak self] in
            for _ in 0..<Self.returnHolderPolls {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                guard isHeldInLedger(player) else { return }
                guard let frameTime = renderers[ObjectIdentifier(player)]?.currentFrameTime,
                      frameTime.isValid, abs(frameTime.seconds - parkedAt.seconds) < 0.5
                else { continue }
                detachLedgerHolder(of: player, decoded: true)
                return
            }
            self?.detachLedgerHolder(of: player, decoded: false)
        }
    }

    private func isHeldInLedger(_ player: AVPlayer) -> Bool {
        returnPlaybacks.contains { $0.player === player } || lookaheadPlaybacks.contains { $0.player === player }
    }

    private func detachLedgerHolder(of player: AVPlayer, decoded: Bool) {
        if let index = returnPlaybacks.firstIndex(where: { $0.player === player }) {
            returnPlaybacks[index].holder?.detach(reason: decoded ? "returnHolderDecoded" : "returnHolderCeiling")
            returnPlaybacks[index].holder = nil
            let entry = returnPlaybacks[index]
            captureReturnStill(of: player, for: entry.key, at: entry.parkedAt)
        } else if let index = lookaheadPlaybacks.firstIndex(where: { $0.player === player }) {
            lookaheadPlaybacks[index].holder?.detach(reason: decoded ? "lookaheadHolderDecoded" : "lookaheadHolderCeiling")
            lookaheadPlaybacks[index].holder = nil
        }
    }

    /// 3 s at 50 ms: a cold item decodes its first frame well inside that.
    private static let returnHolderPolls = 60

    /// Shows the parked clip in `view` and resumes it from where it was
    /// parked: the close's arriving picture. `view` joins the player as a
    /// surface holding no loan; the player stays parked until a landing
    /// claims it (`transferOwnership(of:drawnBy:to:)`) or its owner releases
    /// it. Returns false when nothing is parked for this clip (never parked,
    /// evicted, or released).
    @discardableResult
    public func attachReturnSurface(
        _ view: VideoRenderView, of url: URL, scope: String, owner: ObjectIdentifier? = nil
    ) -> Bool {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        guard let index = returnPlaybacks.firstIndex(where: { $0.key == key }) else { return false }
        // Used: it moves to the young end of the eviction order.
        let entry = returnPlaybacks.remove(at: index)
        returnPlaybacks.append(entry)
        // Primed with the parked frame on attach, so it draws at once.
        bind(entry.player, to: view)
        // Resumed by hand, NOT through `setPaused(false, in:)`: that door
        // flushes the surface's pending samples, which here is the very frame
        // the attach just primed, and the arriving picture would wait a decode
        // with the tile's poster showing through. The anchor rule is kept.
        let playerKey = ObjectIdentifier(entry.player)
        if let anchor = pausedAnchors.removeValue(forKey: playerKey), anchor.isValid {
            let drift = (entry.player.currentTime() - anchor).seconds
            if drift.isFinite, abs(drift) > 0.15 {
                entry.player.seek(to: anchor, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        entry.player.play()
        VideoProducerLog.emit("RETURN RESUME \(VideoProducerLog.name(entry.player)) -> \(view.debugProducerName)")
        return true
    }

    /// Pauses a parked clip again: a close that resumed it was abandoned, and
    /// the post stays open. The player keeps its place in the ledger.
    public func pauseReturnPlayback(of url: URL, scope: String, owner: ObjectIdentifier? = nil) {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        guard let entry = returnPlaybacks.first(where: { $0.key == key })
        else { return }
        pausedAnchors[ObjectIdentifier(entry.player)] = entry.player.currentTime()
        entry.player.pause()
    }

    /// Releases the player parked for this clip, if any, and cancels a park
    /// still resolving.
    public func releaseReturnPlayback(of url: URL, scope: String, owner: ObjectIdentifier? = nil) {
        let key = ReturnKey(scope: scope, url: url, owner: owner)
        returnParkTokens[key] = nil
        // Its owner is done with it: no close will ask for its frame either.
        dropReturnStill(for: key)
        guard let index = returnPlaybacks.firstIndex(where: { $0.key == key }) else { return }
        retire(returnPlaybacks.remove(at: index))
    }

    /// Releases every return player: a memory warning, or a caller that knows
    /// none of them can be landed on any more.
    public func releaseAllReturnPlaybacks() {
        returnParkTokens.removeAll()
        let released = returnPlaybacks
        returnPlaybacks.removeAll()
        // Their frames stay: under memory pressure a close lands on the parked
        // frame instead of its clip (#895).
        for entry in released { retireKeepingStill(entry) }
    }

    /// Memory pressure or the background (#898, the device cache's memory
    /// signals): drops what the pool can build again, and keeps every player
    /// a surface is showing. The idle players go (the next loan mints one),
    /// with their renderers; so do the scrubber's frame generators (each holds
    /// an open reader) and the return players (a close then lands on a still).
    public func releaseIdleMemory() {
        releaseAllReturnPlaybacks()
        frameGenerators.removeAll()
        for player in idlePlayers {
            renderers.removeValue(forKey: ObjectIdentifier(player))
        }
        idlePlayers.removeAll()
    }

    /// Retires a player whose close may still come: its frame is captured
    /// first if it was not yet (a renderer's buffer, or the item's asset,
    /// both gone after `retire`).
    private func retireKeepingStill(_ entry: ReturnPlayback) {
        captureReturnStill(of: entry.player, for: entry.key, at: entry.parkedAt)
        retire(entry)
    }

    func retire(_ entry: ReturnPlayback) {
        entry.pin?.release()
        entry.holder?.detach(reason: "returnReleased")
        // Every surface still joined to it (a card that never landed) is
        // dropped by the renderer's invalidation inside `retire`.
        retire(entry.player)
    }

    /// Takes `player` out of the return ledger for a landing that is about to
    /// own it. Returns the clip it was parked for, or nil when it is not a
    /// return player.
    func claimReturnPlayback(_ player: AVPlayer) -> ReturnKey? {
        guard let index = returnPlaybacks.firstIndex(where: { $0.player === player }) else { return nil }
        let entry = returnPlaybacks.remove(at: index)
        entry.holder?.detach(reason: "returnClaimed")
        // An ordinary loan from here on: its loader pins what it reads, and
        // the clip itself is drawing, so its frame is not needed either.
        entry.pin?.release()
        dropReturnStill(for: entry.key)
        VideoProducerLog.emit("RETURN CLAIM \(VideoProducerLog.name(player)) \(entry.key.url.lastPathComponent)")
        return entry.key
    }
}
