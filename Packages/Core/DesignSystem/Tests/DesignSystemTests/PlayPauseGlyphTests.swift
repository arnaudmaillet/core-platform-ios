import QuartzCore
import Testing
import UIKit
@testable import DesignSystem

/// The app's one play ⇄ pause swap (#2276): each site's motion from one
/// switch, Reduce Motion's cross-fade, and one glyph left once a swap has
/// ended — or been overtaken.
@MainActor
struct PlayPauseGlyphTests {
    private static let play = AppSymbol.play.image(AppSymbol.fixed(22, weight: .semibold))
    private static let pause = AppSymbol.pause.image(AppSymbol.fixed(22, weight: .semibold))

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        return window
    }

    /// An image view showing the play, in a window.
    private func hostedGlyph(in window: UIWindow) -> UIImageView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        window.addSubview(host)
        let view = UIImageView(image: Self.play)
        view.contentMode = .center
        view.frame = CGRect(x: 40, y: 40, width: 40, height: 40)
        host.addSubview(view)
        return view
    }

    /// A configured button showing the play, laid out in a window.
    private func hostedButton(in window: UIWindow) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = Self.play
        let button = UIButton(configuration: configuration)
        button.frame = CGRect(x: 40, y: 40, width: 44, height: 44)
        window.addSubview(button)
        button.layoutIfNeeded()
        return button
    }

    /// Waits, a bounded while, for the swap's copies to go.
    private func settled(_ view: UIView) async -> Bool {
        for _ in 0..<40 {
            if PlayPauseGlyph.debugCopies(of: view) == 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return PlayPauseGlyph.debugCopies(of: view) == 0
    }

    // MARK: - The one switch

    /// Outside glass the system's Replace; in Liquid Glass the scale and
    /// fade — decided in one place.
    @Test func eachSiteHasOneMotion() {
        #expect(PlayPauseGlyph.swap(for: .soundSheet) == .scaleAndFade, "the sheet's glyph is in glass")
        #expect(PlayPauseGlyph.swap(for: .mediaFlash) == .scaleAndFade, "the flash is a glass capsule")
        for site in [PlayPauseGlyph.Site.voicePanel, .voiceComposerChip, .voiceComposerTake, .mediaTimeline] {
            #expect(PlayPauseGlyph.swap(for: site) == .replace, "\(site)")
        }
    }

    /// Reduce Motion cross-fades at every site; unanimated, a cut.
    @Test(arguments: PlayPauseGlyph.Site.allCases)
    func reduceMotionCrossFadesEverywhere(_ site: PlayPauseGlyph.Site) {
        #expect(PlayPauseGlyph.motion(for: site, animated: true, reducesMotion: true) == .crossFade)
        #expect(PlayPauseGlyph.motion(for: site, animated: false, reducesMotion: true) == .cut)
        #expect(PlayPauseGlyph.motion(for: site, animated: false, reducesMotion: false) == .cut)
        let expected: PlayPauseGlyph.Motion = PlayPauseGlyph.swap(for: site) == .replace ? .replace : .scaleAndFade
        #expect(PlayPauseGlyph.motion(for: site, animated: true, reducesMotion: false) == expected)
    }

    // MARK: - Reduce Motion

    /// ⚠️ Under Reduce Motion the swap is a cross-fade in place: nothing
    /// scales, no copy stands beside the glyph.
    @Test func underReduceMotionAnImageViewCrossFades() throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let view = hostedGlyph(in: window)
        let motion = PlayPauseGlyph.swap(view, to: Self.pause, site: .soundSheet, animated: true, reducesMotion: true)
        #expect(motion == .crossFade)
        #expect(view.image === Self.pause)
        let fade = try #require(view.layer.animation(forKey: PlayPauseGlyph.crossFadeKey) as? CATransition)
        #expect(fade.type == .fade)
        #expect(view.transform == .identity && view.alpha == 1)
        #expect(PlayPauseGlyph.debugCopies(of: view) == 0)
    }

    @Test func underReduceMotionAButtonCrossFades() throws {
        let window = makeWindow()
        defer { window.isHidden = true }
        let button = hostedButton(in: window)
        let motion = PlayPauseGlyph.swap(button, site: .mediaTimeline, animated: true, reducesMotion: true) {
            button.configuration?.image = Self.pause
        }
        #expect(motion == .crossFade)
        #expect(button.configuration?.image === Self.pause)
        #expect(button.configuration?.symbolContentTransition == nil, "a cross-fade, not a Replace")
        let fade = try #require(button.layer.animation(forKey: PlayPauseGlyph.crossFadeKey) as? CATransition)
        #expect(fade.type == .fade)
        #expect(PlayPauseGlyph.debugCopies(of: button) == 0)
    }

    // MARK: - Replace

    @Test func outsideGlassAButtonTakesTheReplace() {
        let window = makeWindow()
        defer { window.isHidden = true }
        let button = hostedButton(in: window)
        let motion = PlayPauseGlyph.swap(button, site: .voiceComposerChip, animated: true, reducesMotion: false) {
            button.configuration?.image = Self.pause
        }
        #expect(motion == .replace)
        #expect(button.configuration?.symbolContentTransition != nil, "the system's Replace")
        #expect(button.configuration?.image === Self.pause)
    }

    // MARK: - The scale and fade

    /// The old glyph leaves on a copy, the view springs the new one in — and
    /// once it has, one glyph is left, whole.
    @Test func theScaleAndFadeLeavesOneGlyph() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let view = hostedGlyph(in: window)
        let motion = PlayPauseGlyph.swap(view, to: Self.pause, site: .soundSheet, animated: true, reducesMotion: false)
        #expect(motion == .scaleAndFade)
        #expect(PlayPauseGlyph.debugCopies(of: view) == 1, "the old glyph leaves on a copy")
        #expect(view.image === Self.pause)
        #expect(await settled(view), "the leaving copy stayed")
        #expect(view.alpha == 1 && view.transform == .identity)
    }

    /// A swap overtaking one in flight starts from where it had got to, and
    /// still leaves one glyph — the last one asked for.
    @Test func anInterruptedScaleAndFadeLeavesOneGlyph() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let view = hostedGlyph(in: window)
        PlayPauseGlyph.swap(view, to: Self.pause, site: .soundSheet, animated: true, reducesMotion: false)
        PlayPauseGlyph.swap(view, to: Self.play, site: .soundSheet, animated: true, reducesMotion: false)
        #expect(PlayPauseGlyph.debugCopies(of: view) == 1, "the overtaken swap's copy stayed")
        #expect(await settled(view))
        #expect(view.image === Self.play)
        #expect(view.alpha == 1 && view.transform == .identity)
    }

    /// On a button, two copies play the swap over its hidden glyph, which
    /// shows again once the new one has landed — overtaken or not.
    @Test func aButtonsScaleAndFadeLeavesItsOwnGlyph() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let button = hostedButton(in: window)
        PlayPauseGlyph.swap(button, site: .soundSheet, animated: true, reducesMotion: false) {
            button.configuration?.image = Self.pause
        }
        #expect(PlayPauseGlyph.debugCopies(of: button) == 2, "a leaving and an arriving copy")
        #expect(button.imageView?.alpha == 0)
        PlayPauseGlyph.swap(button, site: .soundSheet, animated: true, reducesMotion: false) {
            button.configuration?.image = Self.play
        }
        #expect(PlayPauseGlyph.debugCopies(of: button) == 2, "the overtaken swap's copies stayed")
        #expect(await settled(button))
        #expect(button.imageView?.alpha == 1)
        #expect(button.configuration?.image === Self.play)
    }

    /// The icon button's own scale and fade (the voice's play button, if its
    /// site moves to it): no Replace in the configuration, the decision
    /// recorded, one glyph left.
    @Test func anIconButtonScalesAndFadesWhenAsked() async {
        let window = makeWindow()
        defer { window.isHidden = true }
        let button = AppIconButton(style: .glyph, content: .symbol(AppSymbol.play.rawValue))
        button.symbolSwap = .scaleAndFade
        button.followsContentSize = false
        button.frame = CGRect(x: 40, y: 40, width: 44, height: 44)
        window.addSubview(button)
        button.layoutIfNeeded()
        #expect(button.configuration?.symbolContentTransition == nil)
        button.setContent(.symbol(AppSymbol.pause.rawValue), animated: true)
        #expect(button.events.last == .symbolScaleAndFade)
        #expect(await settled(button))
        #expect(button.imageView?.alpha == 1)
        #expect(button.content.symbol == AppSymbol.pause.rawValue)
    }
}
