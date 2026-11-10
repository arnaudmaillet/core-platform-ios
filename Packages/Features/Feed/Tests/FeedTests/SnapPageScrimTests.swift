import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The page's bottom scrim protects the caption block and leaves the picture
/// alone above it (#1983): its top is the block's top less the fade — the
/// caption on a pushed post, the author row on Shots — and nothing else
/// moves it. Its curve is set in points of the block, calibrated on TikTok's
/// and Instagram's (#2175).
@MainActor
struct SnapPageScrimTests {
    private func makeChrome(
        caption: String? = "Golden hour at the pier",
        timestamp: String = "2h",
        mediaURL: URL? = URL(string: "mock://photo/single-04"),
        showsAuthorRow: Bool = false
    ) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        chrome.showsAuthorRow = showsAuthorRow
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Vera Lindqvist",
            metaText: "@vera · 2h",
            avatarURL: nil,
            caption: caption,
            mediaURL: mediaURL,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil,
            timestampText: timestamp
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    private func frame(of view: UIView, in chrome: SnapChromeView) -> CGRect {
        view.convert(view.bounds, to: chrome)
    }

    private func scrimTop(_ chrome: SnapChromeView) -> CGFloat {
        frame(of: chrome.debugScrimView, in: chrome).minY
    }

    @Test func onAPushedPostTheScrimStartsAtTheCaptionLessTheFade() {
        let chrome = makeChrome()
        let caption = frame(of: chrome.debugCaptionLabel, in: chrome)
        #expect(abs(scrimTop(chrome) - (caption.minY - SnapChromeView.scrimLead)) < 0.5)
        #expect(SnapChromeView.scrimLead == 48, "the start the owner chose (#2175, option A)")
        // Deeper than the page, clipped at its edges: never over the next page.
        #expect(frame(of: chrome.debugScrimView, in: chrome).maxY >= chrome.bounds.maxY)
        #expect(chrome.debugScrimClip.clipsToBounds && frame(of: chrome.debugScrimClip, in: chrome) == chrome.bounds)
    }

    @Test func aTimestampAloneIsTheBlock() {
        let chrome = makeChrome(caption: nil)
        let caption = frame(of: chrome.debugCaptionLabel, in: chrome)
        #expect(abs(scrimTop(chrome) - (caption.minY - SnapChromeView.scrimLead)) < 0.5)
    }

    @Test func onShotsTheScrimStartsAtTheAuthorRowLessTheFade() {
        let chrome = makeChrome(showsAuthorRow: true)
        let author = frame(of: chrome.debugAuthorRow, in: chrome)
        #expect(!chrome.debugAuthorRow.isHidden)
        #expect(abs(scrimTop(chrome) - (author.minY - SnapChromeView.scrimLead)) < 0.5)
        #expect(scrimTop(chrome) < frame(of: chrome.debugCaptionLabel, in: chrome).minY - SnapChromeView.scrimLead)
    }

    /// The measurement in the issue: the middle of the screen read 0.80 of the
    /// picture, because the scrim began at 32 % of it.
    @Test func theMiddleOfThePageIsNotUnderTheScrim() {
        for chrome in [makeChrome(), makeChrome(showsAuthorRow: true)] {
            #expect(scrimTop(chrome) > chrome.bounds.midY, "the scrim starts at \(scrimTop(chrome))")
        }
    }

    @Test func aTextPostHasNoScrim() {
        let chrome = makeChrome(mediaURL: nil)
        #expect(chrome.debugScrimView.isHidden)
    }

    /// The comment surfaces sit above the caption and no longer get the
    /// scrim (the owner's decision): shown or not, it stays where it is.
    @Test func theCommentSurfacesDoNotMoveIt() {
        let chrome = makeChrome()
        let before = scrimTop(chrome)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: (0..<6).map { TickerCommentModel(id: "c\($0)", text: "fire \($0)") },
            subtitles: [SubtitleCue(id: "a", text: "A longer semantic thought worth reading.", at: nil)],
            commentCount: 7
        ))
        chrome.layoutIfNeeded()
        #expect(scrimTop(chrome) == before)
        chrome.updateCommentStreams(FeedViewModel.CommentStreams(reactions: [], subtitles: [], commentCount: 0))
        chrome.layoutIfNeeded()
        #expect(scrimTop(chrome) == before)
    }

    /// ⚠️ A LONGER CAPTION NO LONGER MOVES IT (#2252): the caption takes one
    /// seat, two lines tall, on every post — so its top, and the scrim led
    /// from it, stand where they stood, whatever the words.
    @Test func aLongerCaptionLeavesItWhereItIs() {
        let short = makeChrome(caption: "Pier.")
        let long = makeChrome(caption: String(repeating: "Golden hour at the pier, the light going amber. ", count: 4))
        #expect(abs(scrimTop(long) - scrimTop(short)) < 0.5)
        let caption = frame(of: long.debugCaptionLabel, in: long)
        #expect(abs(scrimTop(long) - (caption.minY - SnapChromeView.scrimLead)) < 0.5)
    }

    /// The flight's replica and the live page are two chromes configured
    /// alike: one layout, one top.
    @Test func theReplicaAndTheLivePageAgree() {
        #expect(scrimTop(makeChrome()) == scrimTop(makeChrome()))
        #expect(scrimTop(makeChrome(showsAuthorRow: true)) == scrimTop(makeChrome(showsAuthorRow: true)))
    }

    /// The darkness `y` points down the page, as the scrim draws it there.
    private func darkness(atY y: CGFloat, in chrome: SnapChromeView) -> CGFloat {
        SnapChromeView.scrimAlpha(at: y - scrimTop(chrome))
    }

    private static let twoLines = "Golden hour at the pier, the light going amber over the water, the boats coming in."

    /// The same darkness at the block's top whatever the caption — one line,
    /// two, or Shots' author row over it — and the reference's on the text.
    @Test func theBlocksTopIsAsDarkOnEveryPost() {
        let one = makeChrome(caption: "Pier.")
        let two = makeChrome(caption: Self.twoLines)
        let shots = makeChrome(caption: Self.twoLines, showsAuthorRow: true)
        let tops = [
            darkness(atY: frame(of: one.debugCaptionLabel, in: one).minY, in: one),
            darkness(atY: frame(of: two.debugCaptionLabel, in: two).minY, in: two),
            darkness(atY: frame(of: shots.debugAuthorRow, in: shots).minY, in: shots),
        ]
        for top in tops {
            #expect(abs(top - SnapChromeView.scrimTopAlpha) <= 0.01, "the block's top at \(top)")
        }
        let caption = frame(of: two.debugCaptionLabel, in: two)
        #expect(caption.height > 30, "the premise: two lines (\(caption.height))")
        let lastLine = darkness(atY: caption.maxY, in: two)
        #expect(lastLine >= 0.24 && lastLine <= 0.30, "a two-line caption's last line at \(lastLine)")
    }

    /// At the screen's edge, under the toolbar — about 125 pt below a
    /// two-line block's top on a pushed post (this host has no toolbar, so
    /// the curve is read there): darker than the text, lighter than before
    /// (0.75).
    @Test func theEdgeIsLighterThanItWas() {
        let edge = SnapChromeView.scrimAlpha(at: SnapChromeView.scrimLead + 125)
        #expect(edge >= 0.55 && edge <= 0.65, "the edge at \(edge)")
    }

    /// Zero slope at the start, never steeper than the cap, no kink, darker
    /// all the way down — sampled every half point, past the page.
    @Test func theCurveIsGentleAndSmooth() {
        let cap = SnapChromeView.scrimSlopeCap
        let step: CGFloat = 0.5
        var previousSlope: CGFloat?
        var x: CGFloat = 0
        #expect(SnapChromeView.scrimAlpha(at: 0) == 0)
        #expect(SnapChromeView.scrimAlpha(at: step) / step < cap / 50, "a slope where it starts")
        while x < 1_000 {
            let slope = (SnapChromeView.scrimAlpha(at: x + step) - SnapChromeView.scrimAlpha(at: x)) / step
            #expect(slope > 0 || x < 1, "flat at \(x)")
            #expect(slope <= cap + 1e-6, "steeper than the cap at \(x): \(slope)")
            if let previousSlope {
                #expect(abs(slope - previousSlope) < cap * 0.05, "a kink at \(x)")
            }
            previousSlope = slope
            x += step
        }
        // The reference: about the first 20 pt under 3 %, read as nothing.
        #expect(SnapChromeView.scrimAlpha(at: 20) < 0.03, "the first 20 pt show")
        #expect(SnapChromeView.scrimAlpha(at: 1_000) < SnapChromeView.scrimCeiling)
    }

    /// The stops: from 0 to 1, a stop every 6 pt through the curve, every
    /// 30 pt through the slow ease, darker at each.
    @Test func theStopsAreDenseEnough() {
        let points = SnapChromeView.scrimStopPoints
        #expect(points.first == 0 && points.last == SnapChromeView.scrimHeight)
        let dense = SnapChromeView.scrimLead + SnapChromeView.scrimLinearDepth
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(b - a <= (a < dense ? 6 : 30) + 0.001, "a gap of \(b - a) at \(a)")
        }
        let alphas = SnapChromeView.scrimColors.map { $0.cgColor.alpha }
        #expect(zip(alphas.dropFirst(), alphas.dropFirst(2)).allSatisfy { $0 < $1 }, "not darker at every stop")
        #expect(SnapChromeView.scrimLocations.first == 0 && SnapChromeView.scrimLocations.last == 1)
    }
}
