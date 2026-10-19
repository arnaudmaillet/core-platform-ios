import CacheKit
import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// Animated avatars (#1358, #1424): a sheet played once, by the rule, ending
/// on its last frame — the still it rests on.
@MainActor
struct AnimatedAvatarTests {
    /// A 4-frame sheet, one colour per frame, the last one green.
    nonisolated private static let sheet: AnimatedIconSheet = {
        let colors: [UIColor] = [.red, .blue, .yellow, .green]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 8), format: format).image { context in
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: index * 8, y: 0, width: 8, height: 8))
            }
        }
        return AnimatedIconSheet(sheet: image, frameCount: 4, columns: 4, frameDuration: 0.05)
    }()

    private struct OneFace: AnimatedAvatarResolving {
        let animated: URL
        func sheet(for avatarURL: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
            avatarURL == animated || avatarURL == AnimatedAvatarTests.otherFace ? AnimatedAvatarTests.sheet : nil
        }
    }

    /// A sheet avatar: the fragment says so, and there is no photo (#1444).
    nonisolated private static let face = URL(string: "https://example.com/animated.sheet#avatar-sheet")!
    private static let still = URL(string: "https://example.com/still.jpg")!
    /// A second animated face: the rounds count plays by avatar, so two
    /// players of one face are one person.
    nonisolated fileprivate static let otherFace = URL(string: "https://example.com/animated-2.sheet#avatar-sheet")!

    /// Waits for `condition` on a LOOK budget, never a wall-clock deadline:
    /// a starved CI runner took over 100 s for this suite, and a deadline
    /// can run out after a few looks while the main queue waits (the
    /// repo's rule for these waits). Returns at once when already true;
    /// false is the timeout, asserted at the wait site.
    @discardableResult
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeRegistry() -> AnimatedAvatars {
        let registry = AnimatedAvatars(registry: nil)
        registry.resolver = OneFace(animated: Self.face)
        return registry
    }

    private func color(of image: UIImage?) -> UIColor? {
        guard let cg = image?.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let info = cg.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        _ = info
        let (r, g, b) = bgra ? (bytes[2], bytes[1], bytes[0]) : (bytes[0], bytes[1], bytes[2])
        return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    @Test func theStillIsTheSheetsLastFrame() {
        let still = AnimatedAvatars.lastFrame(of: Self.sheet)
        #expect(still?.size == CGSize(width: 8, height: 8))
        var green: CGFloat = 0, red: CGFloat = 0
        color(of: still)?.getRed(&red, green: &green, blue: nil, alpha: nil)
        #expect(green > 0.9 && red < 0.1, "the still is not the last frame")
    }

    /// Rounds of a test's own: never a round of the app's (a pause it never
    /// reaches unless the test plays one itself), a short first-display beat.
    private func makeRounds(
        picks: ClosedRange<Int> = 1...1, stagger: ClosedRange<TimeInterval> = 0...0,
        firstDisplayDelay: ClosedRange<TimeInterval> = 0.05...0.05
    ) -> AnimatedAvatarRounds {
        AnimatedAvatarRounds(tuning: .init(
            picks: picks, stagger: stagger, pause: 3_600...3_600, firstDisplayDelay: firstDisplayDelay
        ))
    }

    /// Hosts a player in a window, its avatar resolved.
    private func hosted(
        _ url: URL, side: CGFloat = 48, at origin: CGPoint = CGPoint(x: 20, y: 100),
        trigger: AnimatedAvatarPlayer.Trigger = .rounds,
        registry: AnimatedAvatars, rounds: AnimatedAvatarRounds? = nil,
        concurrency: AnimatedAvatarPlayer.Concurrency = AnimatedAvatarPlayer.Concurrency(),
        in window: UIWindow
    ) async -> AnimatedAvatarPlayer {
        let host = UIView(frame: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        let player = AnimatedAvatarPlayer.attach(to: host)
        player.registry = registry
        player.rounds = rounds ?? makeRounds()
        // Its own count of plays: other tests' players hold no slot of it.
        player.concurrency = concurrency
        player.trigger = trigger
        player.setAvatar(url)
        if url != Self.still {
            #expect(await eventually { player.debugSheet != nil }, "the sheet never arrived")
        }
        window.addSubview(host)
        return player
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        return window
    }

    @Test func aStillAvatarShowsNothing() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(Self.still, registry: makeRegistry(), in: window)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(player.isHidden)
        #expect(player.still == nil)
    }

    /// Coming on screen plays nothing: only a round does (#1424).
    @Test func anAvatarOnScreenAtArrivalRests() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(Self.face, registry: makeRegistry(), in: window)
        #expect(!player.isHidden, "an animated avatar showed no still")
        #expect(player.still != nil)
        #expect(player.playCount == 0, "an avatar present at arrival played")
    }

    /// The two screens where the avatar is large and alone play it once on
    /// first display, however often it is shown again there.
    @Test func aFirstAppearancePlaysOncePerScope() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let scope = AnimatedAvatarScope()
        let registry = makeRegistry()
        let first = await hosted(Self.face, trigger: .firstAppearance(scope), registry: registry, in: window)
        #expect(await eventually { first.playCount > 0 },
                "the first display did not play: \(first.lastRefusal ?? "never asked")")
        let again = await hosted(Self.face, trigger: .firstAppearance(scope), registry: registry, in: window)
        #expect(again.playCount == 0, "a second display in the same screen played again")
        // And it rests on the still once the loop is over.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(!first.isPlaying)
    }

    /// Too small never plays: a tile's author, a danmaku bubble.
    @Test func aSmallAvatarNeverPlays() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(
            Self.face, side: 20, trigger: .firstAppearance(AnimatedAvatarScope()), registry: makeRegistry(), in: window
        )
        #expect(player.playCount == 0, "a 20 pt avatar played")
        #expect(AnimatedAvatarPlayer.minimumDiameter == 32)
    }

    /// The post screen's author pill: its first avatar rests, the next one
    /// paging brings in plays.
    @Test func aChangedAvatarPlaysAndTheFirstRests() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let player = await hosted(Self.still, trigger: .change, registry: registry, in: window)
        #expect(player.playCount == 0)
        player.setAvatar(Self.face)
        // ⚠️ `playCount`, not `isPlaying`: the test sheet's loop is 0.2 s, and
        // a starved test can look again only after it has ended (#1357's run).
        #expect(await eventually { player.playCount > 0 },
                "the next author did not play: \(player.lastRefusal ?? "never asked")")

        let first = await hosted(Self.face, trigger: .change, registry: registry, in: window)
        #expect(first.playCount == 0, "a pill's first avatar played")
    }

    /// A profile's avatar arrives after its header is on show: its first
    /// display is when the sheet lands, and it plays then.
    @Test func anAvatarArrivingOnAScreenAlreadyUpPlaysOnItsFirstDisplay() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let host = UIView(frame: CGRect(x: 20, y: 100, width: 88, height: 88))
        let player = AnimatedAvatarPlayer.attach(to: host)
        player.registry = makeRegistry()
        player.rounds = makeRounds()
        player.concurrency = AnimatedAvatarPlayer.Concurrency()
        player.trigger = .firstAppearance(AnimatedAvatarScope())
        window.addSubview(host)
        player.setAvatar(Self.face)
        #expect(await eventually { player.playCount > 0 },
                "an avatar that arrived on a screen already up never played: \(player.lastRefusal ?? "never asked")")
    }

    // MARK: - #1424

    /// A play is ONE pass of the sheet, frame 0 to the last, on Core
    /// Animation's clock, and the layer's model is the last frame: the end of
    /// the play is the rest, however late the bookkeeping.
    @Test func aPlayEndsOnTheLastFrameOnTheSheetsClock() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(Self.face, trigger: .firstAppearance(AnimatedAvatarScope()), registry: makeRegistry(), in: window)
        #expect(player.debugRestingRect == Self.sheet.frameRects.last, "at rest, not on the last frame")
        #expect(await eventually { player.playCount > 0 }, "never played: \(player.lastRefusal ?? "never asked")")
        let animation = try #require(player.lastPlayAnimation)
        #expect(animation.repeatCount == 0, "a play loops")
        #expect(animation.calculationMode == .discrete)
        #expect((animation.values as? [NSValue])?.map(\.cgRectValue) == Self.sheet.frameRects)
        #expect(animation.keyTimes?.count == Self.sheet.frameRects.count + 1, "a frame without its own time")
        #expect(abs(animation.duration - Self.sheet.loopDuration) < 0.0001)
        #expect(player.debugRestingRect == Self.sheet.frameRects.last, "the model is not the last frame")
        #expect(await eventually { !player.isPlaying }, "the play never ended")
        #expect(player.debugRestingRect == Self.sheet.frameRects.last)
    }

    /// The first display plays a beat after it, not the instant it lands.
    @Test func aFirstDisplayPlaysAfterABeat() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(
            Self.face, trigger: .firstAppearance(AnimatedAvatarScope()), registry: makeRegistry(),
            rounds: makeRounds(firstDisplayDelay: 0.3...0.3), in: window
        )
        #expect(player.playCount == 0, "the first display played at once")
        #expect(await eventually { player.playCount > 0 }, "never played: \(player.lastRefusal ?? "never asked")")
    }

    /// Shown for less than the beat, a first display has not played: it
    /// plays on the next one.
    @Test func aFirstDisplayCutShortPlaysOnTheNext() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(
            Self.face, trigger: .firstAppearance(AnimatedAvatarScope()), registry: makeRegistry(),
            rounds: makeRounds(firstDisplayDelay: 0.3...0.3), in: window
        )
        let host = player.superview
        host?.removeFromSuperview()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(player.playCount == 0, "an avatar off screen played")
        if let host { window.addSubview(host) }
        #expect(await eventually { player.playCount > 0 },
                "the next display never played: \(player.lastRefusal ?? "never asked")")
    }

    /// The viewer's tap plays again, every time — idle calm does not stop it.
    @Test func aTapReplaysEvenAtRest() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let tapped = await hosted(Self.face, registry: registry, in: window)
        let picked = await hosted(Self.face, at: CGPoint(x: 120, y: 100), registry: registry, in: window)
        // ⚠️ Global state, set and reset with no await between (the repo's
        // rule for process-wide switches).
        IdleCalm.set(true)
        tapped.replay()
        picked.playFromRound()
        let tappedPlays = tapped.playCount, pickedPlays = picked.playCount
        IdleCalm.set(false)
        #expect(tappedPlays == 1, "a tap at rest did not play: \(tapped.lastRefusal ?? "")")
        #expect(pickedPlays == 0, "a round played at rest")
        #expect(await eventually { !tapped.isPlaying })
        tapped.replay()
        #expect(tapped.playCount == 2, "the second tap did not replay")
    }

    /// A round picks among the VISIBLE ANIMATED avatars only.
    @Test func aRoundPicksOnlyVisibleAnimatedAvatars() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds(picks: 3...3)
        let visible = await hosted(Self.face, registry: registry, rounds: rounds, in: window)
        let still = await hosted(Self.still, at: CGPoint(x: 120, y: 100), registry: registry, rounds: rounds, in: window)
        let offScreen = await hosted(Self.face, at: CGPoint(x: 20, y: 2_000), registry: registry, rounds: rounds, in: window)
        let small = await hosted(Self.face, side: 20, at: CGPoint(x: 220, y: 100), registry: registry, rounds: rounds, in: window)
        rounds.playRound()
        #expect(visible.playCount == 1, "the visible avatar was not picked: \(visible.lastRefusal ?? "")")
        #expect(still.playCount == 0)
        #expect(offScreen.playCount == 0, "an avatar off screen played")
        #expect(small.playCount == 0, "a 20 pt avatar played")
    }

    /// A round's plays are staggered, not all at once.
    @Test func aRoundStaggersItsPlays() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds(picks: 3...3, stagger: 0.3...0.3)
        var players: [AnimatedAvatarPlayer] = []
        for index in 0..<3 {
            players.append(await hosted(Self.face, at: CGPoint(x: 20 + index * 100, y: 100), registry: registry, rounds: rounds, in: window))
        }
        rounds.playRound()
        #expect(players.filter { $0.playCount > 0 }.count == 1, "a round played more than one at once")
        #expect(await eventually { players.allSatisfy { $0.playCount > 0 } }, "the staggered plays never came")
    }

    /// Never more than `maxConcurrent` at once, a round's included.
    @Test func aRoundRespectsMaxConcurrent() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds(picks: 6...6)
        let concurrency = AnimatedAvatarPlayer.Concurrency()
        var players: [AnimatedAvatarPlayer] = []
        for index in 0..<6 {
            players.append(await hosted(
                Self.face, at: CGPoint(x: 20 + (index % 3) * 100, y: 100 + (index / 3) * 100),
                registry: registry, rounds: rounds, concurrency: concurrency, in: window
            ))
        }
        rounds.playRound()
        #expect(players.filter(\.isPlaying).count == AnimatedAvatarPlayer.maxConcurrent)
        #expect(concurrency.playing == AnimatedAvatarPlayer.maxConcurrent)
    }

    /// No avatar plays two rounds in a row: with two on screen and one pick
    /// a round, they take turns.
    @Test func aRoundSkipsTheLastPlayed() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds(picks: 1...1)
        let first = await hosted(Self.face, registry: registry, rounds: rounds, in: window)
        let second = await hosted(Self.otherFace, at: CGPoint(x: 120, y: 100), registry: registry, rounds: rounds, in: window)
        var order: [Int] = []
        for _ in 0..<4 {
            let before = (first.playCount, second.playCount)
            rounds.playRound()
            order.append(first.playCount > before.0 ? 0 : second.playCount > before.1 ? 1 : -1)
            #expect(await eventually { !first.isPlaying && !second.isPlaying })
        }
        #expect(!order.contains(-1), "a round played nothing: \(order)")
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "an avatar played twice in a row: \(order)")
    }

    /// The rounds' timer runs only while an animated avatar is in a window:
    /// none for a still one, and it stops when the screen goes.
    @Test func theRoundsRunOnlyWithAnAnimatedAvatarOnScreen() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds()
        _ = await hosted(Self.still, registry: registry, rounds: rounds, in: window)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!rounds.isRunning, "a timer ran for a still avatar")
        let animated = await hosted(Self.face, at: CGPoint(x: 120, y: 100), registry: registry, rounds: rounds, in: window)
        #expect(rounds.isRunning, "no round waits with an animated avatar on screen")
        animated.superview?.removeFromSuperview()
        #expect(!rounds.isRunning, "the rounds ran on after the screen went")
    }

    /// An animated avatar's picture IS its still, not a layer over a
    /// different photo — and, its sheet known, from the first configure.
    @Test func anAvatarViewDrawsTheStillAsItsPicture() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let avatar = AvatarView(diameter: 48, size: .avatar)
        avatar.frame = CGRect(x: 20, y: 100, width: 48, height: 48)
        avatar.animation.registry = makeRegistry()
        avatar.animation.rounds = makeRounds()
        window.addSubview(avatar)
        avatar.setPicture(Self.face, pipeline: nil)
        #expect(await eventually { avatar.picture.image != nil }, "the still never became the picture")
        let still = avatar.animation.still
        #expect(still != nil && avatar.picture.image === still, "the picture is not the still")
        #expect(avatar.shownPicture === still)

        // A recycled row showing the face again: the still at once, in the
        // configure pass — never the photo first.
        avatar.reset()
        avatar.setPicture(Self.face, pipeline: nil)
        #expect(avatar.picture.image === still, "a reconfigure did not draw the still at once")
    }

    /// `-avatar-rounds` tunes the numbers on the device.
    @Test func theLaunchFlagTunesTheRounds() {
        let tuning = AnimatedAvatarRounds.Tuning.launch(["app", "-avatar-rounds", "picks=2-4 pause=1-2 first=0.1-0.2"])
        #expect(tuning.picks == 2...4)
        #expect(tuning.pause == 1...2)
        #expect(tuning.firstDisplayDelay == 0.1...0.2)
        #expect(tuning.stagger == AnimatedAvatarRounds.Tuning.standard.stagger)
        #expect(AnimatedAvatarRounds.Tuning.launch(["app"]) == .standard)
    }

    /// The mock's sheets are seamless loops that END ON THE FACE: the still
    /// is the photo, and frame 0 is mostly it.
    @Test func aBakedSheetEndsOnTheFace() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let white = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let baked = try #require(AnimatedAvatars.bakeSquareSheet(from: Self.sheet, cellPX: 8, endingOn: white, blendFrames: 1))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color(of: AnimatedAvatars.lastFrame(of: baked))?.getRed(&red, green: &green, blue: &blue, alpha: nil)
        #expect(red > 0.95 && green > 0.95 && blue > 0.95, "the last frame is not the face")
        #expect(AnimatedAvatars.anchorWeight(index: 3, count: 4, blend: 1) == 1)
        #expect(AnimatedAvatars.anchorWeight(index: 2, count: 4, blend: 1) == 0.5)
        #expect(AnimatedAvatars.anchorWeight(index: 0, count: 4, blend: 1) == 0.5)
        #expect(AnimatedAvatars.anchorWeight(index: 1, count: 4, blend: 1) == 0)
    }

    // MARK: - #1444: the sheet is the only media

    /// Counts every photo the pipeline is asked to fetch.
    private final class CountingFetcher: ImageFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var fetched: [URL] { lock.withLock { urls } }
        func fetchImageData(for url: URL) async throws -> Data {
            lock.withLock { urls.append(url) }
            return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
    }

    /// Holds the sheet back until the test lets it go, and records the rungs
    /// it is asked for.
    private actor GatedFace: AnimatedAvatarResolving {
        private var gate: CheckedContinuation<Void, Never>?
        private var open = false
        private(set) var rungs: [AnimatedAvatars.Rung] = []
        func sheet(for avatarURL: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
            rungs.append(rung)
            if !open { await withCheckedContinuation { gate = $0 } }
            return AnimatedAvatarTests.sheet
        }
        func release() {
            open = true
            gate?.resume()
            gate = nil
        }
    }

    @Test func aSheetIsAtLeastAsWideAsTheDrawnAvatar() {
        #expect(AnimatedAvatars.Rung(pixels: 40 * 3) == .px128, "a 40 pt avatar at @3x")
        #expect(AnimatedAvatars.Rung(pixels: 96 * 3) == .px256, "the profile header at @3x")
        #expect(AnimatedAvatars.Rung(pixels: 2_000) == .px256, "past the largest rung, the largest")
        #expect(AnimatedAvatars.Rung(bucket: .avatar) == .px128)
        #expect(AnimatedAvatars.Rung(bucket: .px512) == .px256)
        #expect(AnimatedAvatars.isSheet(Self.face) && !AnimatedAvatars.isSheet(Self.still))
    }

    /// An animated avatar never asks for a photo, and shows its initials until
    /// its sheet is decoded — then the sheet's last frame, at the rung its
    /// picture is decoded at.
    @Test func aSheetAvatarNeverFetchesAPhotoAndWaitsForItsSheet() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let resolver = GatedFace()
        let registry = AnimatedAvatars(registry: nil)
        registry.resolver = resolver
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, sheetAvatars: registry)
        let avatar = AvatarView(diameter: 96, size: .px512)
        avatar.frame = CGRect(x: 20, y: 100, width: 96, height: 96)
        avatar.animation.registry = registry
        avatar.animation.rounds = makeRounds()
        window.addSubview(avatar)

        avatar.setPicture(Self.face, pipeline: pipeline)
        var asked = false
        for _ in 0..<6_000 where !asked {
            asked = !(await resolver.rungs).isEmpty
            if !asked { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(asked, "the sheet was never asked for")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(avatar.picture.image == nil && avatar.standIn.image == nil, "a picture before the sheet")
        #expect(avatar.shownPicture == nil, "something other than the initials before the sheet")

        await resolver.release()
        #expect(await eventually { avatar.picture.image != nil }, "the sheet's still never became the picture")
        #expect(avatar.picture.image === registry.cachedStill(for: Self.face, rung: .px256))
        #expect(Set(await resolver.rungs) == [.px256], "the 512 px picture did not take the 256 px sheet")
        #expect(fetcher.fetched.isEmpty, "an animated avatar fetched a photo: \(fetcher.fetched)")
    }

    /// The pipeline answers a sheet avatar's URL with the sheet's last frame,
    /// never brings a photo ahead, and fails when there is no sheet.
    @Test func thePipelineServesASheetAvatarItsStill() async throws {
        let registry = makeRegistry()
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, sheetAvatars: registry)
        #expect(pipeline.cachedImage(for: Self.face, size: .avatar) == nil)
        #expect(pipeline.prefetch(Self.face, size: .avatar, window: .display, owner: CacheOwner("test")) == nil)

        let still = try await pipeline.image(for: Self.face, size: .avatar)
        #expect(still === registry.cachedStill(for: Self.face, rung: .px128))
        #expect(pipeline.cachedImage(for: Self.face, size: .avatar) === still)
        let none = URL(string: "https://example.com/none.sheet#avatar-sheet")!
        await #expect(throws: (any Error).self) { try await pipeline.image(for: none, size: .avatar) }
        #expect(fetcher.fetched.isEmpty, "a sheet avatar reached the fetcher: \(fetcher.fetched)")
    }
}
