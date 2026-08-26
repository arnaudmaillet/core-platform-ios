import AVFoundation
import Testing
@testable import MediaPlayback

/// ONE ASSET, ONE PLAYER — asserted across the transitions a gallery post puts
/// the pool through, repeatedly.
///
/// ⚠️ Why this suite exists rather than another simulator run.
///
/// The duplicate-player fault was found by an in-app auditor and then chased
/// through the simulator, where `--console-pty` stopped delivering output
/// mid-session and two runs were reported as "0 failures" from an empty log.
/// The invariant itself needs none of that: it is a property of the pool, and
/// the pool is a plain object. What the simulator can tell us is that a real
/// sequence REACHES these states; what it cannot tell us reliably is whether
/// the states are correct.
///
/// So the sequences below are written as the transitions themselves — open,
/// close, open again — and the count is asserted after every one of them
/// rather than at the end. A count checked only at the end passes on a run that
/// spent the whole session at two and happened to settle at one.
@MainActor
struct VideoPoolIdentityTests {
    private var stubURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("s.mp4") }

    private func pool(size: Int = 6) -> VideoPlaybackController {
        VideoPlaybackController(source: StubVideoSource(url: stubURL), poolSize: size)
    }

    /// The count of DISTINCT players on `url`, which is the whole invariant.
    private func players(_ controller: VideoPlaybackController, on url: URL) -> Int {
        controller.playerCountByURL[url] ?? 0
    }

    // MARK: - Surfaces that vanish

    /// ⚠️ A RENDER VIEW CAN DIE WITHOUT SAYING SO, and the pool must survive it.
    ///
    /// Every table here is keyed by `ObjectIdentifier(view)` and none of them
    /// keeps the view alive — deliberately; a pool that retained surfaces would
    /// pin whole screens. So a page torn down by a pop, or a cell released
    /// while its `play` was still resolving, leaves its player bound to a key
    /// nobody will ever call `stop` on: a decoder held for the life of the app,
    /// and an ADDRESS the allocator may hand to the next render view, which
    /// then inherits a stranger's playback.
    ///
    /// That is the reported "the new video's player disappeared and the
    /// transition shows the old one", and this is its root: nothing tells the
    /// pool a view is gone, so the next question it is asked has to be the
    /// moment it notices.
    /// ⚠️ THE PROBE IS ALLOCATED FIRST, and that is what makes this test mean
    /// something.
    ///
    /// The first version of it triggered the sweep with a throwaway
    /// `VideoRenderView()` — and passed with the sweep DISABLED, because that
    /// throwaway can land on the address the orphan just freed and clean the
    /// entry up by aliasing onto it. The very effect under test was hiding the
    /// bug from the test. A view that already exists cannot occupy an address
    /// freed after it, so this one is a genuinely independent surface.
    @Test func aSurfaceThatDiesInSilenceGivesItsPlayerBack() async {
        let controller = pool()
        let orphanURL = URL(string: "mock://video/orphan")!
        let probeURL = URL(string: "mock://video/probe")!
        let probe = VideoRenderView()
        do {
            let orphan = VideoRenderView()
            await controller.play(orphanURL, in: orphan)
            #expect(controller.activePlayerCount == 1)
        }

        // The sweep rides the ordinary calls rather than a timer: nothing tells
        // the pool a view is gone, so the next question is the moment it can
        // notice.
        await controller.play(probeURL, in: probe)

        #expect(controller.activePlayerCount == 1)
        #expect(players(controller, on: orphanURL) == 0)
        // GIVEN BACK, not merely forgotten — and the evidence is that the probe
        // is playing without the pool having minted a second player. The idle
        // cache is empty at this point precisely because the recovered one went
        // straight back out; a player dropped on the floor instead would leave
        // the same count with a decoder lost for the life of the app.
        #expect(controller.idlePlayerCount == 0)
        #expect(controller.itemCreations == 2)
    }

    /// ⚠️ AND A SURVIVING SIBLING KEEPS ITS PICTURE.
    ///
    /// The sweep reaches the same teardown `detach` does, including the rule
    /// that matters most: a player two surfaces share is not torn down when one
    /// of them leaves. Without that half, a page dying would freeze the tile
    /// behind it.
    @Test func aDyingSurfaceDoesNotStopASharedPlayback() async {
        let controller = pool()
        let url = URL(string: "mock://video/shared")!
        let survivor = VideoRenderView()
        let probe = VideoRenderView()
        await controller.play(url, in: survivor)
        do {
            let doomed = VideoRenderView()
            #expect(controller.attachSurface(doomed, to: url))
        }

        // Same rule as above: the trigger must not be able to alias the view
        // whose disappearance is under test.
        #expect(controller.attachSurface(probe, to: url))

        #expect(players(controller, on: url) == 1)
        #expect(controller.isAdvancing(in: survivor))
    }

    // MARK: - One video, opened and closed many times

    /// ⚠️ THE REPORTED SHAPE: a gallery with one clip, opened and dismissed
    /// over and over.
    ///
    /// Both routes the app can take are exercised, because the build chooses
    /// between them at runtime and only one of them was ever covered:
    ///
    /// * **park → adopt** — the page takes the tile's player whole.
    /// * **share** — the tile keeps its player and the page joins it, which is
    ///   what a paused clip on a card does while its post is open.
    @Test func oneClipKeepsOnePlayerAcrossManyOpens() async {
        let controller = pool()
        let url = URL(string: "mock://video/one")!
        let card = VideoRenderView()
        let page = VideoRenderView()

        await controller.play(url, in: card)
        #expect(players(controller, on: url) == 1)

        for _ in 1...5 {
            // Open, by the park route.
            #expect(controller.parkPlayback(from: card))
            #expect(players(controller, on: url) == 1)
            await controller.play(url, in: page)
            #expect(players(controller, on: url) == 1)

            // Close.
            #expect(controller.parkPlayback(from: page))
            #expect(players(controller, on: url) == 1)
            await controller.play(url, in: card)
            #expect(players(controller, on: url) == 1)
        }
    }

    /// The same sequence by the SHARE route: nothing is parked, the card holds
    /// its player throughout, and the page asks for the same asset.
    @Test func oneClipKeepsOnePlayerWhenBothSurfacesWantIt() async {
        let controller = pool()
        let url = URL(string: "mock://video/one")!
        let card = VideoRenderView()
        let page = VideoRenderView()

        await controller.play(url, in: card)

        for _ in 1...5 {
            await controller.play(url, in: page)
            #expect(players(controller, on: url) == 1)
            #expect(controller.activePlayer(in: page) === controller.activePlayer(in: card))

            // The post closes: its surface stops, the card's keeps playing.
            controller.stop(page)
            #expect(players(controller, on: url) == 1)
            #expect(controller.activePlayer(in: card) != nil)
            #expect(controller.isAdvancing(in: card))
        }
    }

    // MARK: - Two videos in one gallery

    /// ⚠️ TWO CLIPS, TWO PLAYERS — and never three.
    ///
    /// A mixed gallery can hold more than one, and the viewer moves between
    /// them. Each page's arrival is a `play` of a different asset on the SAME
    /// surface, which is where a naive reuse rule would either strand the first
    /// player or hand the second surface the wrong one.
    @Test func twoClipsKeepTwoPlayersAcrossPaging() async {
        let controller = pool()
        let first = URL(string: "mock://video/a")!
        let second = URL(string: "mock://video/b")!
        let card = VideoRenderView()

        for _ in 1...4 {
            await controller.play(first, in: card)
            #expect(players(controller, on: first) == 1)
            #expect(players(controller, on: second) == 0)

            await controller.play(second, in: card)
            #expect(players(controller, on: second) == 1)
            // The first asset is off the surface, so nothing is playing it.
            #expect(players(controller, on: first) == 0)
        }
    }

    /// Both clips on screen at once — a card holding one paused while the post
    /// plays the other. Two assets, two players, one apiece.
    @Test func twoClipsOnTwoSurfacesAreTwoPlayers() async {
        let controller = pool()
        let first = URL(string: "mock://video/a")!
        let second = URL(string: "mock://video/b")!
        let card = VideoRenderView()
        let page = VideoRenderView()

        await controller.play(first, in: card)
        await controller.play(second, in: page)

        #expect(players(controller, on: first) == 1)
        #expect(players(controller, on: second) == 1)
        #expect(controller.activePlayer(in: card) !== controller.activePlayer(in: page))
    }

    /// And a gallery of two, opened and closed repeatedly, ends every cycle
    /// with exactly one player per asset — the count asserted INSIDE the loop.
    @Test func aTwoClipGallerySurvivesRepeatedOpens() async {
        let controller = pool()
        let first = URL(string: "mock://video/a")!
        let second = URL(string: "mock://video/b")!
        let card = VideoRenderView()
        let page = VideoRenderView()

        for cycle in 1...6 {
            // The card rests on one clip; the post opens on the other.
            await controller.play(first, in: card)
            await controller.play(second, in: page)
            #expect(players(controller, on: first) == 1)
            #expect(players(controller, on: second) == 1)

            // The viewer pages the post onto the clip the card is holding.
            await controller.play(first, in: page)
            #expect(players(controller, on: first) == 1)
            #expect(players(controller, on: second) == 0)

            // And closes it.
            controller.stop(page)
            #expect(players(controller, on: first) == 1)
            #expect(controller.isAdvancing(in: card))
            if cycle == 6 { controller.stop(card) }
        }
        #expect(controller.playerCountByURL.isEmpty)
    }

    // MARK: - More clips than the pool holds

    /// ⚠️ `poolSize` is the IDLE CACHE, not a concurrency limit — and this is
    /// the test that says so out loud, because the name invites the other
    /// reading.
    ///
    /// Five assets on five surfaces get five players even from a pool of two:
    /// `play` mints one when the cache is empty. What the size bounds is how
    /// many are KEPT after release — the rest are dropped, which is the cost
    /// the cache exists to avoid paying during a scroll.
    @Test func moreClipsThanTheCacheStillGetTheirOwnPlayers() async {
        let controller = pool(size: 2)
        let urls = (0..<5).map { URL(string: "mock://video/\($0)")! }
        let surfaces = urls.map { _ in VideoRenderView() }

        for (url, surface) in zip(urls, surfaces) {
            await controller.play(url, in: surface)
        }

        for url in urls {
            #expect(players(controller, on: url) == 1)
        }
        #expect(controller.idlePlayerCount == 0)

        for surface in surfaces {
            controller.stop(surface)
        }
        // Two kept, three released — the cache's whole job.
        #expect(controller.idlePlayerCount == 2)
        #expect(controller.playerCountByURL.isEmpty)
    }

    /// A cache of one, driven through the same gallery cycle: still one player
    /// per asset while they are on screen, and the reuse still holds.
    @Test func aCacheOfOneStillNeverDuplicatesAnAsset() async {
        let controller = pool(size: 1)
        let url = URL(string: "mock://video/one")!
        let card = VideoRenderView()
        let page = VideoRenderView()

        for _ in 1...4 {
            await controller.play(url, in: card)
            await controller.play(url, in: page)
            #expect(players(controller, on: url) == 1)
            controller.stop(page)
            #expect(players(controller, on: url) == 1)
            controller.stop(card)
            #expect(players(controller, on: url) == 0)
        }
    }

    /// ⚠️ TWO SURFACES ASKING AT THE SAME TIME still get one player.
    ///
    /// The reuse check has to happen on BOTH sides of the URL resolution. A
    /// single check before the await let two concurrent callers through — one
    /// grid row and the page opening over it — and both minted. Measured in the
    /// app as twelve duplicates in one battery, always on the asset two
    /// surfaces reach for at once.
    @Test func twoSimultaneousPlaysOfOneAssetShareItsPlayer() async {
        let controller = pool()
        let url = URL(string: "mock://video/one")!
        let first = VideoRenderView()
        let second = VideoRenderView()

        async let a: Void = controller.play(url, in: first)
        async let b: Void = controller.play(url, in: second)
        _ = await (a, b)

        #expect(players(controller, on: url) == 1)
        #expect(controller.activePlayer(in: first) === controller.activePlayer(in: second))
    }

    // MARK: - The transitions themselves

    /// ⚠️ Every INTERMEDIATE state, not just the settled ones.
    ///
    /// A duplicate that exists only between a donation and a landing is still a
    /// duplicate: it is two decoders on one asset for the length of a flight,
    /// and the flight is exactly when the viewer is looking. So the count is
    /// asserted after each step of the handoff rather than at the end of it.
    @Test func aFlightNeverDoublesTheAsset() async {
        let controller = pool()
        let url = URL(string: "mock://video/one")!
        let card = VideoRenderView()
        let flight = VideoRenderView()
        let page = VideoRenderView()

        await controller.play(url, in: card)
        #expect(players(controller, on: url) == 1)

        // The flight card joins the same playback alongside the tile.
        #expect(controller.attachSurface(flight, alongsideSurface: card))
        #expect(players(controller, on: url) == 1)

        // The page warms its own surface on the same player…
        #expect(controller.attachSurface(page, to: url))
        #expect(players(controller, on: url) == 1)

        // …and takes the loan at the landing.
        #expect(controller.transferOwnership(of: url, to: page))
        #expect(players(controller, on: url) == 1)

        // Coming home, the tile takes it back.
        #expect(controller.transferOwnership(of: url, to: card))
        #expect(players(controller, on: url) == 1)
        #expect(controller.isAdvancing(in: card))
    }
}

/// Resolves every URL to one local stub, so the tests exercise the POOL rather
/// than a fetcher.
private struct StubVideoSource: VideoSource {
    let url: URL
    func playableURL(for mediaURL: URL) async throws -> URL { url }
}
