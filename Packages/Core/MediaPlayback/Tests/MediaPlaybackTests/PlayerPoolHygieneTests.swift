import AVFoundation
import Testing
@testable import MediaPlayback

/// The pool's bookkeeping must end when the thing it describes ends.
///
/// ⚠️ Why this suite exists: the hero flight puts every surface through
/// play → pause → donate → retire many times per minute, and three of the
/// pool's side tables survived that cycle when their subject did not:
///
/// * `pausedAnchors` — keyed by PLAYER, written on pause, removed only on
///   resume. A player retired while paused kept its anchor; pooled players are
///   reused by address, so a later clip on the same player could be seeked to
///   the PREVIOUS clip's playhead the first time it was resumed.
/// * `stallObservers` — appended per item under `-carousel-audit` and never
///   removed, each closure holding its `AVPlayerItem` strongly: every clip
///   ever played, retained for the life of the process, exactly when someone
///   is diagnosing playback.
/// * `generation` — one entry per surface ever played, cleared only by the
///   dead-surface sweep, which cannot reach a key whose surface was stopped
///   properly before it died.
///
/// None of these shows up on screen; all of them are the kind of slow leak a
/// production soak turns into a memory report with no reproduction attached.
///
/// `.serialized` because the trace flag is PROCESS-global: a test that arms it
/// suspends at an `await`, and a parallel neighbour asserting the flag-off
/// behaviour reads the armed state (seen on the first run of this suite).
@Suite(.serialized)
@MainActor
struct PlayerPoolHygieneTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("s.mp4") }

    private func pool(size: Int = 6) -> VideoPlaybackController {
        VideoPlaybackController(source: StubSource(url: stubURL), poolSize: size)
    }

    private func players(_ controller: VideoPlaybackController, on url: URL) -> Int {
        controller.playerCountByURL[url] ?? 0
    }

    // MARK: - L1: paused anchors end with the loan

    /// ⚠️ THE HAUNTING: pause, retire, re-loan — and the anchor must be gone.
    ///
    /// The anchor is keyed by the PLAYER, and the pool reuses players. One left
    /// behind by a retired loan belongs to a clip that no longer exists, and the
    /// first resume of the player's next clip would compare a fresh playhead
    /// against it — drift over the threshold by construction, so the new clip
    /// gets seeked to wherever the old one was paused.
    @Test func aRetiredPlayersPauseAnchorDoesNotHauntItsNextLoan() async {
        let controller = pool()
        let first = URL(string: "mock://video/first")!
        let second = URL(string: "mock://video/second")!
        let view = VideoRenderView()

        await controller.play(first, in: view)
        #expect(controller.setPaused(true, in: view))
        #expect(controller.debugPausedAnchorCount == 1)

        controller.stop(view)
        // The retire IS the moment: nothing else runs between a stop and the
        // player going back out on loan.
        #expect(controller.debugPausedAnchorCount == 0)

        // And the reuse is real, not assumed: the same pooled player comes back
        // out (idle cache emptied), pauses and resumes with only its OWN anchor
        // in play.
        let next = VideoRenderView()
        await controller.play(second, in: next)
        #expect(controller.idlePlayerCount == 0)
        #expect(controller.setPaused(true, in: next))
        #expect(controller.debugPausedAnchorCount == 1)
        #expect(controller.setPaused(false, in: next))
        #expect(controller.debugPausedAnchorCount == 0)
    }

    /// The legitimate case stays legitimate: two surfaces share one player and
    /// its playhead, so one of them leaving must NOT discard the anchor — the
    /// clip is still paused for the survivor. Only the end of the playback is.
    @Test func anAnchorOnASharedPlayerSurvivesOneSurfaceLeaving() async {
        let controller = pool()
        let url = URL(string: "mock://video/shared")!
        let first = VideoRenderView()
        let second = VideoRenderView()

        await controller.play(url, in: first)
        await controller.play(url, in: second)
        #expect(players(controller, on: url) == 1)
        #expect(controller.setPaused(true, in: first))
        #expect(controller.debugPausedAnchorCount == 1)

        controller.stop(first)
        #expect(controller.debugPausedAnchorCount == 1)

        controller.stop(second)
        #expect(controller.debugPausedAnchorCount == 0)
    }

    /// A cancelled flight discards its parked player — pause anchor included.
    /// The discard reaches the same retirement `stop` does, and it must leave
    /// the same nothing behind.
    @Test func discardingAParkedPlayerClearsItsAnchor() async {
        let controller = pool()
        let url = URL(string: "mock://video/parked")!
        let view = VideoRenderView()

        await controller.play(url, in: view)
        #expect(controller.setPaused(true, in: view))
        #expect(controller.parkPlayback(from: view))
        #expect(controller.debugPausedAnchorCount == 1)

        controller.discardParkedPlayback()
        #expect(controller.debugPausedAnchorCount == 0)
        // Given back, not dropped: the whole point of discarding politely.
        #expect(controller.idlePlayerCount == 1)
    }

    // MARK: - L2: stall observers end with their players

    /// ⚠️ Armed only under the audit flag — which is precisely when the table
    /// used to grow without bound, one strongly-held item per clip ever played.
    /// The diagnostic must not be the leak.
    @Test func stallObserversComeAndGoWithTheirPlayers() async {
        VideoPlaybackTrace.debugOverrideEnabled(true)
        defer { VideoPlaybackTrace.debugOverrideEnabled(false) }

        let controller = pool()
        let first = VideoRenderView()
        let second = VideoRenderView()

        for _ in 1...3 {
            await controller.play(URL(string: "mock://video/a")!, in: first)
            await controller.play(URL(string: "mock://video/b")!, in: second)
            #expect(controller.debugStallObserverCount == 2)

            controller.stop(first)
            #expect(controller.debugStallObserverCount == 1)
            controller.stop(second)
            #expect(controller.debugStallObserverCount == 0)
        }
    }

    /// Paging a surface to another clip replaces its item — and must replace
    /// its observer, not add a second. One player, one item, one observer.
    @Test func replayingASurfaceReplacesItsStallObserver() async {
        VideoPlaybackTrace.debugOverrideEnabled(true)
        defer { VideoPlaybackTrace.debugOverrideEnabled(false) }

        let controller = pool()
        let view = VideoRenderView()
        for index in 0..<4 {
            await controller.play(URL(string: "mock://video/\(index)")!, in: view)
            #expect(controller.debugStallObserverCount == 1)
        }
        controller.stop(view)
        #expect(controller.debugStallObserverCount == 0)
    }

    /// With the flag OFF the table stays empty — asserted so the suite cannot
    /// pass by never arming the thing it is about (the flag-off run and a
    /// broken removal look identical without this denominator).
    @Test func stallObserversStayEmptyWithoutTheFlag() async {
        let controller = pool()
        let view = VideoRenderView()
        await controller.play(URL(string: "mock://video/a")!, in: view)
        #expect(controller.debugStallObserverCount == 0)
        controller.stop(view)
    }

    // MARK: - L3: generation bookkeeping ends with the surface

    /// ⚠️ THE SLOW ONE: an entry per surface ever played, kept forever.
    ///
    /// `stop` bumped the token and left the entry; the dead-surface sweep only
    /// walks `surfaces`, and `stop` had already removed the key from there — so
    /// a surface stopped properly and then deallocated was exactly the one the
    /// table never let go of. Forty here; every cell, page, and flight surface
    /// of a session in production.
    @Test func generationBookkeepingEndsWithTheSurface() async {
        let controller = pool()
        for index in 0..<40 {
            let view = VideoRenderView()
            await controller.play(URL(string: "mock://video/\(index)")!, in: view)
            controller.stop(view)
        }
        #expect(controller.activePlayerCount == 0)
        #expect(controller.debugGenerationEntryCount == 0)
    }

    /// The sweep route reaches the same emptiness: a surface that dies WITHOUT
    /// stopping is noticed at the next question, and its whole ledger goes.
    @Test func theDeadSurfaceSweepAlsoEndsTheLedger() async {
        let controller = pool()
        let probe = VideoRenderView()
        do {
            let orphan = VideoRenderView()
            await controller.play(URL(string: "mock://video/orphan")!, in: orphan)
        }
        await controller.play(URL(string: "mock://video/probe")!, in: probe)
        controller.stop(probe)
        #expect(controller.debugGenerationEntryCount == 0)
    }

    /// ⚠️ WHAT THE LEDGER IS FOR must keep working once it is allowed to end:
    /// a `play` still resolving when its surface is stopped must bind nothing.
    @Test func aStaleResolutionAfterStopStillNeverBinds() async {
        let gate = GateSource(url: stubURL)
        let controller = VideoPlaybackController(source: gate)
        let view = VideoRenderView()
        let url = URL(string: "mock://video/late")!

        let pending = Task { await controller.play(url, in: view) }
        await settle { await gate.pendingCount == 1 }

        controller.stop(view)
        await gate.openNext()
        await pending.value

        #expect(!controller.hasPlayer(in: view))
        #expect(controller.activePlayerCount == 0)
        #expect(controller.itemCreations == 0)
        #expect(controller.debugGenerationEntryCount == 0)
    }

    /// ⚠️ AND THE TOKENS CAN NEVER COLLIDE. Ending an entry invites the next
    /// surface at the same key to start counting from scratch; if tokens were
    /// per-key, a resolution from before the reset could then match a token
    /// minted after it and bind stale content over a fresh request. Two gated
    /// plays across a stop pin the ordering: the old one lands on nothing, the
    /// new one lands whole.
    @Test func interleavedStalePlaysCannotAliasAFreshToken() async {
        let gate = GateSource(url: stubURL)
        let controller = VideoPlaybackController(source: gate)
        let view = VideoRenderView()
        let stale = URL(string: "mock://video/stale")!
        let fresh = URL(string: "mock://video/fresh")!

        let first = Task { await controller.play(stale, in: view) }
        await settle { await gate.pendingCount == 1 }
        controller.stop(view)

        let second = Task { await controller.play(fresh, in: view) }
        await settle { await gate.pendingCount == 2 }

        await gate.openNext()
        await first.value
        #expect(players(controller, on: stale) == 0)
        #expect(!controller.hasPlayer(in: view))

        await gate.openNext()
        await second.value
        #expect(players(controller, on: fresh) == 1)
        #expect(controller.itemCreations == 1)
    }

    // MARK: - The census at rest

    /// After a session's worth of mixed traffic, every table reads zero. This
    /// is the exact assertion the in-app hero audit makes at each settle; if it
    /// can fail here it would have failed there, with a screen in front of it.
    @Test func everyLedgerReadsZeroOnceEverythingStops() async {
        VideoPlaybackTrace.debugOverrideEnabled(true)
        defer { VideoPlaybackTrace.debugOverrideEnabled(false) }

        let controller = pool(size: 2)
        let urls = (0..<5).map { URL(string: "mock://video/\($0)")! }
        var views: [VideoRenderView] = []
        for url in urls {
            let view = VideoRenderView()
            views.append(view)
            await controller.play(url, in: view)
        }
        _ = controller.setPaused(true, in: views[1])
        #expect(controller.parkPlayback(from: views[3]))
        controller.discardParkedPlayback()
        for view in views {
            controller.stop(view)
        }

        #expect(controller.activePlayerCount == 0)
        #expect(controller.playerCountByURL.isEmpty)
        #expect(controller.debugPausedAnchorCount == 0)
        #expect(controller.debugStallObserverCount == 0)
        #expect(controller.debugGenerationEntryCount == 0)
        #expect(controller.idlePlayerCount == 2)
    }

    // MARK: - Support

    /// Condition-based settle — never a fixed sleep (the CI flake history in
    /// InboxTests is the precedent, and the gate below is an actor, so the
    /// condition itself must be async).
    private func settle(until condition: () async -> Bool, tries: Int = 4000) async {
        for _ in 0..<tries {
            if await condition() { return }
            await Task.yield()
        }
    }

    private func settle(_ condition: () async -> Bool) async {
        await settle(until: condition)
    }
}

/// Resolves every URL to one local stub, so the tests exercise the POOL rather
/// than a fetcher. Duplicated per suite by convention — there is no shared
/// test-support target.
private struct StubSource: VideoSource {
    let url: URL
    func playableURL(for mediaURL: URL) async throws -> URL { url }
}

/// A source that answers only when told to, in arrival order — the seam that
/// lets a test hold a `play` mid-resolution while the world changes under it.
private actor GateSource: VideoSource {
    private let url: URL
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(url: URL) { self.url = url }

    var pendingCount: Int { waiters.count }

    func playableURL(for mediaURL: URL) async throws -> URL {
        await withCheckedContinuation { waiters.append($0) }
        return url
    }

    func openNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
