import AVFoundation
import CacheKit
import CoreMedia
import Foundation
import UIKit

// Lookahead playback (#895): the players kept ready for the posts ahead
extension VideoPlaybackController {
    // MARK: - Lookahead playback (#895)

    /// How many lookahead players may be kept at once: the vertical feed's
    /// +1 (warmed) and −1 (kept). With the playing page's own player that is
    /// three, the pool every short-video feed runs and well under the device's
    /// decoder ceiling (Apple: no good way past 4–6).
    public static let lookaheadCapacity = 2

    /// The read-ahead a lookahead player's item may buffer while it waits:
    /// ~5 s, Media3's +1. The playing item goes back to the default (0, the
    /// system decides) when it is adopted.
    public static let lookaheadForwardBufferSeconds: TimeInterval = 5

    /// One player kept ready around the vertical feed's page.
    struct LookaheadPlayback {
        let key: ReturnKey
        let player: AVPlayer
        /// As a return player's: pulls the first frame in sample-buffer mode,
        /// let go once it is decoded.
        var holder: VideoRenderView?
    }


    public var lookaheadPlaybackCount: Int { lookaheadPlaybacks.count }

    public func hasLookaheadPlayback(of url: URL, scope: String) -> Bool {
        lookaheadPlaybacks.contains { $0.key == ReturnKey(scope: scope, url: url, owner: nil) }
    }

    /// A lookahead for the vertical feed, planning its preload through this
    /// pool and the byte cache. Nil without a byte cache: the feed then only
    /// prerolls its neighbours, as before.
    public func makeLookahead(name: String) -> VideoLookahead? {
        guard let byteCache else { return nil }
        return VideoLookahead(playback: self, cache: byteCache, name: name)
    }

    /// Declares the clips the vertical feed wants kept ready: `next` is
    /// warmed (when `warmNext`, unless another surface already plays it),
    /// either is kept when its page lets go of it (`stop(_:keepingLookahead:)`),
    /// and every other lookahead player is given back. Idempotent.
    ///
    /// `warmNext` false still WANTS `next`: the page just swiped back from is
    /// the new +1, and its player is kept when the page lets go, while a
    /// fresh warm-up waits for the playing clip to be under way.
    ///
    /// `client` names the lookahead asking (one per feed screen): a screen
    /// covered by another feed clears only what it set (`clearLookahead`).
    public func setLookahead(
        next: VideoLookaheadItem?, previous: VideoLookaheadItem?, warmNext: Bool = true,
        client: ObjectIdentifier? = nil
    ) {
        lookaheadClient = client
        let wanted = [next, previous].compactMap { $0.map { ReturnKey(scope: $0.scope, url: $0.url, owner: nil) } }
        if releasedNext != next.map({ ReturnKey(scope: $0.scope, url: $0.url, owner: nil) }) { releasedNext = nil }
        lookaheadWanted = wanted
        lookaheadTokens = lookaheadTokens.filter { wanted.contains($0.key) }
        let unwanted = lookaheadPlaybacks.filter { !wanted.contains($0.key) }
        lookaheadPlaybacks.removeAll { !wanted.contains($0.key) }
        for entry in unwanted { retireLookahead(entry) }
        if let next, warmNext { warmLookahead(next) }
    }

    /// Gives back every lookahead player, if `client` is the lookahead that
    /// set them: a feed leaving the screen does not clear the one pushed over
    /// it.
    public func clearLookahead(for client: ObjectIdentifier) {
        guard lookaheadClient == nil || lookaheadClient == client else { return }
        setLookahead(next: nil, previous: nil, warmNext: false)
    }


    /// Stops `view`, unless the clip it plays is one the lookahead wants kept
    /// (the page just left, −1): its player is then kept, paused where it
    /// stands, for a swipe back to adopt. Returns whether it was kept.
    ///
    /// Kept only when this view holds the player alone: a player another
    /// surface still uses is not this page's to keep, and goes through `stop`.
    @discardableResult
    public func stop(_ view: VideoRenderView, keepingLookahead: Bool) -> Bool {
        forgetDeadSurfaces()
        let key = ObjectIdentifier(view)
        guard keepingLookahead, let player = activePlayers[key], let url = playingURL[key],
              let scope = playingScope[key]
        else {
            stop(view)
            return false
        }
        let entryKey = ReturnKey(scope: scope, url: url, owner: nil)
        let sharedElsewhere = activePlayers.contains { $0.key != key && $0.value === player }
            || parked.map { $0.player === player } ?? false
        guard lookaheadWanted.contains(entryKey), !sharedElsewhere,
              !lookaheadPlaybacks.contains(where: { $0.key == entryKey }),
              player.currentItem.map({ $0.status != .failed }) ?? false
        else {
            stop(view)
            return false
        }
        VideoPlaybackTrace.emit("stop keeping lookahead \(url.lastPathComponent)")
        lookaheadTokens[entryKey] = nil
        view.detach(reason: "lookahead.keep")
        surfaces[key] = nil
        playingURL[key] = nil
        playingScope[key] = nil
        generation[key] = nil
        activePlayers[key] = nil
        pausedAnchors[ObjectIdentifier(player)] = player.currentTime()
        player.pause()
        // Heard no more, and off the Lock Screen: it is a page nobody is on.
        forgetSound(of: player)
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = Self.lookaheadForwardBufferSeconds
            byteCache?.setPriority(.next, of: item.asset)
        }
        lookaheadPlaybacks.append(LookaheadPlayback(key: entryKey, player: player, holder: nil))
        let keptName: String = VideoProducerLog.name(player)
        let keptFile: String = url.lastPathComponent
        VideoProducerLog.emit("LOOKAHEAD KEEP \(keptName) \(keptFile)")
        trimLookaheadPlaybacks()
        return true
    }

    /// Gives back every lookahead player: a memory warning.
    ///
    /// The clip that was warmed is not warmed again for the page it was
    /// warmed for: the lookahead asks again every tick, and a warm-up minted
    /// half a second after a memory warning would undo it. The next page's
    /// `+1` warms as usual.
    public func releaseAllLookaheadPlaybacks() {
        releasedNext = lookaheadWanted.first
        lookaheadTokens.removeAll()
        let released = lookaheadPlaybacks
        lookaheadPlaybacks.removeAll()
        for entry in released { retireLookahead(entry) }
    }

    /// The vertical feed's playing clip, as its lookahead reads it.
    public func playingState(of url: URL, scope: String?) -> VideoPlayingState {
        guard let item = sharedActivePlayer(playing: url, scope: scope)?.currentItem else { return .notReady }
        switch item.status {
        case .failed:
            return .failed
        case .readyToPlay:
            return .ready(VideoBufferStatus(
                current: item.currentTime().seconds, duration: item.duration.seconds,
                loaded: item.loadedTimeRanges.map(\.timeRangeValue)
            ))
        default:
            return .notReady
        }
    }

    /// The URL a player opens for `url`, as `play` resolves it: what the byte
    /// cache keys and preloads.
    public func playableURL(for url: URL) async throws -> URL {
        try await source.playableURL(for: url)
    }


    private func warmLookahead(_ item: VideoLookaheadItem) {
        let key = ReturnKey(scope: item.scope, url: item.url, owner: nil)
        guard releasedNext != key, lookaheadTokens[key] == nil,
              !lookaheadPlaybacks.contains(where: { $0.key == key }),
              sharedActivePlayer(playing: item.url, scope: item.scope) == nil,
              parked.map({ $0.url != item.url }) ?? true
        else { return }
        let token = nextGenerationToken()
        lookaheadTokens[key] = token
        Task { [weak self] in await self?.mintLookahead(item, key: key, token: token) }
    }

    private func mintLookahead(_ item: VideoLookaheadItem, key: ReturnKey, token: Int) async {
        let resolved: URL
        do {
            resolved = try await source.playableURL(for: item.url)
        } catch {
            VideoPlaybackTrace.emit("lookahead resolve FAILED \(item.url.lastPathComponent): \(error)")
            if lookaheadTokens[key] == token { lookaheadTokens[key] = nil }
            return
        }
        guard lookaheadTokens[key] == token else { return }
        lookaheadTokens[key] = nil
        // Asked again after the await: the page may have started it meanwhile.
        guard lookaheadWanted.contains(key),
              sharedActivePlayer(playing: item.url, scope: item.scope) == nil,
              !lookaheadPlaybacks.contains(where: { $0.key == key })
        else { return }
        let playerItem = makeItem(for: resolved, priority: .next)
        playerItem.preferredForwardBufferDuration = Self.lookaheadForwardBufferSeconds
        let player = idlePlayers.popLast() ?? AVPlayer()
        itemCreations += 1
        installLoop(for: player, item: playerItem)
        settle(nil, on: playerItem, of: player)
        player.replaceCurrentItem(with: playerItem)
        // A position filed for this post (a stop, a flight) is where its page
        // will start: warm THAT frame. Read, not spent: the adoption spends it.
        let start = resumeTimes[ResumeKey(scope: item.scope, url: item.url)] ?? .zero
        if start.seconds > 0 {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        renderer(for: player)?.setItem(playerItem)
        player.isMuted = true
        player.actionAtItemEnd = .none
        var holder: VideoRenderView?
        if VideoRenderFlags.usesSampleBufferLayer {
            let view = VideoRenderView()
            #if DEBUG
            view.debugLabel = "lookahead-holder"
            #endif
            bind(player, to: view)
            holder = view
        }
        // Play-then-pause, as `prewarm` does: a player that never ran has
        // decoded nothing, and the first frame is the point.
        player.play()
        pausedAnchors[ObjectIdentifier(player)] = start
        player.pause()
        lookaheadPlaybacks.append(LookaheadPlayback(key: key, player: player, holder: holder))
        let warmName: String = VideoProducerLog.name(player)
        let warmFile: String = item.url.lastPathComponent
        let warmAddress: String = item.url.absoluteString
        let resolvedFile: String = resolved.lastPathComponent
        VideoProducerLog.emit("LOOKAHEAD WARM \(warmName) \(warmFile)")
        VideoCacheAudit.emit("lookahead player warmed \(warmAddress) -> \(resolvedFile)")
        trimLookaheadPlaybacks()
        if holder != nil { releaseHolderOnceDecoded(player, at: start) }
    }

    /// Takes the lookahead player kept for this clip and post out of the
    /// ledger, for `play` to adopt.
    func takeLookaheadPlayback(of url: URL, scope: String) -> LookaheadPlayback? {
        let key = ReturnKey(scope: scope, url: url, owner: nil)
        guard let index = lookaheadPlaybacks.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = lookaheadPlaybacks.remove(at: index)
        guard entry.player.currentItem.map({ $0.status != .failed }) ?? false else {
            retireLookahead(entry)
            return nil
        }
        return entry
    }

    /// Binds an adopted lookahead player to `view` and starts it where it
    /// stands: the warmed first frame, or the playhead the page left.
    func adoptLookahead(
        _ entry: LookaheadPlayback, in view: VideoRenderView, key: ObjectIdentifier,
        url: URL, scope: String, peakBitRate: Double
    ) {
        entry.holder?.detach(reason: "lookaheadAdopted")
        detach(key: key, view: view)
        let player = entry.player
        if let item = player.currentItem {
            item.preferredForwardBufferDuration = 0
            item.preferredPeakBitRate = peakBitRate
            byteCache?.setPriority(.visible, of: item.asset)
        }
        bind(player, to: view)
        activePlayers[key] = player
        surfaces[key] = WeakSurface(view: view)
        playingURL[key] = url
        playingScope[key] = scope
        let playerKey = ObjectIdentifier(player)
        var target = pausedAnchors.removeValue(forKey: playerKey)
        // A start filed since (a flight's frame) wins over where it waited.
        if let filed = takeResume(scope: scope, url: url) { target = filed }
        if let target, target.isValid {
            let drift = (player.currentTime() - target).seconds
            if drift.isFinite, abs(drift) > 0.15 {
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }
        }
        let name: String = VideoProducerLog.name(player)
        let owner: String = view.debugProducerName
        let file: String = url.lastPathComponent
        VideoProducerLog.emit("LOOKAHEAD ADOPT \(name) owner=\(owner) \(file)")
        VideoCacheAudit.emit("lookahead player adopted \(url.absoluteString)")
        player.play()
    }

    private func trimLookaheadPlaybacks() {
        while lookaheadPlaybacks.count > Self.lookaheadCapacity {
            retireLookahead(lookaheadPlaybacks.removeFirst())
        }
    }

    private func retireLookahead(_ entry: LookaheadPlayback) {
        entry.holder?.detach(reason: "lookaheadReleased")
        let releasedName: String = VideoProducerLog.name(entry.player)
        let releasedFile: String = entry.key.url.lastPathComponent
        VideoProducerLog.emit("LOOKAHEAD RELEASE \(releasedName) \(releasedFile)")
        // Where the viewer left it, for the next time this post opens.
        rememberResume(scope: entry.key.scope, url: entry.key.url, player: entry.player)
        retire(entry.player)
    }

    /// Re-caps the bit rate of the item already playing in `view`, in bits per
    /// second; `0` lifts the cap entirely.
    ///
    /// **This mutates the live `AVPlayerItem` and never replaces it**, which is
    /// the entire point. The playhead belongs to the item, so swapping items to
    /// change quality would reset `currentTime` to zero — the restart the hero
    /// transition exists to avoid. Changing the cap in place lets ABR climb to a
    /// higher rung at its next switch point while the clock keeps running, which
    /// is how a grid tile capped to the ladder's floor becomes a full-quality
    /// full-screen player without a visible break.
    ///
    /// A no-op when `view` has no active player. See
    /// `dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md` §0.3.
    public func setPeakBitRate(_ peakBitRate: Double, in view: VideoRenderView) {
        activePlayers[ObjectIdentifier(view)]?.currentItem?.preferredPeakBitRate = peakBitRate
    }

    /// Unbinds `view` and returns its player to the pool. Also cancels any
    /// in-flight `play` for the view.
    /// ⚠️ DROPS EVERY KEY WHOSE SURFACE IS GONE, and gives its player back.
    ///
    /// Called before any lookup that could ALIAS — see `surfaces`. The window
    /// is not theoretical: a render view is deallocated with its cell, and
    /// nothing in this file is notified, so the only honest moment to notice is
    /// the next question somebody asks.
    ///
    /// The player is released exactly as `detach` would, minus the view calls a
    /// deallocated view cannot receive: paused, un-looped, and returned to the
    /// idle cache — unless another surface is still rendering it, which is the
    /// same "one leaving, not the end of a playback" rule.
    func forgetDeadSurfaces() {
        let dead = surfaces.filter { $0.value.view == nil }.map(\.key)
        guard !dead.isEmpty else { return }
        for key in dead {
            VideoPlaybackTrace.emit(
                "forget dead surface \(playingURL[key]?.lastPathComponent ?? "-")"
            )
            surfaces[key] = nil
            generation[key] = nil
            playingURL[key] = nil
            playingScope[key] = nil
            pausedSurfaces.remove(key)
            stilledSurfaces.remove(key)
            stilledPlayers[key] = nil
            guard let player = activePlayers.removeValue(forKey: key) else { continue }
            let stillInUse = activePlayers.values.contains { $0 === player }
                || parked.map { $0.player === player } ?? false
            // ⚠️ A dead owner retires its player UNDER every surface that only
            // joined it — named here, because from those surfaces' side it is
            // a picture that stopped for no reason (see `adoptSurface`).
            VideoProducerLog.emit("SWEEP dead owner \(VideoProducerLog.name(player)) "
                + (stillInUse ? "(still owned elsewhere)"
                   : "-> RETIRE with \(renderers[ObjectIdentifier(player)]?.surfaceCount ?? 0) joined surface(s)"))
            guard !stillInUse else { continue }
            retire(player)
        }
    }

    public func stop(_ view: VideoRenderView) {
        forgetDeadSurfaces()
        let key = ObjectIdentifier(view)
        VideoPlaybackTrace.emit("stop \(playingURL[key]?.lastPathComponent ?? "-")")
        // No token bump: `detach` clears the entry outright, and a cleared key
        // fails the resolution guard just as hard as a newer token would.
        detach(key: key, view: view)
    }

    /// How many DISTINCT players are currently on each asset.
    ///
    /// ⚠️ The answer should always be one. Two players on one URL means two
    /// decoders on two clocks: the surface a viewer is looking at can be bound
    /// to whichever of them a lookup happens to find, and a paused one behind a
    /// visible surface is a picture that has stopped moving for no reason the
    /// caller can see. The codebase has met this before — `startDeferredPlayback`
    /// carries a note about the cold-open race minting a second player — and it
    /// is measured here rather than reasoned about.
    public var playerCountByURL: [URL: Int] {
        var players: [URL: Set<ObjectIdentifier>] = [:]
        for (key, url) in playingURL {
            guard let player = activePlayers[key] else { continue }
            players[url, default: []].insert(ObjectIdentifier(player))
        }
        if let parked {
            players[parked.url, default: []].insert(ObjectIdentifier(parked.player))
        }
        return players.mapValues(\.count)
    }

    /// Whether the player bound to `view` is actually advancing.
    ///
    /// ⚠️ Distinct from "has a player" and from "is visible", and the gap
    /// between the three is what a frozen picture IS: a surface on screen,
    /// bound to a player, that is not moving. Paused is a legitimate state —
    /// a clip one page over is meant to be paused — so the question only means
    /// something next to whether the viewer is looking at it.
    /// Whether `view`'s player is REALLY playing, as opposed to merely not
    /// paused.
    ///
    /// ⚠️ THE DISTINCTION `isAdvancing` CANNOT MAKE, and it cost a whole round
    /// of diagnosis. `timeControlStatus != .paused` is true for
    /// `.waitingToPlayAtSpecifiedRate` — a player that has been asked to play,
    /// has bound its item, and is stalled fetching data it may never get. From
    /// outside, that is indistinguishable from playing: attached, unpaused, and
    /// showing nothing. Which is exactly the state reported as "the player is
    /// attached but the image stays frozen".
    ///
    /// `isAdvancing` keeps its meaning because callers use it to read INTENT —
    /// did a pause take, did a resume take — and intent is what they need. This
    /// answers the other question, and diagnostics should ask this one.
    public func isPlayingForReal(in view: VideoRenderView) -> Bool {
        guard !isStilled(view) else { return false }
        return activePlayers[ObjectIdentifier(view)]?.timeControlStatus == .playing
    }

    /// How fast the clip in `view` is moving right now: its rate while it
    /// really plays, and zero while it is paused, stalled or unbound.
    ///
    /// ⚠️ **`.playing` ONLY** — see `isPlayingForReal`. A stalled player has
    /// been asked for a rate it is not delivering, and a caller extrapolating
    /// from that rate would run ahead of a picture that is not moving.
    public func advancingRate(in view: VideoRenderView) -> Double {
        guard !isStilled(view), let player = watchedPlayer(in: view), player.timeControlStatus == .playing else {
            return 0
        }
        return Double(player.rate)
    }

    /// Whether the player `view` shows is asked to play and is waiting for
    /// media to do so — buffering at the start, or stalled mid-clip (#1537).
    /// Not a viewer's pause.
    public func isWaitingToPlay(in view: VideoRenderView) -> Bool {
        guard !isStilled(view) else { return false }
        return watchedPlayer(in: view)?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    public func isAdvancing(in view: VideoRenderView) -> Bool {
        guard !isStilled(view), let player = watchedPlayer(in: view) else { return false }
        return player.timeControlStatus != .paused
    }

    /// Whether `view` is already bound to a player for **this** asset.
    ///
    /// ⚠️ The question a caller must ask before starting something, or it throws
    /// away a decode it has already paid for. `play` on a surface that is
    /// already showing the URL replaces the item and begins again at zero — so
    /// arriving at a clip that was warmed for exactly this moment restarted it
    /// from the beginning, which is the opposite of the point.
    public func isBound(_ mediaURL: URL, in view: VideoRenderView) -> Bool {
        let key = ObjectIdentifier(view)
        return activePlayers[key] != nil && playingURL[key] == mediaURL
    }


    /// Whether `view` currently has a player bound to it.
    ///
    /// Exists for the carousel audit: "this cell is playing" is a fact the
    /// coordinator holds, and "this surface can draw" is a fact the pool holds,
    /// and the whole class of defects this session chased lives in the gap
    /// between the two.
    public func hasPlayer(in view: VideoRenderView) -> Bool {
        activePlayers[ObjectIdentifier(view)] != nil
    }

    /// Pauses or resumes the player rendering in `view`, without releasing it.
    ///
    /// ⚠️ Explicit, not a toggle, because this one is used for RECONCILIATION.
    /// A toggle answers "flip whatever you are", which is right for a tap and
    /// wrong for "make this match the world": two reconciles in a row would
    /// undo each other, and one missed edge leaves the state inverted for good.
    ///
    /// The loan is untouched — the player, its item and its decoded frame stay
    /// exactly where they are, which is the whole point: a paused surface keeps
    /// showing its last frame, and resuming costs nothing.
    ///
    /// Returns whether there was a player to move.
    @discardableResult
    public func setPaused(_ paused: Bool, in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        // The floating window shows its own play / pause; it is told.
        defer { if pictureInPicture?.surface === view { refreshPictureInPictureState() } }
        let key = ObjectIdentifier(view)
        if paused {
            // One clock: a pause stops every picture on the player, as it
            // always has. What changes is a LATER play by another surface
            // (`stillPausedSurfaces`).
            pausedSurfaces.insert(key)
            // ⚠️ WHERE THE PICTURE WAS, remembered — because an adaptive stream
            // does not necessarily come back to it.
            //
            // A progressive file resumes exactly where it stopped. An HLS one
            // re-anchors its timebase on resume and makes up the interval it was
            // stopped for: measured at 5x to 17.5x for seconds, with the clock
            // itself advancing 0.111s per 0.017s of real time. That is not the
            // display being wrong — playback really is somewhere else.
            pausedAnchors[ObjectIdentifier(player)] = player.currentTime()
            player.pause()
        } else {
            resumeSurface(key: key, view: view, on: player)
            // ⚠️ Whatever is queued belongs to BEFORE the pause.
            //
            // The picture resumes at the playhead, and anything still waiting in
            // the layer was decoded for a moment that has passed. Shown, those
            // frames read as the video hurrying to catch up — the effect
            // reported on a long stream, where the gap can grow, and never on a
            // ten-second one, where it wraps. Dropped, the surface holds its
            // frozen frame for one dispatch and then shows the present.
            view.flushPendingSamples()
            // ⚠️ PINNED BACK to where it was, and only when it has drifted.
            //
            // The seek is exact on both sides — a tolerant one would let the
            // player choose a keyframe further on and reintroduce the jump it is
            // there to prevent. The threshold keeps it off the common path: a
            // progressive file returns within a frame of its anchor and is left
            // alone, so this costs nothing where nothing is wrong.
            let key = ObjectIdentifier(player)
            if let anchor = pausedAnchors.removeValue(forKey: key), anchor.isValid {
                let drift = (player.currentTime() - anchor).seconds
                // ⚠️ Reported on EVERY resume, not only when it acts.
                //
                // "The re-pin never fired" and "there was never any drift to
                // pin" are the same silence, and this session has spent four
                // runs mistaking one for the other. The number is printed so the
                // next run says which — and so a threshold that turns out to be
                // wrong is visibly wrong rather than quietly inert.
                VideoPlaybackTrace.emit(String(
                    format: "resume drift=%.3fs anchor=%.3fs", drift, anchor.seconds
                ))
                if drift.isFinite, abs(drift) > 0.15 {
                    player.seek(to: anchor, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            player.play()
            stillPausedSurfaces(sharing: player, besides: key)
        }
        return true
    }

    /// The other surfaces on `player`: those holding a loan on it, those that
    /// only joined it (a hero landing's page, a mirror), and those holding a
    /// still taken from it.
    ///
    /// ⚠️ THE JOINED ONES TOO (the owner's device, 2026-10-31): a post opened
    /// from a grid tile JOINS the tile's player, with no loan of its own, and
    /// went on mirroring the profile's tile of the same post.
    func surfaces(sharing player: AVPlayer, besides key: ObjectIdentifier) -> [ObjectIdentifier: VideoRenderView] {
        var shared: [ObjectIdentifier: VideoRenderView] = [:]
        for (other, candidate) in activePlayers where other != key && candidate === player {
            if let view = surfaces[other]?.view { shared[other] = view }
        }
        for view in boundSurfaces.allObjects {
            let other = ObjectIdentifier(view)
            guard other != key else { continue }
            if view.boundPlayer === player || stilledPlayers[other]?.player === player { shared[other] = view }
        }
        return shared
    }

    /// `player` plays for `key`: every other surface on it that its owner
    /// paused holds its frame instead of mirroring the clip (#1914).
    func stillPausedSurfaces(sharing player: AVPlayer, besides key: ObjectIdentifier) {
        for (other, view) in surfaces(sharing: player, besides: key) where pausedSurfaces.contains(other) {
            holdStill(key: other, view: view)
        }
    }

    /// The surface leaving `player` was the last one playing it: if every
    /// surface left on it is paused, the player pauses too — no sound, no
    /// clock running under pictures that all hold a still.
    func pauseIfOnlyStillsRemain(on player: AVPlayer, besides key: ObjectIdentifier) {
        let remaining = surfaces(sharing: player, besides: key)
        guard !remaining.isEmpty, remaining.keys.allSatisfy({ pausedSurfaces.contains($0) }),
              player.timeControlStatus != .paused
        else { return }
        pausedAnchors[ObjectIdentifier(player)] = player.currentTime()
        player.pause()
    }

    /// `player` starts again for a surface that did not pause it: the clock
    /// moves on on purpose, so the anchor its last pause left describes a
    /// moment that is over.
    ///
    /// ⚠️ LEFT IN PLACE, IT WAS A SEEK BACK (the owner's device, 2026-10-31):
    /// the profile's tile played the post's player on for seconds, then the
    /// post resumed it, read seconds of "drift" against the anchor of its own
    /// pause, and seeked back exactly — a stutter on every hand-back from the
    /// profile to the post, and none the other way.
    func playsForAnotherSurface(_ player: AVPlayer) {
        pausedAnchors[ObjectIdentifier(player)] = nil
    }

    private func holdStill(key: ObjectIdentifier, view: VideoRenderView) {
        guard !isStilled(view), let player = watchedPlayer(in: view) else { return }
        stilledSurfaces.insert(key)
        stilledPlayers[key] = WeakPlayer(player: player)
        view.holdStill()
        VideoProducerLog.emit("STILL owner=\(view.debugProducerName) holds its frame, the player plays elsewhere")
    }

    /// A surface asked to play again: it is no longer paused, and a still it
    /// held gives way to the player.
    private func resumeSurface(key: ObjectIdentifier, view: VideoRenderView, on player: AVPlayer) {
        pausedSurfaces.remove(key)
        stilledPlayers[key] = nil
        if stilledSurfaces.remove(key) != nil {
            view.releaseStill()
            bind(player, to: view)
        }
    }

    /// Whether `view` holds a still while its player plays for another
    /// surface: to its owner, it is paused.
    private func isStilled(_ view: VideoRenderView) -> Bool {
        stilledSurfaces.contains(ObjectIdentifier(view)) && view.isHoldingStill
    }

    /// Plays the clip in `view` at `rate` — 1 is as shot, 2 twice as fast.
    ///
    /// ⚠️ **`defaultRate` FIRST, AND `rate` ONLY IF IT IS ALREADY RUNNING.**
    /// Assigning `player.rate` STARTS playback: a paused clip told to run at 2×
    /// would begin playing on the spot, which is not what "set the speed" means
    /// and would undo a pause the author asked for. `defaultRate` (iOS 16) is the
    /// rate the next `play()` will use, so the two together give "from now on,
    /// this fast" without deciding whether it is moving.
    ///
    /// ⚠️ **AND THE PITCH IS NOT THIS CALL'S TO SET.** `AVPlayerItem`'s
    /// `audioTimePitchAlgorithm` defaults to `.spectral`, which keeps a voice at
    /// its own pitch through a rate change — the same default `VideoExporter`
    /// relies on, so what the author hears in the preview is what the export
    /// produces.
    ///
    /// Returns whether there was a player to move.
    @discardableResult
    public func setRate(_ rate: Double, in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        guard rate.isFinite, rate > 0 else { return false }
        player.defaultRate = Float(rate)
        if player.timeControlStatus != .paused { player.rate = Float(rate) }
        return true
    }

    /// Changes the look the arrangement playing in `view` is drawn with, without
    /// a new item: the next composed frame wears it, and a paused frame is
    /// drawn again.
    ///
    /// ⚠️ **A BOARD, NOT A RELOAD.** Every load gives its arrangement a
    /// `VideoLiveLook` that the compositor reads on every frame; this writes it
    /// and asks the frame reader to draw the moment on screen again, which it
    /// does only while the clip is paused — a playing clip's next frames wear
    /// the look anyway, a few frames late (`ComposedFrameReader.refresh`).
    ///
    /// ⚠️ **AND THE LOAD ON ITS WAY, IF ANY, TAKES IT TOO** — its plan was made
    /// before this look, and its item would otherwise bring the old one back.
    ///
    /// Returns whether an arrangement took the look: false when nothing is
    /// bound, when the item is the file as shot (a held handle), and on the
    /// legacy layer path, which composes nothing live.
    @discardableResult
    public func setLiveLook(_ look: FrameLook, in view: VideoRenderView) -> Bool {
        let loading = loadingBoards[ObjectIdentifier(view)]
        loading?.set(look)
        guard let player = watchedPlayer(in: view), let renderer = renderer(for: player),
              let board = renderer.composedVideo?.live
        else { return loading != nil }
        board.set(look)
        renderer.refresh()
        return true
    }


    /// Where the clip `view` is drawing has got to, as a fraction of its
    /// length, with the length in seconds beside it.
    ///
    /// ⚠️ NIL IS AN ANSWER, and the caller must draw it as one. There is no
    /// playhead when there is no player, and none worth reporting while the
    /// length is unknown — a stream still resolving, or a live one that has no
    /// end at all. A bar that draws zero for those is a bar that says "at the
    /// beginning" when the truth is "not yet known", which is the reading a
    /// viewer will act on.
    ///
    /// Asked of the WATCHED player, so a page that joined a grid tile's clip
    /// answers about the picture in front of the viewer — see `watchedPlayer`.
    public func playhead(in view: VideoRenderView) -> (fraction: Double, seconds: Double)? {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return nil }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let time = item.currentTime().seconds
        guard time.isFinite else { return nil }
        return (min(max(time / duration, 0), 1), duration)
    }

    /// A still from the clip `view` is drawing, at `fraction` of its length —
    /// the picture a scrubber shows above the thumb.
    ///
    /// ⚠️ BEST EFFORT, AND NIL IS ORDINARY. Not every asset will give up a
    /// frame on demand: a stream may refuse outright, and one that obliges may
    /// take longer than the thumb waits. The caller draws nil as "no picture
    /// yet", never as an error — the time beside it is the part that always
    /// works.
    ///
    /// ⚠️ TOLERANT BY HALF A SECOND, for the reason the seek is: an exact frame
    /// means decoding forward from the nearest keyframe, and a scrubber asks
    /// again before that finishes. What the viewer is reading is roughly where
    /// they are, and the roughness is invisible at the size this is drawn.
    public func previewFrame(
        atFraction fraction: Double, in view: VideoRenderView, maximumWidth: CGFloat
    ) async -> CGImage? {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return nil }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let generator = frameGenerator(for: item.asset)
        generator.maximumSize = CGSize(width: maximumWidth * 2, height: 0)
        let seconds = duration * min(max(fraction, 0), 1)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // ⚠️ The callback form, not `image(at:)`. The async one would carry the
        // generator across an isolation boundary — it is not `Sendable`, and
        // the compiler is right to refuse. Here the generator is only touched
        // where it lives and the frame comes back through the continuation,
        // which is the shape `VideoExporter.posterImage` already uses.
        return try? await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
    }

    /// One generator per asset, kept for the length of a scrub rather than
    /// built per frame: a generator carries the reader it has already opened,
    /// and building one per request pays for that open thirty times a second.
    private func frameGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let key = ObjectIdentifier(asset)
        if let existing = frameGenerators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // Bounded: a post's clips are few, and an entry costs a reader.
        if frameGenerators.count >= 4 {
            frameGenerators.removeAll()
        }
        frameGenerators[key] = generator
        return generator
    }


    /// Moves the playhead of the clip `view` is drawing.
    ///
    /// ⚠️ TOLERANT, not exact. A finger on a scrubber asks for a new position
    /// thirty times a second and every exact seek is a decode from the nearest
    /// keyframe forward: asked exactly, the picture falls behind the thumb and
    /// then catches up in lurches. A quarter-second either way is inside what
    /// the eye reads as "there", and it lets the player answer from frames it
    /// already has.
    /// ⚠️ **`toleranceSeconds` DEFAULTS TO THE QUARTER SECOND THIS ALWAYS USED.**
    /// A scrubber that knows how fast it is moving can do better — see
    /// `MediaTimelining.seekTolerance` — but a caller that does not know should
    /// keep getting the answer that has always worked.
    public func seek(
        toFraction fraction: Double, in view: VideoRenderView, toleranceSeconds: Double = 0.25
    ) {
        guard let player = watchedPlayer(in: view), let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let seconds = duration * min(max(fraction, 0), 1)
        let tolerance = CMTime(
            seconds: max(toleranceSeconds, 0), preferredTimescale: 600
        )
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        // ⚠️ **THE PAUSE ANCHOR MOVES WITH A DELIBERATE SEEK, AND NOT MOVING IT
        // UNDID EVERY SCRUB.** `setPaused(true)` files where the picture was so
        // that a resume can pin an HLS stream back after its timebase ran on
        // while stopped. A scrub wears exactly that shape — pause, go somewhere
        // else, resume — and the resume found a difference of seconds and called
        // it drift: the clip was dragged back to where the finger went DOWN.
        // Reported from the editor's timeline as "the video goes back to its
        // starting point instead of carrying on from the cursor", reproduced in
        // `ScrubWhilePausedTests` at 0.098 after a scrub to 0.75.
        //
        // ⚠️ **MOVED, NOT DELETED — and deleting it is the fix that looks
        // right.** Retiring the anchor here would fix the scrub and quietly give
        // up the drift correction for any stream scrubbed while paused, which is
        // the case most likely to need it. Only an EXISTING anchor is updated:
        // filing one for a player that is not paused would hand
        // `setPaused(false)` an anchor it never took.
        let key = ObjectIdentifier(player)
        if pausedAnchors[key] != nil { pausedAnchors[key] = target }
        lastSeekTolerance = toleranceSeconds
        chased[key] = Chase(target: target, tolerance: tolerance)
        guard !seeking.contains(key) else { return }
        chase(player)
    }

    /// Moves the clip in `view` to `seconds` of its ITEM.
    ///
    /// ⚠️ **BY SECONDS, BECAUSE A FRACTION NEEDS A DURATION THE ITEM MAY NOT HAVE
    /// YET.** An item made from a URL does not know how long it is for its first
    /// hundred milliseconds or so (measured), and `seek(toFraction:)` drops every
    /// request made in that window — which is exactly the window after the
    /// editor has swapped in a new item and the finger is still moving. A caller
    /// that already knows where it wants to be should not need the length.
    public func seek(
        toSeconds seconds: Double, in view: VideoRenderView, toleranceSeconds: Double = 0.25
    ) {
        guard let player = watchedPlayer(in: view), player.currentItem != nil,
              seconds.isFinite
        else { return }
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        let tolerance = CMTime(seconds: max(toleranceSeconds, 0), preferredTimescale: 600)
        let key = ObjectIdentifier(player)
        if pausedAnchors[key] != nil { pausedAnchors[key] = target }
        lastSeekTolerance = toleranceSeconds
        chased[key] = Chase(target: target, tolerance: tolerance)
        guard !seeking.contains(key) else { return }
        chase(player)
    }

    /// Where the clip in `view` has got to, in seconds of its ITEM — no length
    /// needed, for the reason `seek(toSeconds:)` needs none.
    public func playheadSeconds(in view: VideoRenderView) -> Double? {
        guard let item = watchedPlayer(in: view)?.currentItem else { return nil }
        let seconds = item.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    /// The length of the clip in `view`, in seconds, once its item knows it.
    public func durationSeconds(in view: VideoRenderView) -> Double? {
        guard let seconds = watchedPlayer(in: view)?.currentItem?.duration.seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Shows the FILE as shot in `view`, at once, in place of whatever it is
    /// running — the editor's view of a trim handle being dragged, which may be
    /// standing on film the loaded arrangement does not contain.
    ///
    /// ⚠️ **SYNCHRONOUS, AND THAT IS THE POINT.** An asynchronous swap to the
    /// file could land AFTER the release that should have replaced it with the
    /// new arrangement, and leave the editor showing raw film for good. Nothing
    /// here waits: the URL must be one this controller's source resolves to
    /// itself (the editor's files are local), and a surface with no player is
    /// left alone.
    ///
    /// Returns whether there was a player to swap.
    @discardableResult
    public func showAsShot(_ file: URL, in view: VideoRenderView, at seconds: Double) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        let item = AVPlayerItem(asset: asShotAsset(file))
        item.audioTimePitchAlgorithm = .spectral
        // ⚠️ UPRIGHT, FROM THE TURN THE LAST LOAD OF THIS FILE WORKED OUT. It
        // cannot be built here: the swap is synchronous on purpose.
        var composed: ComposedVideo?
        if let known = asShotOrientation, known.url == file {
            composed = present(known.composed, on: item)
        } else {
            VideoPlaybackTrace.emit("showAsShot without an orientation for \(file.lastPathComponent)")
        }
        swap(
            item, into: player, at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
            composing: composed
        )
        return true
    }

    /// ⚠️ ONE ASSET PER FILE, KEPT: an asset that has already read its header
    /// hands a new item its length at once, which is the difference between a
    /// swapped-in file that answers the next seek and one that drops it.
    func asShotAsset(_ file: URL) -> AVURLAsset {
        if let cached = asShot, cached.url == file { return cached }
        let asset = AVURLAsset(url: file)
        asShot = asset
        return asset
    }


    /// ⚠️ **THE PREVIEW IS COMPOSED AT MOST THIS LARGE.** The canvas is a phone
    /// screen; composing a 4K frame to show it at a third of its width would
    /// spend the compositor's whole budget on pixels nobody sees.
    static let previewLongestSide: CGFloat = 1280

    /// Puts a composed arrangement where this render path can draw it.
    ///
    /// ⚠️ **THE SAMPLE-BUFFER PATH READS IT; ONLY THE LEGACY LAYER PATH HANDS IT
    /// TO THE ITEM.** An item carrying a video composition fails to play on the
    /// iOS 27 simulator the moment anything renders it (`ComposedFrameReader`
    /// has the measurement), so the item itself stays plain and its renderer
    /// composes the pictures. `AVPlayerLayer` has no such hook: the legacy path
    /// keeps the old assignment, and with it the old failure.
    ///
    /// Returns what the renderer must compose, if anything.
    func present(_ composed: ComposedVideo?, on item: AVPlayerItem) -> ComposedVideo? {
        guard let composed else { return nil }
        guard VideoRenderFlags.usesSampleBufferLayer else {
            item.videoComposition = composed.composition
            return nil
        }
        return composed
    }

    /// Where a scrub wants the picture next, waiting for the current seek to
    /// finish.
    struct Chase {
        let target: CMTime
        let tolerance: CMTime
    }


    /// ⚠️ **ONE SEEK IN FLIGHT, ALWAYS CHASING THE LATEST POSITION — AND ASKING
    /// SIXTY TIMES A SECOND WITHOUT THIS IS WHY SCRUBBING LURCHED.** A new
    /// `seek` CANCELS the one still running. A finger on the track produces a
    /// sample per vsync, so each request killed its predecessor and almost none
    /// ever landed: the picture sat still and then jumped, which is exactly what
    /// was reported — "if I scroll fast the video jumps instead of progressing
    /// frame by frame", and worse in reverse, where every frame costs a decode
    /// forward from the previous keyframe.
    ///
    /// This is Apple's documented scrubbing shape (their sample code calls the
    /// stored position `chaseTime`): record where the finger is now, and when the
    /// seek in flight reports back, go to wherever the finger has since got to.
    /// Every request is honoured — either by being seeked to, or by being
    /// superseded by a newer one — and none is cancelled midway.
    ///
    /// ⚠️ **THE COMPLETION HANDLER IS `NS_SWIFT_SENDABLE` AND
    /// `NS_SWIFT_NONISOLATED`** — checked in `AVPlayer.h`, not assumed — so it
    /// runs off the main actor and the hop below is required rather than
    /// defensive. `PhotosMediaLibrary.videoFile` records what happens when a
    /// framework is NOT annotated this way: the compiler accepts a main-actor
    /// closure and the process traps at runtime. Here the compiler refuses
    /// outright, which is the annotation doing its job.
    private func chase(_ player: AVPlayer) {
        let key = ObjectIdentifier(player)
        guard let wanted = chased.removeValue(forKey: key) else {
            seeking.remove(key)
            settle(key)
            return
        }
        seeking.insert(key)
        let item = player.currentItem.map(ObjectIdentifier.init)
        player.seek(
            to: wanted.target,
            toleranceBefore: wanted.tolerance, toleranceAfter: wanted.tolerance
        ) { @Sendable [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player else { return }
                // ⚠️ A SEEK THAT WAS RUNNING ON AN ITEM WHICH HAS SINCE BEEN
                // SWAPPED OUT REPORTS BACK LATE — measured: after the new item's
                // own seek has landed. It speaks for a clock that is gone, and
                // letting it clear `seeking` would let a second seek start while
                // the new item's first is still in flight.
                guard player.currentItem.map(ObjectIdentifier.init) == item else {
                    // Nobody waiting on this clock is waiting on anything real
                    // any more; leaving them parked would strand them for good.
                    self.settle(key)
                    return
                }
                if finished { self.seeksLanded += 1 } else { self.seeksCancelled += 1 }
                if self.chased[key] == nil {
                    self.seeking.remove(key)
                    self.settle(key)
                } else {
                    self.chase(player)
                }
            }
        }
    }

    /// Runs `body` once the clip in `view` has no seek in flight and none
    /// waiting — at once when it has none now, or when there is no player.
    ///
    /// ⚠️ **THE RELEASE OF A SCRUB WAITS ON THIS, NOT ON A TIMER.** Resuming
    /// while the last seek is still decoding plays from wherever the player
    /// happens to be, and `setPaused(false)` then finds the pause anchor (which
    /// the seek moved) a long way off and seeks AGAIN — a second hop the viewer
    /// sees as the picture snapping back and forth at the moment they let go.
    /// Resumed after the landing, the anchor and the playhead agree and the
    /// clip simply carries on from under the thumb.
    public func whenSeeksSettle(in view: VideoRenderView, _ body: @escaping @MainActor () -> Void) {
        guard let player = watchedPlayer(in: view) else {
            body()
            return
        }
        let key = ObjectIdentifier(player)
        guard seeking.contains(key) || chased[key] != nil else {
            body()
            return
        }
        settleWaiters[key, default: []].append(body)
    }


    func settle(_ key: ObjectIdentifier) {
        guard let waiters = settleWaiters.removeValue(forKey: key) else { return }
        for waiter in waiters { waiter() }
    }

    /// Whether the clip in `view` is stopped. Nil when nothing is bound — which
    /// is not "playing" and not "paused", and a caller drawing a glyph has to
    /// tell the three apart.
    ///
    /// ⚠️ `timeControlStatus`, NOT `rate == 0`. A player that is buffering has a
    /// rate of zero and is not paused; drawing it as paused offers the author a
    /// play button that does nothing, because it is already trying.
    public func isPaused(in view: VideoRenderView) -> Bool? {
        guard let player = watchedPlayer(in: view) else { return nil }
        if isStilled(view) { return true }
        return player.timeControlStatus == .paused
    }

    /// Toggles play/pause for the player bound to `view` (a user tapping the
    /// full-screen cell). Returns the new paused state. No-op returning `false`
    /// when no player is active for the view (e.g. an image/text cell).
    @discardableResult
    public func togglePlayback(in view: VideoRenderView) -> Bool {
        guard let player = watchedPlayer(in: view) else { return false }
        if isStilled(view) {
            setPaused(false, in: view)
            return false
        }
        if player.timeControlStatus == .paused {
            player.play()
            return false
        } else {
            player.pause()
            return true
        }
    }

    /// Attaches the player currently rendering in `view` to `mirrorView` as an
    /// additional surface. Both layers are driven by the *same* `AVPlayer`, so
    /// they show the same frame with no clock to synchronize — the seam the
    /// hero transition uses to fly a live pin without freezing it. The mirror
    /// is passive: it holds no pool loan, and discarding `mirrorView` (or
    /// `stop(_:)` on the primary view) simply ends it. Returns whether `view`
    /// actually had a player to mirror.
    @discardableResult
    public func mirror(from view: VideoRenderView, to mirrorView: VideoRenderView) -> Bool {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return false }
        bind(player, to: mirrorView)
        return true
    }

    /// Re-asserts `view` as its own player's display surface. With multiple
    /// `AVPlayerLayer`s on one player, only the most recently attached one is
    /// guaranteed to display — after a mirror surface goes away (a cancelled
    /// hero flight), the original view reclaims the render slot. No-op if
    /// `view` has no active player.
    public func reclaim(_ view: VideoRenderView) {
        guard let player = activePlayers[ObjectIdentifier(view)] else { return }
        bind(player, to: view)
    }
}
