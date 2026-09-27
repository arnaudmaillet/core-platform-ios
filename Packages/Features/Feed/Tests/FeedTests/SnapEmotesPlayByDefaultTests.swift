import EmoteKit
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The feed page's two moving comment surfaces play their emotes with no
/// touch: the danmaku band (each bubble's model parked at its EXIT, off the
/// band, while Core Animation flies it across) and the subtitle pill (model
/// opacity parked at 0, held visible by a filled opacity animation).
///
/// Both read as invisible to a MODEL-only visibility test, so neither label
/// ever placed a player until a scrub wrote presentation positions into the
/// models (reported 27 September 2026: "I have to touch the danmaku to see
/// them play").
@MainActor
@Suite(.serialized)
struct SnapEmotesPlayByDefaultTests {
    private let bandWidth: CGFloat = 400

    /// Hosted and taken down within the test, like the ticker's own suite
    /// (a window released visible in a dirty turn crashes the host).
    private func hosting(_ body: (UIWindow) async throws -> Void) async rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 200))
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try await body(window)
    }

    private func emoteLabels(in view: UIView) -> [EmoteLabel] {
        view.subviews.flatMap { sub -> [EmoteLabel] in
            (sub as? EmoteLabel).map { [$0] } ?? emoteLabels(in: sub)
        }
    }

    /// Players a label placed: `AnimatedIconView`s riding over its glyphs.
    private func placedPlayers(_ label: UILabel) -> Int {
        label.subviews.filter { $0 is AnimatedIconView }.count
    }

    /// Waits (a few monitor ticks at most) for `condition`, laying out as the
    /// run loop would.
    private func settle(_ window: UIWindow, until condition: () -> Bool) async throws {
        for _ in 0..<60 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
            window.layoutIfNeeded()
        }
    }

    @Test func danmakuBubblesOnTheBandPlaceTheirEmotesWithNoTouch() async throws {
        try await hosting { window in
            let ticker = SnapCommentTickerView(frame: CGRect(x: 0, y: 0, width: bandWidth, height: 69))
            ticker.setComments((0..<12).map { TickerCommentModel(id: "r\($0)", text: "GG 🔥 \($0)") })
            window.addSubview(ticker)
            ticker.setActive(true)

            // The bubbles whose PRESENTATION is on the band — what the eye sees.
            func onBand() -> [UIView] {
                ticker.subviews.filter { bubble in
                    guard bubble.layer.animation(forKey: "flight") != nil,
                          let shown = bubble.layer.presentation()?.frame else { return false }
                    return shown.intersects(ticker.bounds)
                }
            }
            try await settle(window) {
                let shown = onBand()
                return !shown.isEmpty && shown.allSatisfy { bubble in
                    emoteLabels(in: bubble).contains { placedPlayers($0) > 0 }
                }
            }
            let shown = onBand()
            #expect(!shown.isEmpty, "the pre-fill lays bubbles on the band")
            for bubble in shown {
                // The model sits at the exit, off the band's left edge.
                #expect(bubble.frame.maxX <= 0)
                #expect(emoteLabels(in: bubble).contains { placedPlayers($0) > 0 },
                        "a flying bubble on the band animates its 🔥")
            }
        }
    }

    @Test func theSubtitlePillPlacesItsEmotesWhileItsModelOpacityIsZero() async throws {
        try await hosting { window in
            let view = SnapSubtitleView(frame: CGRect(x: 0, y: 0, width: 350, height: 60))
            window.addSubview(view)
            view.setCues([SubtitleCue(id: "a", text: "so good 🔥🔥", at: nil)])
            view.setActive(true)
            window.layoutIfNeeded()

            let label = try #require(emoteLabels(in: view).first { $0.layer.animation(forKey: "subtitle-cue") != nil })
            try await settle(window) { placedPlayers(label) > 0 }
            #expect(label.layer.opacity == 0, "the model stays parked at 0")
            #expect(placedPlayers(label) == 2)
        }
    }
}
