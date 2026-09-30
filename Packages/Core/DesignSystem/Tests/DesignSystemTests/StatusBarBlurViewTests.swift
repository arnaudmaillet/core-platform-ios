import Testing
import UIKit
@testable import DesignSystem

/// `StatusBarBlurView`: the switch, the band geometry and the mask ramp. The
/// look itself was judged on simulator screenshots; these pin the rules the
/// look rests on. No test attaches the view to a window, so no blur effect is
/// ever materialised here (the headless-CI render-server stall).
@MainActor
struct StatusBarBlurViewTests {

    // MARK: Switch

    @Test func theLaunchArgumentTurnsItOn() {
        #expect(StatusBarBlurView.isEnabled(arguments: ["app", "-status-bar-blur"]))
        #expect(!StatusBarBlurView.isEnabled(arguments: ["app", "-status-bar-blur-style", "thin"]))
        #expect(!StatusBarBlurView.isEnabled(arguments: ["app"]))
    }

    @Test func installingWhileOffAddsNothing() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        #expect(StatusBarBlurView.install(in: host, enabled: false) == nil)
        #expect(host.subviews.isEmpty)
    }

    @Test func installingTwiceKeepsOneBlur() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let first = try #require(StatusBarBlurView.install(in: host, enabled: true))
        let second = StatusBarBlurView.install(in: host, enabled: true)
        #expect(first === second)
        #expect(host.subviews.filter { $0 is StatusBarBlurView }.count == 1)
    }

    /// Above the host's content whatever is added later, and never in the way
    /// of a touch.
    @Test func itSitsAboveContentAndTakesNoTouches() throws {
        let host = UIView()
        let blur = try #require(StatusBarBlurView.install(in: host, enabled: true))
        host.addSubview(UIView())
        #expect(blur.layer.zPosition > 0)
        #expect(!blur.isUserInteractionEnabled)
    }

    /// The blur is only materialised once the view reaches a window.
    @Test func noBlurIsMaterialisedOffWindow() throws {
        let blur = try #require(StatusBarBlurView.install(in: UIView(), enabled: true))
        #expect(!blur.blurLayers.isEmpty)
        #expect(blur.blurLayers.allSatisfy { $0.effect == nil })
    }

    // MARK: Geometry

    @Test func aHostAtTheWindowTopGetsTheWholeBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 0) == 62)
    }

    @Test func aHostBelowTheBandGetsNothing() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 400) == 0)
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 62) == 0)
    }

    @Test func aHostStraddlingTheBandGetsItsOverlap() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: 20) == 42)
    }

    /// Landscape: no status bar, no inset, no blur.
    @Test func noStatusBarMeansNoBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 0, hostTopInWindow: 0) == 0)
    }

    @Test func aHostAboveTheWindowTopNeverGetsMoreThanTheBand() {
        #expect(StatusBarBlurView.bandHeight(statusBandHeight: 62, hostTopInWindow: -30) == 62)
    }

    // MARK: Mask ramp

    @Test func eachLayerStartsAtItsPeakAndEndsClear() {
        for count in 1...4 {
            for index in 0..<count {
                let stops = StatusBarBlurView.maskStops(index: index, count: count, peak: 0.8)
                #expect(stops.first?.location == 0)
                #expect(abs((stops.first?.alpha ?? 0) - 0.8) < 0.0001)
                #expect(stops.last?.location == 1)
                #expect(stops.last?.alpha == 0)
            }
        }
    }

    /// Layer `i` of `n` is clear from `(i + 1) / n` of the band down, so the
    /// deepest layer reaches the band's foot and nothing reaches past it.
    @Test func layerIndexSetsWhereItFadesOut() {
        let stops = StatusBarBlurView.maskStops(index: 0, count: 3)
        let firstClear = stops.first { $0.alpha < 0.0001 }
        #expect(abs((firstClear?.location ?? 0) - 1.0 / 3.0) < 0.0001)
        let deepest = StatusBarBlurView.maskStops(index: 2, count: 3)
        let deepestClear = deepest.first { $0.alpha < 0.0001 }
        #expect(abs((deepestClear?.location ?? 0) - 1) < 0.0001)
    }

    @Test func theRampNeverBrightensGoingDown() {
        let stops = StatusBarBlurView.maskStops(index: 0, count: 1)
        for (upper, lower) in zip(stops, stops.dropFirst()) {
            #expect(lower.location >= upper.location)
            #expect(lower.alpha <= upper.alpha)
        }
    }

    @Test func thePeakIsClamped() {
        #expect(StatusBarBlurView.maskStops(index: 0, count: 1, peak: 3).first?.alpha == 1)
        #expect(StatusBarBlurView.maskStops(index: 0, count: 1, peak: -1).first?.alpha == 0)
    }

    // MARK: Tuning arguments

    @Test func theDefaultsAreOneUltraThinLayerAtFullStrength() {
        #expect(StatusBarBlurView.tunedStyle(arguments: []) == .systemUltraThinMaterial)
        #expect(StatusBarBlurView.tunedLayerCount(arguments: []) == 1)
        #expect(StatusBarBlurView.tunedPeak(arguments: []) == 1)
    }

    @Test func tuningArgumentsAreReadAndClamped() {
        #expect(StatusBarBlurView.tunedStyle(arguments: ["-status-bar-blur-style", "plain"]) == .regular)
        #expect(StatusBarBlurView.tunedLayerCount(arguments: ["-status-bar-blur-layers", "9"]) == 6)
        #expect(StatusBarBlurView.tunedLayerCount(arguments: ["-status-bar-blur-layers", "0"]) == 1)
        #expect(StatusBarBlurView.tunedPeak(arguments: ["-status-bar-blur-peak", "0.4"]) == 0.4)
        #expect(StatusBarBlurView.tunedPeak(arguments: ["-status-bar-blur-peak", "2"]) == 1)
    }
}
