import CacheKit
@testable import DesignSystem
import Testing
import UIKit
@testable import MediaCore
@testable import MediaUI

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
        AnimatedAvatars(resolver: OneFace(animated: Self.face), registry: nil)
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

    /// A screen of a test's own (#2454): a view over the window declaring
    /// `name`, `rule` written in `rounds`' table.
    private func makeScreen(
        _ rule: AvatarMotionRule, named name: String = "test", rounds: AnimatedAvatarRounds, in window: UIWindow
    ) -> UIView {
        let screen = UIView(frame: window.bounds)
        let id = AvatarMotionScreen(rawValue: name)
        rounds.policy.rules[id] = rule
        screen.traitOverrides.avatarMotionScreen = id
        window.addSubview(screen)
        return screen
    }

    /// Hosts a player in a window, its avatar resolved, under `screen` (the
    /// window, a screen that declares nothing, by default). `rule`: the host
    /// declares a screen of its own with that rule, as a pill does, so the
    /// rule holds before it is on screen.
    private func hosted(
        _ url: URL, side: CGFloat = 48, at origin: CGPoint = CGPoint(x: 20, y: 100),
        rule: AvatarMotionRule? = nil,
        registry: AnimatedAvatars, rounds: AnimatedAvatarRounds? = nil,
        concurrency: AnimatedAvatarPlayer.Concurrency = AnimatedAvatarPlayer.Concurrency(),
        in window: UIWindow, screen: UIView? = nil
    ) async -> AnimatedAvatarPlayer {
        let conductor = rounds ?? makeRounds()
        let host = UIView(frame: CGRect(origin: origin, size: CGSize(width: side, height: side)))
        if let rule {
            let id = AvatarMotionScreen(rawValue: "test-\(rule)")
            conductor.policy.rules[id] = rule
            host.traitOverrides.avatarMotionScreen = id
        }
        let player = AnimatedAvatarPlayer.attach(to: host)
        player.registry = registry
        player.rounds = conductor
        // Its own count of plays: other tests' players hold no slot of it.
        player.concurrency = concurrency
        player.setAvatar(url)
        if url != Self.still {
            #expect(await eventually { player.debugSheet != nil }, "the sheet never arrived")
        }
        (screen ?? window).addSubview(host)
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
        let rounds = makeRounds()
        let screen = makeScreen(.firstAppearance(then: .off), rounds: rounds, in: window)
        let registry = makeRegistry()
        let first = await hosted(Self.face, registry: registry, rounds: rounds, in: window, screen: screen)
        #expect(await eventually { first.playCount > 0 },
                "the first display did not play: \(first.lastRefusal ?? "never asked")")
        let again = await hosted(Self.face, registry: registry, rounds: rounds, in: window, screen: screen)
        #expect(again.playCount == 0, "a second display in the same screen played again")
        // And it rests on the still once the loop is over — waited for on
        // looks (#1676): a fixed 400 ms ran out on a starved runner before
        // the 0.2 s loop's end had its turn. Resting is where it stays.
        #expect(await eventually { !first.isPlaying }, "the first display never came to rest")
    }

    /// Too small never plays: a tile's author, a danmaku bubble.
    @Test func aSmallAvatarNeverPlays() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(
            Self.face, side: 20, rule: .firstAppearance(then: .off), registry: makeRegistry(), in: window
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
        let player = await hosted(Self.still, rule: .change, registry: registry, in: window)
        #expect(player.playCount == 0)
        player.setAvatar(Self.face)
        // ⚠️ `playCount`, not `isPlaying`: the test sheet's loop is 0.2 s, and
        // a starved test can look again only after it has ended (#1357's run).
        #expect(await eventually { player.playCount > 0 },
                "the next author did not play: \(player.lastRefusal ?? "never asked")")

        let first = await hosted(Self.face, rule: .change, registry: registry, in: window)
        #expect(first.playCount == 0, "a pill's first avatar played")
    }

    /// A fresh pill per author (#1791): its avatar, set before the pill
    /// joins the bar, plays once it is on screen — and never joins the
    /// rounds.
    @Test func anArrivingAvatarPlaysOnceOnScreen() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let player = await hosted(Self.face, rule: .arrival, registry: makeRegistry(), rounds: rounds, in: window)
        #expect(await eventually { player.playCount > 0 },
                "an arriving pill's avatar did not play: \(player.lastRefusal ?? "never asked")")
        #expect(!rounds.isRunning, "an arriving avatar joined the rounds")
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
        host.traitOverrides.avatarMotionScreen = .profileHeader
        window.addSubview(host)
        player.setAvatar(Self.face)
        #expect(await eventually { player.playCount > 0 },
                "an avatar that arrived on a screen already up never played: \(player.lastRefusal ?? "never asked")")
    }

    // MARK: - #1424

    /// A play is TWO passes of the sheet back to back (the owner, 2026-10-25),
    /// frame 0 to the last each time, on Core Animation's clock, and the
    /// layer's model is the last frame: the end of the play is the rest,
    /// however late the bookkeeping.
    @Test func aPlayEndsOnTheLastFrameOnTheSheetsClock() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(Self.face, rule: .firstAppearance(then: .off), registry: makeRegistry(), in: window)
        #expect(player.debugRestingRect == Self.sheet.frameRects.last, "at rest, not on the last frame")
        #expect(await eventually { player.playCount > 0 }, "never played: \(player.lastRefusal ?? "never asked")")
        let animation = try #require(player.lastPlayAnimation)
        #expect(animation.repeatCount == Float(AnimatedAvatarPlayer.loopsPerPlay), "a play is not two loops")
        #expect(AnimatedAvatarPlayer.loopsPerPlay == 2)
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
            Self.face, rule: .firstAppearance(then: .off), registry: makeRegistry(),
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
            Self.face, rule: .firstAppearance(then: .off), registry: makeRegistry(),
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
        picked.playFromConductor()
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
        rounds.advance()
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
        rounds.advance()
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
        rounds.advance()
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
            rounds.advance()
            order.append(first.playCount > before.0 ? 0 : second.playCount > before.1 ? 1 : -1)
            #expect(await eventually { !first.isPlaying && !second.isPlaying })
        }
        #expect(!order.contains(-1), "a round played nothing: \(order)")
        #expect(zip(order, order.dropFirst()).allSatisfy { $0 != $1 }, "an avatar played twice in a row: \(order)")
    }

    /// A face that played on its first display follows its screen's next
    /// rule: the rounds pick it again (the owner, 2026-10-20: a face that
    /// played once and never again read as broken). A `.change` avatar plays
    /// only on a change.
    @Test func aFirstAppearanceAvatarJoinsTheRounds() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let rounds = makeRounds()
        let screen = makeScreen(.firstAppearance(then: .rounds(picks: 1...1)), named: "header", rounds: rounds, in: window)
        let face = await hosted(Self.face, registry: registry, rounds: rounds, in: window, screen: screen)
        #expect(rounds.isRunning, "a first-display face is not in the rounds")
        #expect(await eventually { face.playCount == 1 && !face.isPlaying }, "the first display never played")
        rounds.advance(on: AvatarMotionScreen(rawValue: "header"))
        #expect(face.playCount == 2, "the round did not pick the face again: \(face.lastRefusal ?? "-")")

        let changing = makeRounds()
        _ = await hosted(Self.face, at: CGPoint(x: 120, y: 100), rule: .change, registry: registry, rounds: changing, in: window)
        #expect(!changing.isRunning, "a .change avatar joined the rounds")
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
        // The avatar plays the sheets of the pipeline it is drawn through.
        let pipeline = ImagePipeline(fetcher: CountingFetcher(), sheetAvatars: makeRegistry())
        avatar.animation.rounds = makeRounds()
        window.addSubview(avatar)
        avatar.setPicture(Self.face, pipeline: pipeline)
        #expect(await eventually { avatar.picture.image != nil }, "the still never became the picture")
        let still = avatar.animation.still
        #expect(still != nil && avatar.picture.image === still, "the picture is not the still")
        #expect(avatar.shownPicture === still)

        // A recycled row showing the face again: the still at once, in the
        // configure pass — never the photo first.
        avatar.reset()
        avatar.setPicture(Self.face, pipeline: pipeline)
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

    /// #1742: a sheet baked straight from a clip's frames — 48 at 12 fps,
    /// any shape, each cut to its centre square — four to a row.
    @Test func aSheetBakesFromFramesCutFromAClip() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }.cgImage
        let baked = try #require(AnimatedAvatars.bakeSquareSheet(
            cells: Array(repeating: frame, count: 48), frameDuration: 1.0 / 12.0, cellPX: 8
        ))
        #expect(baked.frameCount == 48)
        #expect(abs(baked.loopDuration - 4) < 0.0001, "48 frames at 12 fps are not 4 s")
        #expect(baked.sheet.cgImage?.width == 4 * 8)
        #expect(baked.sheet.cgImage?.height == 12 * 8)
    }

    /// Without a face, the clip's OWN last frame is the rest (the owner,
    /// 2026-10-20): the sheet ends on it, and its first frame fades out of
    /// it — a play loops back to the clip's end, never restarts from a
    /// still of its beginning.
    @Test func aSheetWithoutAFaceRestsOnTheClipsLastFrame() throws {
        let baked = try #require(AnimatedAvatars.bakeSquareSheet(from: Self.sheet, cellPX: 8, blendFrames: 1))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color(of: AnimatedAvatars.lastFrame(of: baked))?.getRed(&red, green: &green, blue: &blue, alpha: nil)
        // The source's last cell is green, its first red.
        #expect(green > 0.4 && red < 0.1 && blue < 0.1, "the rest is not the clip's last frame: \(red) \(green) \(blue)")
        let first = try #require(baked.sheet.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        color(of: UIImage(cgImage: first))?.getRed(&red, green: &green, blue: &blue, alpha: nil)
        #expect(red > 0.3 && green > 0.15, "frame 0 does not fade out of the rest: \(red) \(green) \(blue)")
    }

    // MARK: - #2454: one motion rule per screen

    /// Animates every sheet avatar: a group's faces.
    private struct AnyFace: AnimatedAvatarResolving {
        func sheet(for avatarURL: URL, rung: AnimatedAvatars.Rung) async -> AnimatedIconSheet? {
            AnimatedAvatars.isSheet(avatarURL) ? AnimatedAvatarTests.sheet : nil
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "avatar-motion-\(UUID().uuidString)") ?? .standard
    }

    /// The issue's starting table, screen by screen.
    @Test func theTableHoldsEveryScreensRule() {
        let rules = AvatarMotionPolicy.standard.rules
        #expect(rules[.messages] == .sequence(order: .unreadFirst))
        #expect(rules[.thread] == .off)
        #expect(rules[.threadHeader] == .arrival)
        #expect(rules[.posts] == .rounds(picks: 1...1))
        #expect(rules[.profileHeader] == .firstAppearance(then: .rounds(picks: 1...1)))
        #expect(rules[.authorPill] == .change)
        for screen: AvatarMotionScreen in [.comments, .search, .personLists, .suggestions, .map] {
            #expect(rules[screen] == .off, "\(screen) is not still")
        }
    }

    /// A screen the table leaves out keeps today's random rounds: nothing
    /// changes by accident.
    @Test func aScreenMissingFromTheTableKeepsTheRounds() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds(picks: 2...2)
        let nowhere = AvatarMotionScreen(rawValue: "nowhere")
        #expect(rounds.rule(for: nowhere) == .rounds(picks: 2...2))
        #expect(rounds.rule(for: nil) == .rounds(picks: 2...2))
        let screen = UIView(frame: window.bounds)
        screen.traitOverrides.avatarMotionScreen = nowhere
        window.addSubview(screen)
        let player = await hosted(Self.face, registry: makeRegistry(), rounds: rounds, in: window, screen: screen)
        #expect(rounds.isRunning, "an avatar on a screen out of the table is not in the rounds")
        rounds.advance(on: nowhere)
        #expect(player.playCount == 1, "the rounds did not pick it: \(player.lastRefusal ?? "-")")
    }

    /// `.off`: nothing plays — no round, no change, no timer.
    @Test func anOffScreenPlaysNothing() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.off, named: "reading", rounds: rounds, in: window)
        let player = await hosted(Self.still, registry: makeRegistry(), rounds: rounds, in: window, screen: screen)
        player.setAvatar(Self.face)
        #expect(await eventually { player.debugSheet != nil }, "the sheet never arrived")
        #expect(!player.isHidden, "an animated avatar showed no still")
        #expect(!rounds.isRunning, "a timer ran for a screen where nothing plays")
        rounds.advance(on: AvatarMotionScreen(rawValue: "reading"))
        #expect(player.playCount == 0, "an avatar played on an .off screen")
    }

    /// A sequence plays one avatar at a time, by rank on screen — never by
    /// the order the avatars came in — each starting once the last ended.
    @Test func aSequencePlaysOneAtATimeInRankOrder() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "list", rounds: rounds, in: window)
        let registry = makeRegistry()
        let middle = await hosted(Self.face, at: CGPoint(x: 20, y: 300), registry: registry, rounds: rounds, in: window, screen: screen)
        let bottom = await hosted(Self.otherFace, at: CGPoint(x: 20, y: 500), registry: registry, rounds: rounds, in: window, screen: screen)
        let top = await hosted(Self.face, at: CGPoint(x: 20, y: 100), registry: registry, rounds: rounds, in: window, screen: screen)
        let players = [top, middle, bottom]
        var order: [ObjectIdentifier] = []
        var overlaps = 0
        rounds.onPlay = { player in
            order.append(ObjectIdentifier(player))
            if players.filter(\.isPlaying).count > 1 { overlaps += 1 }
        }
        rounds.advance(on: AvatarMotionScreen(rawValue: "list"))
        #expect(await eventually { order.count == 3 }, "the wave stopped short: \(order.count) of 3")
        #expect(order == players.map { ObjectIdentifier($0) }, "the wave did not go top to bottom")
        #expect(overlaps == 0, "two avatars played at once")
    }

    /// Under `unreadFirst`, the rows the host raised play first, then the
    /// others, each top to bottom.
    @Test func anUnreadFirstSequencePlaysTheRaisedRowsFirst() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .unreadFirst), named: "inbox", rounds: rounds, in: window)
        let registry = makeRegistry()
        let top = await hosted(Self.face, at: CGPoint(x: 20, y: 100), registry: registry, rounds: rounds, in: window, screen: screen)
        let middle = await hosted(Self.otherFace, at: CGPoint(x: 20, y: 300), registry: registry, rounds: rounds, in: window, screen: screen)
        let bottom = await hosted(Self.face, at: CGPoint(x: 20, y: 500), registry: registry, rounds: rounds, in: window, screen: screen)
        middle.motionPriority = .raised
        bottom.motionPriority = .raised
        var order: [ObjectIdentifier] = []
        rounds.onPlay = { order.append(ObjectIdentifier($0)) }
        rounds.advance(on: AvatarMotionScreen(rawValue: "inbox"))
        #expect(await eventually { order.count == 3 }, "the wave stopped short: \(order.count) of 3")
        #expect(order == [middle, bottom, top].map { ObjectIdentifier($0) }, "the unread rows did not play first")
    }

    /// An avatar that leaves the screen mid-wave is skipped: the next one
    /// plays in its turn.
    @Test func anAvatarThatLeavesMidWaveIsSkipped() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "list", rounds: rounds, in: window)
        let registry = makeRegistry()
        let top = await hosted(Self.face, at: CGPoint(x: 20, y: 100), registry: registry, rounds: rounds, in: window, screen: screen)
        let middle = await hosted(Self.otherFace, at: CGPoint(x: 20, y: 300), registry: registry, rounds: rounds, in: window, screen: screen)
        let bottom = await hosted(Self.face, at: CGPoint(x: 20, y: 500), registry: registry, rounds: rounds, in: window, screen: screen)
        var order: [ObjectIdentifier] = []
        rounds.onPlay = { player in
            order.append(ObjectIdentifier(player))
            // The middle row scrolls away while the top one plays.
            if player === top { middle.superview?.removeFromSuperview() }
        }
        rounds.advance(on: AvatarMotionScreen(rawValue: "list"))
        #expect(await eventually { order.count == 2 }, "the wave stopped at the avatar that left")
        #expect(order == [top, bottom].map { ObjectIdentifier($0) })
        #expect(middle.playCount == 0, "an avatar that left the screen played")
    }

    /// A play a global limit refuses is skipped: the sequence goes to the
    /// next avatar.
    @Test func aRefusedPlayHandsTheTurnToTheNext() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "list", rounds: rounds, in: window)
        let registry = makeRegistry()
        // Four plays already hold every slot the top avatar counts in.
        let full = AnimatedAvatarPlayer.Concurrency()
        var holders: [AnimatedAvatarPlayer] = []
        for index in 0..<AnimatedAvatarPlayer.maxConcurrent {
            holders.append(await hosted(
                Self.face, at: CGPoint(x: 120 + index * 60, y: 700), registry: registry, concurrency: full, in: window
            ))
        }
        let top = await hosted(Self.face, at: CGPoint(x: 20, y: 100), registry: registry, rounds: rounds, concurrency: full, in: window, screen: screen)
        let next = await hosted(Self.otherFace, at: CGPoint(x: 20, y: 300), registry: registry, rounds: rounds, in: window, screen: screen)
        holders.forEach { $0.replay() }
        rounds.advance(on: AvatarMotionScreen(rawValue: "list"))
        let refusal = top.lastRefusal
        #expect(top.playCount == 0, "a play past maxConcurrent started")
        #expect(refusal?.contains("already playing") == true, "the top avatar was not refused for room: \(refusal ?? "-")")
        #expect(next.playCount == 1, "the sequence did not go on to the next avatar: \(next.lastRefusal ?? "-")")
    }

    /// The global limits stay above every rule: Reduce Motion, Low Power
    /// Mode and idle calm refuse a sequence's play and stop its screen, and
    /// an avatar under 32 pt is never a candidate.
    @Test func theGlobalLimitsStillRefuse() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "list", rounds: rounds, in: window)
        let list = AvatarMotionScreen(rawValue: "list")
        let registry = makeRegistry()
        let player = await hosted(Self.face, registry: registry, rounds: rounds, in: window, screen: screen)
        let small = await hosted(Self.otherFace, side: 20, at: CGPoint(x: 20, y: 300), registry: registry, rounds: rounds, in: window, screen: screen)
        // ⚠️ Process-wide switches, each set and reset with no await between
        // (the repo's rule for them).
        let previous = (MotionPreference.defaults, LowPowerMode.defaults, LowPowerMode.system)
        MotionPreference.defaults = isolatedDefaults()
        LowPowerMode.defaults = isolatedDefaults()
        MotionPreference.appReducesMotion = true
        rounds.advance(on: list)
        let underReduceMotion = (player.playCount, rounds.isRunning)
        MotionPreference.appReducesMotion = false
        LowPowerMode.system = { true }
        rounds.advance(on: list)
        let underLowPower = (player.playCount, rounds.isRunning)
        LowPowerMode.system = previous.2
        IdleCalm.set(true)
        rounds.advance(on: list)
        let underIdleCalm = (player.playCount, rounds.isRunning)
        let refused = player.playFromConductor() == nil
        IdleCalm.set(false)
        MotionPreference.defaults = previous.0
        LowPowerMode.defaults = previous.1
        #expect(underReduceMotion.0 == 0 && !underReduceMotion.1, "Reduce Motion let a sequence play or run on")
        #expect(underLowPower.0 == 0 && !underLowPower.1, "Low Power Mode let a sequence play or run on")
        #expect(underIdleCalm.0 == 0 && !underIdleCalm.1, "idle calm let a sequence play or run on")
        #expect(refused, "idle calm let a conducted play start")
        rounds.advance(on: list)
        #expect(player.playCount == 1, "the sequence did not play once the limits lifted: \(player.lastRefusal ?? "-")")
        #expect(small.playCount == 0, "a 20 pt avatar played")
    }

    /// A group offers its first face only (the owner first, #2233), and
    /// counts as one avatar in a sequence: one rank, one turn. Its photo is a
    /// still.
    @Test func aGroupOffersItsFirstFaceOnlyAndCountsAsOne() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "inbox", rounds: rounds, in: window)
        let inbox = AvatarMotionScreen(rawValue: "inbox")
        let pipeline = ImagePipeline(
            fetcher: CountingFetcher(), sheetAvatars: AnimatedAvatars(resolver: AnyFace(), registry: nil)
        )
        let group = GroupAvatarView(diameter: 120, size: .avatar)
        group.frame = CGRect(x: 20, y: 100, width: 120, height: 120)
        let faces = (1...3).map { index in
            GroupAvatarFace(name: "Member \(index)", avatarURL: URL(string: "https://example.com/member-\(index).sheet#avatar-sheet")!)
        }
        group.setContent(GroupAvatarContent(name: "Group", faces: faces), pipeline: pipeline)
        #expect(group.stackPlayable == [true, false, false], "a face past the first may play")
        #expect(!group.singlePlayable, "a group's photo may play")
        // The test's own conductor, never the app's.
        let faceViews = group.subviews.compactMap { $0 as? AvatarView }
        for face in faceViews {
            face.animation.rounds = rounds
            face.animation.concurrency = AnimatedAvatarPlayer.Concurrency()
        }
        screen.addSubview(group)
        group.layoutIfNeeded()
        let single = await hosted(Self.face, at: CGPoint(x: 20, y: 400), registry: makeRegistry(), rounds: rounds, in: window, screen: screen)
        let stacked = faceViews.filter { !$0.isHidden }
        #expect(await eventually { stacked.allSatisfy { $0.animation.debugSheet != nil } }, "a face's sheet never arrived")
        #expect(rounds.memberCount(on: inbox) == 2, "the group is not one avatar: \(rounds.memberCount(on: inbox)) members")
        let first = try #require(stacked.first?.animation)
        var order: [ObjectIdentifier] = []
        rounds.onPlay = { order.append(ObjectIdentifier($0)) }
        rounds.advance(on: inbox)
        #expect(await eventually { order.count == 2 }, "the wave stopped short: \(order.count) of 2")
        #expect(order == [first, single].map { ObjectIdentifier($0) }, "the group did not take one turn with its first face")
        #expect(stacked.dropFirst().allSatisfy { $0.animation.playCount == 0 }, "a face past the first played")
    }

    /// A group's first face has its own floor, 24 pt (#2454): in a 56 pt
    /// row, the first of four faces is 27 pt, and it is offered and plays,
    /// while a plain 27 pt avatar is still refused.
    @Test func aGroupsFirstFaceHasItsOwnFloor() async throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let screen = makeScreen(.sequence(order: .topToBottom), named: "inbox", rounds: rounds, in: window)
        let inbox = AvatarMotionScreen(rawValue: "inbox")
        let pipeline = ImagePipeline(
            fetcher: CountingFetcher(), sheetAvatars: AnimatedAvatars(resolver: AnyFace(), registry: nil)
        )
        let group = GroupAvatarView(diameter: 56, size: .avatar)
        group.frame = CGRect(x: 20, y: 100, width: 56, height: 56)
        let faces = (1...4).map { index in
            GroupAvatarFace(name: "Member \(index)", avatarURL: URL(string: "https://example.com/member-\(index).sheet#avatar-sheet")!)
        }
        group.setContent(GroupAvatarContent(name: "Group", faces: faces), pipeline: pipeline)
        let faceViews = group.subviews.compactMap { $0 as? AvatarView }
        for face in faceViews {
            face.animation.rounds = rounds
            face.animation.concurrency = AnimatedAvatarPlayer.Concurrency()
        }
        screen.addSubview(group)
        group.layoutIfNeeded()
        let stacked = faceViews.filter { !$0.isHidden }
        let first = try #require(stacked.first)
        #expect(first.frame.width == 27, "the first of four faces is not 27 pt: \(first.frame.width)")
        let plain = await hosted(Self.face, side: 27, at: CGPoint(x: 20, y: 300), registry: makeRegistry(), rounds: rounds, in: window, screen: screen)
        #expect(await eventually { first.animation.debugSheet != nil }, "the first face's sheet never arrived")
        #expect(first.animation.isRoundCandidate, "a 27 pt group's first face is not offered")
        #expect(!plain.isRoundCandidate, "a 27 pt avatar is offered")
        var order: [ObjectIdentifier] = []
        rounds.onPlay = { order.append(ObjectIdentifier($0)) }
        rounds.advance(on: inbox)
        #expect(order == [ObjectIdentifier(first.animation)], "the group's first face did not play alone")
        #expect(plain.playFromConductor() == nil, "a 27 pt avatar played")
        #expect(plain.lastRefusal?.hasPrefix("under 32") == true, "not refused for its size: \(plain.lastRefusal ?? "-")")
    }

    /// #580: no work item waits without a conducted avatar in a window — none
    /// for a screen where nothing plays, and a sequence's timer goes with its
    /// last avatar.
    @Test func noWorkItemWaitsWithoutACandidateInAWindow() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let rounds = makeRounds()
        let reading = makeScreen(.off, named: "reading", rounds: rounds, in: window)
        let list = makeScreen(.sequence(order: .unreadFirst), named: "list", rounds: rounds, in: window)
        let registry = makeRegistry()
        _ = await hosted(Self.face, registry: registry, rounds: rounds, in: window, screen: reading)
        #expect(!rounds.isRunning, "a timer ran for a screen where nothing plays")
        let player = await hosted(Self.face, at: CGPoint(x: 120, y: 100), registry: registry, rounds: rounds, in: window, screen: list)
        #expect(rounds.isRunning, "no wave waits with an avatar in a sequence on screen")
        player.superview?.removeFromSuperview()
        #expect(!rounds.isRunning, "the sequence's timer outlived its last avatar")
    }

    /// `-avatar-motion` overrides one screen's rule on the device; an entry
    /// that does not read changes nothing, and every rule reads back from
    /// what the play log prints.
    @Test func theLaunchFlagOverridesAScreensRule() {
        let policy = AvatarMotionPolicy.launch(
            ["app", "-avatar-motion", "messages=sequence:topToBottom comments=rounds:2 map=first:rounds:1-2 search=nonsense bogus"],
            standardPicks: 1...3
        )
        let standard = AvatarMotionPolicy.standard
        #expect(policy.rules[.messages] == .sequence(order: .topToBottom))
        #expect(policy.rules[.comments] == .rounds(picks: 2...2))
        #expect(policy.rules[.map] == .firstAppearance(then: .rounds(picks: 1...2)))
        #expect(policy.rules[.search] == standard.rules[.search], "an entry that does not read changed a rule")
        #expect(policy.rules[.posts] == standard.rules[.posts], "a screen the flag left out changed")
        #expect(AvatarMotionPolicy.launch(["app"], standardPicks: 1...3) == standard)
        let rules: [AvatarMotionRule] = [
            .off, .change, .arrival, .rounds(picks: 1...3), .sequence(order: .leadingToTrailing),
            .sequence(order: .unreadFirst), .firstAppearance(then: .off), .firstAppearance(then: .sequence(order: .topToBottom))
        ]
        for rule in rules {
            #expect(AvatarMotionRule(spec: Substring(rule.description), standardPicks: 1...3) == rule, "\(rule) does not read back")
        }
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
        let registry = AnimatedAvatars(resolver: resolver, registry: nil)
        let fetcher = CountingFetcher()
        let pipeline = ImagePipeline(fetcher: fetcher, sheetAvatars: registry)
        let avatar = AvatarView(diameter: 96, size: .px512)
        avatar.frame = CGRect(x: 20, y: 100, width: 96, height: 96)
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
