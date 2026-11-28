import CoreModels
import DesignSystem
import PostGrid
import Testing
import UIKit
@testable import Maps

/// The rounded text bubble (#2330): it unfolds from the round into a rounded
/// rectangle — the four corners at one radius, 18 pt (#2347) — the marker at
/// its top-left whatever its height. The only bubble, unflagged: the owner's
/// decision, 2026-11-28 (the capsule kept that morning, reversed the same
/// day).
@MainActor
struct MapBubbleRoundedTests {
    private static let side = 44 * MapFeaturedHalo.scale
    private static let padding = MapTextBubbleView.markerPadding

    private static let channel = ChannelEmbed(
        conversationID: ConversationID("ch-printroom"), name: "Print room", description: "Darkroom hours.",
        subscriberCount: 820, visibility: .public, viewerState: .none
    )
    private static let voice = PostVoice(assetID: "voice-post-hike", url: URL(fileURLWithPath: "/tmp/hike.m4a"),
                                         duration: 12.6, waveform: Array(repeating: 14, count: 100))

    private enum Kind: CaseIterable { case oneLine, threeLines, voice, showcase }

    private static func content(_ kind: Kind) -> MapTextBubbleView.Content {
        var post = GalleryPost(
            id: PostID("p-\(kind)"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: kind == .oneLine ? "Hi" : "Golden hour at the pier, the light hit the water and everyone stopped talking",
            publishedAtMS: 1_800_000_000_000,
            authorID: ProfileID("ava"), authorName: "Ava Moreau", authorHandle: "ava"
        )
        switch kind {
        case .voice: post.voice = voice
        case .showcase: post.embed = .channel(channel)
        default: break
        }
        return .of(post, now: Date(timeIntervalSince1970: 1_800_007_200), showsVoice: kind == .voice,
                   showsEmbed: kind == .showcase)
    }

    private static func window() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        return window
    }

    /// A bubble standing alone, unfolded at its own size.
    private static func bubble(_ kind: Kind, in window: UIWindow) -> MapTextBubbleView {
        let bubble = MapTextBubbleView()
        bubble.markerSide = side
        bubble.setContent(content(kind))
        window.addSubview(bubble)
        bubble.frame = CGRect(origin: CGPoint(x: 20, y: 300), size: bubble.sizeThatFits(.zero))
        bubble.layoutIfNeeded()
        return bubble
    }

    /// The radius UIKit draws at each corner, top-left first.
    private static func drawn(_ bubble: MapTextBubbleView) -> [CGFloat] {
        let corners: [UIRectCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        return corners.map { bubble.debugGlass.effectiveRadius(corner: $0) }
    }

    /// An unfolded bubble round a 44 pt marker, through the halo, as the map
    /// opens it.
    private static func unfold(_ kind: Kind, in window: UIWindow) -> (bubble: MapTextBubbleView, card: UIView)? {
        let host = UIView(frame: CGRect(x: 179, y: 400, width: 44, height: 44))
        let card = UIView(frame: host.bounds)
        host.addSubview(card)
        window.addSubview(host)
        let halo = MapFeaturedHalo()
        halo.set(true, card: card, in: host, animated: false)
        halo.setBubble(content(kind), card: card, in: host, animated: false)
        guard let bubble = halo.debugBubble else { return nil }
        return (bubble, card)
    }

    /// Folded, a circle round the marker; unfolded, the four corners at
    /// `roundedCorner`, 18 pt — the top-left no rounder than the others
    /// (#2347) — the one-line bubble, as tall as the marker and its padding,
    /// included.
    @Test func roundedCornersPerState() {
        let window = Self.window()
        defer { window.isHidden = true }
        for kind in [Kind.oneLine, .threeLines, .showcase] {
            let bubble = Self.bubble(kind, in: window)
            let unfolded = MapTextBubbleView.Corners(all: MapTextBubbleView.roundedCorner)
            #expect(MapTextBubbleView.corners(for: bubble.bounds.size, markerSide: Self.side) == unfolded,
                    "\(kind)")
            let drawn = Self.drawn(bubble)
            for radius in drawn {
                #expect(abs(radius - MapTextBubbleView.roundedCorner) < 0.5, "\(kind): \(drawn)")
            }

            let folded = Self.side + 2 * Self.padding
            bubble.bounds = CGRect(x: 0, y: 0, width: folded, height: folded)
            bubble.layoutIfNeeded()
            #expect(MapTextBubbleView.corners(for: bubble.bounds.size, markerSide: Self.side)
                == MapTextBubbleView.Corners(all: folded / 2), "\(kind): folded is not a circle")
            for radius in Self.drawn(bubble) {
                #expect(abs(radius - folded / 2) < 0.5, "\(kind): folded \(Self.drawn(bubble))")
            }
        }
    }

    /// At every size the unfold and the fold pass through, the four corners
    /// share one radius (#2347): no frame with one corner rounder than the
    /// others.
    @Test func roundedCornersAreOneRadiusAtEverySize() {
        let folded = Self.side + 2 * Self.padding
        for width in stride(from: folded, through: folded + 260, by: 13) {
            for height in stride(from: folded, through: folded + 140, by: 7) {
                let radii = MapTextBubbleView.corners(for: CGSize(width: width, height: height), markerSide: Self.side)
                #expect(radii == MapTextBubbleView.Corners(all: radii.topLeft), "\(width)×\(height): \(radii)")
            }
        }
    }

    /// The marker sits at the top-left, `markerPadding` from the top and the
    /// leading edge, at every height — one line, three, a voice, a showcase;
    /// the bubble stays centred on the marker's place; the author's first
    /// baseline is level with the marker's upper half, the words on its
    /// right.
    @Test func roundedMarkerSitsTopLeftAtEveryHeight() throws {
        let window = Self.window()
        defer { window.isHidden = true }
        var heights: [Kind: CGFloat] = [:]
        for kind in Kind.allCases {
            let (bubble, card) = try #require(Self.unfold(kind, in: window), "\(kind): no bubble")
            heights[kind] = bubble.bounds.height
            #expect(abs(card.frame.minX - bubble.frame.minX - Self.padding) < 0.5,
                    "\(kind): the marker is not at the leading edge: \(card.frame) in \(bubble.frame)")
            #expect(abs(card.frame.minY - bubble.frame.minY - Self.padding) < 0.5,
                    "\(kind): the marker is not at the top: \(card.frame) in \(bubble.frame)")
            #expect(abs(card.frame.width - Self.side) < 0.5)
            #expect(abs(bubble.center.x - card.center.x) < 0.5 && abs(bubble.center.y - card.center.y) < 0.5,
                    "\(kind): the bubble is not centred on the marker's place")
            let end = bubble.convert(bubble.markerCentre, to: card.superview)
            #expect(abs(card.frame.midX - end.x) < 0.5 && abs(card.frame.midY - end.y) < 0.5, "\(kind)")

            let author = bubble.authorLabel.convert(bubble.authorLabel.bounds, to: bubble)
            let font = try #require(bubble.authorLabel.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            let baseline = author.minY + font.ascender
            #expect(baseline > Self.padding && baseline <= Self.padding + Self.side / 2 + 0.5,
                    "\(kind): the author's baseline \(baseline) is not beside the marker's upper half")
            #expect(bubble.debugColumnFrame.minX > Self.padding + Self.side, "\(kind): the words are not on the right")
        }
        let oneLine = try #require(heights[.oneLine])
        #expect(abs(oneLine - (Self.side + 2 * Self.padding)) < 0.5, "the one-line bubble is not the marker's height")
        #expect(try #require(heights[.threeLines]) > oneLine + 1, "three lines are no taller than one")
        #expect(try #require(heights[.showcase]) > heights[.threeLines]!, "the showcase is no taller than the words")
        #expect(try #require(heights[.voice]) > oneLine + 1, "the voice is no taller than one line")
    }

    /// The column does not move as the rounded bubble grows: it is held to
    /// the top, not centred in the bounds — folded or unfolded, the same
    /// place.
    @Test func roundedColumnNeverMovesAsItUnfolds() {
        let window = Self.window()
        defer { window.isHidden = true }
        let bubble = Self.bubble(.threeLines, in: window)
        let unfolded = bubble.debugColumnFrame
        #expect(abs(unfolded.minY - MapTextBubbleView.insets.top) < 0.5, "\(unfolded)")
        let folded = Self.side + 2 * Self.padding
        bubble.bounds = CGRect(x: 0, y: 0, width: folded, height: folded)
        bubble.layoutIfNeeded()
        #expect(bubble.debugColumnFrame == unfolded, "the column moved: \(bubble.debugColumnFrame) vs \(unfolded)")
    }
}
