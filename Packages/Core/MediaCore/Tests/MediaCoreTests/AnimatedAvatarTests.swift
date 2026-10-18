import DesignSystem
import Testing
import UIKit
@testable import MediaCore

/// Animated avatars (#1358, the owner 2026-10-18): a sheet played once, by
/// the rule; the sheet's last frame at rest.
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
        func sheet(for avatarURL: URL) async -> AnimatedIconSheet? {
            avatarURL == animated ? AnimatedAvatarTests.sheet : nil
        }
    }

    private static let face = URL(string: "https://example.com/animated.jpg")!
    private static let still = URL(string: "https://example.com/still.jpg")!

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

    /// Hosts a player in a window, its avatar resolved.
    private func hosted(
        _ url: URL, side: CGFloat = 48, trigger: AnimatedAvatarPlayer.Trigger = .scrollAppearance,
        registry: AnimatedAvatars, in window: UIWindow
    ) async -> AnimatedAvatarPlayer {
        let host = UIView(frame: CGRect(x: 20, y: 100, width: side, height: side))
        let player = AnimatedAvatarPlayer.attach(to: host)
        player.registry = registry
        // Its own count of plays: other tests' players hold no slot of it.
        player.concurrency = AnimatedAvatarPlayer.Concurrency()
        player.trigger = trigger
        player.setAvatar(url)
        if url == Self.face {
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

    /// Already on screen when the screen appears: it rests, it does not play.
    @Test func anAvatarOnScreenAtArrivalRests() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let player = await hosted(Self.face, registry: makeRegistry(), in: window)
        #expect(!player.isHidden, "an animated avatar showed no still")
        #expect(player.still != nil)
        #expect(!player.isPlaying, "an avatar present at arrival played")
    }

    /// The two screens where the avatar is large and alone play it once on
    /// first display, however often it is shown again there.
    @Test func aFirstAppearancePlaysOncePerScope() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let scope = AnimatedAvatarScope()
        let registry = makeRegistry()
        let first = await hosted(Self.face, trigger: .firstAppearance(scope), registry: registry, in: window)
        #expect(first.isPlaying, "the first display did not play")
        let again = await hosted(Self.face, trigger: .firstAppearance(scope), registry: registry, in: window)
        #expect(!again.isPlaying, "a second display in the same screen played again")
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
        #expect(!player.isPlaying, "a 20 pt avatar played")
        #expect(AnimatedAvatarPlayer.minimumDiameter == 32)
    }

    /// The post screen's author pill: its first avatar rests, the next one
    /// paging brings in plays.
    @Test func aChangedAvatarPlaysAndTheFirstRests() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let registry = makeRegistry()
        let player = await hosted(Self.still, trigger: .change, registry: registry, in: window)
        #expect(!player.isPlaying)
        player.setAvatar(Self.face)
        #expect(await eventually { player.isPlaying }, "the next author did not play")

        let first = await hosted(Self.face, trigger: .change, registry: registry, in: window)
        #expect(!first.isPlaying, "a pill's first avatar played")
    }

    /// A profile's avatar arrives after its header is on show: its first
    /// display is when the sheet lands, and it plays then.
    @Test func anAvatarArrivingOnAScreenAlreadyUpPlaysOnItsFirstDisplay() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let host = UIView(frame: CGRect(x: 20, y: 100, width: 88, height: 88))
        let player = AnimatedAvatarPlayer.attach(to: host)
        player.registry = makeRegistry()
        player.concurrency = AnimatedAvatarPlayer.Concurrency()
        player.trigger = .firstAppearance(AnimatedAvatarScope())
        window.addSubview(host)
        player.setAvatar(Self.face)
        #expect(await eventually { player.isPlaying }, "an avatar that arrived on a screen already up never played")
    }
}
