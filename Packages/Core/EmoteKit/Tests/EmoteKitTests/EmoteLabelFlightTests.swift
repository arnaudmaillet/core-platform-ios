import DesignSystem
import Foundation
import MediaCore
import MediaUI
import Testing
import UIKit
@testable import EmoteKit

/// A label that ARRIVES with a flight draws its emotes from the flight's first
/// frame (#2580): the post page a hero brings in had no player yet, and its
/// squares stayed empty until the landing. It places them paused — the art on
/// its poster frame, or the skeleton while the art is on its way — and they
/// play at the landing. A label already playing when the flight leaves still
/// only holds the frame it was on (#922).
///
/// ⚠️ PER WINDOW, AND RELEASED IN EVERY TEST: `FlightActivity` is keyed by
/// window, so a flight begun here stills nothing in another suite's windows.
///
/// ⚠️ THE TESTS' FLIGHT NEVER ENDS BY ITSELF (#2590): a real flight releases
/// itself after `maximumHold`, 10 s of wall clock, and a starved runner spent
/// longer than that waiting for the art — the flight had landed by itself,
/// and the emotes played. Every expectation made during the flight first
/// checks it is still up, so an early end fails as that.
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteLabelFlightTests {
    private let font = UIFont.systemFont(ofSize: 17)
    private let text = "hot 🔥 take :lol:"

    /// The frame the poster art rests on: its first twenty are blank, so a
    /// paused clock frame or frame 0 would be an empty square.
    private static let posterIndex = 20
    private static let posterFrames = 30

    /// Thirty frames, the first `posterIndex` of them empty.
    private static func posterArt(side: Int) -> AnimatedIconArt {
        let columns = 6
        let rows = (posterFrames + columns - 1) / columns
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side * columns, height: side * rows), format: format)
        let image = renderer.image { context in
            UIColor.systemPink.setFill()
            for frame in posterIndex..<posterFrames {
                let origin = CGPoint(x: (frame % columns) * side, y: (frame / columns) * side)
                context.fill(CGRect(origin: origin, size: CGSize(width: side, height: side)))
            }
        }
        let sheet = AnimatedIconSheet(sheet: image, frameCount: posterFrames, columns: columns, frameDuration: 1.0 / 30)
        return .sheet(sheet)
    }

    /// The motion the label asks for: the loop, unless emotes may not move.
    private var motion: EmoteEngine.Motion { EmoteMotion.policy == .still ? .still : .loop }

    /// Every bucket of `ids` already resident: a layout pass installs at once.
    private func warmEngine(_ ids: [String]) throws -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        for id in ids {
            let emote = try #require(engine.catalog.emote(id: id))
            for side in EmoteEngine.pixelBuckets {
                engine.insert(Self.posterArt(side: side), for: emote, pixelSide: side, motion: motion)
            }
        }
        return engine
    }

    /// A cold engine whose art waits for `gate`.
    private func gatedEngine(_ gate: ArtGate) -> EmoteEngine {
        let engine = EmoteEngine(diskCache: nil, animationProvider: { _ in nil })
        engine.artProvider = { _, side, _ in
            await gate.wait()
            return Self.posterArt(side: side)
        }
        return engine
    }

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.isHidden = false
        return window
    }

    /// The label joins `window` and is laid out — inside a flight when one is
    /// up, as a page a hero brings in is.
    private func arrivingLabel(in window: UIWindow, engine: EmoteEngine, text: String? = nil) -> EmoteLabel {
        let label = EmoteLabel()
        label.engine = engine
        label.font = font
        label.textColor = .black
        label.setEmoteText(text ?? self.text)
        window.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 320, height: 40)
        label.layoutIfNeeded()
        return label
    }

    /// A flight in `window` that lasts until the test releases it.
    private func holdFlight(in window: UIWindow) -> FlightActivity.Lease {
        FlightActivity.begin(in: window, maximumHold: .infinity)
    }

    /// Whether the test's flight is still up over `label`. Asked through the
    /// label: a window has no `window` of its own, so asking the window
    /// itself always answers no.
    private func isInFlight(_ label: EmoteLabel) -> Bool {
        FlightActivity.isActive(for: label)
    }

    private func players(of label: EmoteLabel) -> [AnimatedIconView] {
        label.artViews.compactMap { $0 as? AnimatedIconView }
    }

    /// ⚠️ THE OWNER'S REPORT: map → post, the caption's squares empty for the
    /// whole flight. With the art in cache, a label laid out during the flight
    /// shows it at once, paused on its poster frame — never a blank frame.
    @Test func aLabelArrivingWithAFlightPlacesItsArtPausedOnThePosterFrame() throws {
        let engine = try warmEngine(["noto:1f525", "lol"])
        let window = makeWindow()
        defer { window.isHidden = true }
        let flight = holdFlight(in: window)
        defer { flight.release() }
        let label = arrivingLabel(in: window, engine: engine)
        try #require(isInFlight(label), "the flight ended before the test released it")

        #expect(label.placedEmoteCount == 2, "the arriving label placed nothing: its squares stay empty")
        let views = players(of: label)
        try #require(views.count == 2)
        #expect(views.allSatisfy { $0.isPaused }, "an emote plays through a flight")
        #expect(views.allSatisfy { !$0.isHidden }, "the art is placed hidden")
        #expect(
            views.map(\.displayedFrame) == [Self.posterIndex, Self.posterIndex],
            "not held on the poster frame: \(views.map(\.displayedFrame))"
        )
        #expect(label.skeletonCount == 0, "a skeleton over art already in cache")
        #expect(label.coveredMarkIndices == [0, 1], "a glyph drawn under a flight (#1504)")
    }

    /// With nothing in cache: skeletons from the first frame, as on any first
    /// display (#987); the art that lands mid-flight holds its poster frame.
    @Test func aLabelArrivingWithAFlightShowsSkeletonsUntilItsArtLands() async throws {
        let gate = ArtGate()
        defer { gate.open() }
        let window = makeWindow()
        defer { window.isHidden = true }
        let flight = holdFlight(in: window)
        defer { flight.release() }
        // Two Noto emoji: their art is a BAKE, whose skeleton shows at once (a
        // house `:code:` from the map catalogue is a read, shown after a grace,
        // #987).
        let label = arrivingLabel(in: window, engine: gatedEngine(gate), text: "so 🔥 good 😎")
        try #require(isInFlight(label), "the flight ended before the test released it")

        #expect(label.placedEmoteCount == 2, "the arriving label placed nothing")
        #expect(label.skeletonCount == 2, "no skeleton while the art is on its way")
        #expect(label.coveredMarkIndices == [0, 1], "a glyph drawn under the skeletons")

        gate.open()
        let landed = await settle { label.showingEmoteCount + label.posterEmoteCount == 2 }
        try #require(landed, "the art never came")
        try #require(isInFlight(label), "the flight ended before the art landed")
        let views = players(of: label)
        #expect(views.allSatisfy { $0.isPaused }, "art landing mid-flight plays")
        #expect(views.allSatisfy { $0.displayedFrame == Self.posterIndex }, "not held on the poster frame")
    }

    /// At the landing the emotes play, from the frame they held, on the
    /// shared clock — the same players, not placed again.
    @Test func theArrivingLabelsEmotesPlayWhenTheFlightLands() throws {
        let engine = try warmEngine(["noto:1f525", "lol"])
        let window = makeWindow()
        defer { window.isHidden = true }
        let flight = holdFlight(in: window)
        defer { flight.release() }
        let label = arrivingLabel(in: window, engine: engine)
        try #require(isInFlight(label), "the flight ended before the test released it")
        let held = players(of: label)
        try #require(held.count == 2 && held.allSatisfy { $0.isPaused })

        flight.release()
        label.layoutIfNeeded()
        let playing = players(of: label)
        #expect(playing.count == 2)
        #expect(zip(held, playing).allSatisfy { $0 === $1 }, "the landing placed the emotes again")
        #expect(playing.allSatisfy { !$0.isPaused }, "the emotes did not play on at the landing")
        if motion == .loop {
            #expect(playing.allSatisfy { $0.isAnimating }, "the emotes are back on no clock")
        }
    }

    /// ⚠️ UNCHANGED (#922): a label already playing when a flight leaves only
    /// holds the frame it was on — the same players, paused, not re-dressed on
    /// their poster frame, however often the flight lays it out.
    @Test func aLabelAlreadyPlayingWhenAFlightLeavesOnlyPauses() throws {
        let engine = try warmEngine(["noto:1f525", "lol"])
        let window = makeWindow()
        defer { window.isHidden = true }
        let label = arrivingLabel(in: window, engine: engine)
        let before = players(of: label)
        try #require(before.count == 2 && before.allSatisfy { !$0.isPaused })

        let flight = holdFlight(in: window)
        defer { flight.release() }
        label.setNeedsLayout()
        label.layoutIfNeeded()
        let held = before.map(\.displayedFrame)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        try #require(isInFlight(label), "the flight ended before the test released it")

        let during = players(of: label)
        #expect(zip(before, during).allSatisfy { $0 === $1 } && during.count == 2, "the flight placed the emotes again")
        #expect(during.allSatisfy { $0.isPaused }, "an emote played through a flight")
        #expect(during.map(\.displayedFrame) == held, "a held frame moved during the flight")
    }
}
