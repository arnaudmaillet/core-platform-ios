import CoreModels
import DesignSystem
import LaunchArguments
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Maps

/// The text bubble (#2203, the owner, 2026-11-09; every build since #2299): the text marker nearest the
/// map's centre opens a glass bubble round it, with its author and words.
@MainActor
struct MapTextBubbleTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func content(caption: String, name: String = "Ava Moreau") -> MapTextBubbleView.Content {
        let post = GalleryPost(
            id: PostID("a"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: Int64((now.timeIntervalSince1970 - 7_200) * 1000),
            authorID: ProfileID("ava"), authorName: name, authorHandle: "ava", reactionCount: 1_200
        )
        return .of(post, now: now)
    }

    // MARK: - Which post

    /// The nearest to the centre wins; the one featured keeps the bubble
    /// unless another is nearer by more than the give — two markers at
    /// almost the same distance do not take turns as the map drifts.
    @Test func theNearestTakesTheBubbleWithAGive() {
        let centre = CGPoint(x: 200, y: 300)
        let a = (id: PostID("a"), point: CGPoint(x: 200, y: 340))   // 40 away
        let b = (id: PostID("b"), point: CGPoint(x: 230, y: 300))   // 30 away
        typealias Map = MapsViewController
        #expect(Map.textBubblePick(candidates: [a, b], centre: centre, current: nil) == PostID("b"))
        #expect(Map.textBubblePick(candidates: [a, b], centre: centre, current: PostID("a")) == PostID("a"),
                "10 pt nearer is within the give")
        let c = (id: PostID("c"), point: CGPoint(x: 205, y: 300))   // 5 away
        #expect(Map.textBubblePick(candidates: [a, c], centre: centre, current: PostID("a")) == PostID("c"))
        #expect(Map.textBubblePick(candidates: [], centre: centre, current: PostID("a")) == nil)
    }

    // MARK: - What it says

    /// The author's name and the post's age; the words on two lines at most,
    /// their blank lines folded.
    @Test func theBubbleSaysWhoWhenAndTheWords() {
        let words = Self.content(caption: "  Golden hour.\n\n\nThe light hit the water.  ")
        #expect(words.authorName == "Ava Moreau")
        #expect(!words.age.isEmpty, "no age")
        #expect(MapTextBubbleView.shownText(of: words.caption) == "Golden hour.\nThe light hit the water.")
        #expect(MapTextBubbleView.maxLines == 2)
        let bubble = MapTextBubbleView()
        bubble.markerSide = 44 * MapFeaturedHalo.scale
        bubble.setContent(words)
        #expect(bubble.authorLabel.attributedText?.string == "Ava Moreau · \(words.age)")
        #expect(bubble.label.text == "Golden hour.\nThe light hit the water.")
        #expect(bubble.label.numberOfLines == 2)
    }

    /// A city's or a country's marker takes the bubble when its face is a
    /// text post, with that post's bubble; never when its face is a picture
    /// (the owner, 2026-11-09).
    @Test func aPlacesMarkerSpeaksForItsTextFace() {
        func pin(_ id: String, kind: MapPin.Kind) -> MapPin {
            MapPin(postID: PostID(id), latitude: 48.85, longitude: 2.35, thumbnailURL: nil, kind: kind)
        }
        typealias Map = MapsViewController
        let text = MapAnnotation(pin: pin("t", kind: .text))
        let photo = MapAnnotation(pin: pin("p", kind: .photo))
        #expect(Map.textBubblePin(of: text)?.postID == PostID("t"))
        #expect(Map.textBubblePin(of: photo) == nil, "a picture took the bubble")
    }

    // MARK: - Round the marker

    private func marker(at x: CGFloat, in window: UIWindow) -> (UIView, UIView) {
        let host = UIView(frame: CGRect(x: x, y: 400, width: 44, height: 44))
        let card = UIView(frame: host.bounds)
        host.addSubview(card)
        window.addSubview(host)
        return (host, card)
    }

    /// The bubble unfolds out of the marker, centred on its place — the
    /// marker at its LEFT end, the author and words on its right, the bubble
    /// behind it, in glass — centred on it even near an edge; the whole
    /// bubble takes the marker's tap; folded, the marker is home.
    @Test func theBubbleUnfoldsOutOfTheMarker() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let (host, card) = marker(at: 179, in: window)
        let halo = MapFeaturedHalo()
        halo.set(true, card: card, in: host, animated: false)
        halo.setBubble(Self.content(caption: "Golden hour at the pier, the light hit the water"), card: card, in: host,
                       animated: false)
        let bubble = halo.debugBubble
        #expect(bubble != nil)
        if let bubble {
            #expect(host.subviews.firstIndex(of: bubble)! < host.subviews.firstIndex(of: card)!, "the bubble covers the marker")
            #expect(abs(bubble.center.x - card.center.x) < 0.5, "the bubble is not centred on the marker's place")
            let end = bubble.convert(bubble.markerCentre, to: host)
            #expect(abs(card.frame.midX - end.x) < 0.5 && abs(card.frame.midY - end.y) < 0.5,
                    "the marker is not at the bubble's left end: \(card.frame) vs \(end)")
            #expect(card.frame.midX < card.center.x, "the marker did not slide left")
            let words = bubble.convert(bubble.debugColumnFrame, to: host)
            #expect(words.minX > card.frame.maxX, "the words are not on the marker's right")
            let author = bubble.authorLabel.convert(bubble.authorLabel.bounds, to: host)
            let caption = bubble.label.convert(bubble.label.bounds, to: host)
            #expect(author.maxY <= caption.minY + 0.5, "the author is not over the words")
            #expect(halo.bubbleHitFrame == bubble.frame, "the bubble does not take the marker's tap")
            #expect(bubble.debugIsGlass && bubble.debugHasGlass, "the bubble is not glass")
        }

        // Near the screen's right edge: still centred on its marker, running
        // off the screen as the map does.
        let (edgeHost, edgeCard) = marker(at: 350, in: window)
        let edge = MapFeaturedHalo()
        edge.set(true, card: edgeCard, in: edgeHost, animated: false)
        edge.setBubble(Self.content(caption: "Golden hour at the pier"), card: edgeCard, in: edgeHost, animated: false)
        if let bubble = edge.debugBubble {
            #expect(abs(bubble.center.x - edgeCard.center.x) < 0.5, "near the edge, the bubble was nudged off its marker")
        }

        halo.set(false, card: card, in: host, animated: false)
        #expect(halo.debugBubble == nil)
        #expect(halo.bubbleHitFrame == nil)
        #expect(card.transform == .identity, "the marker did not come home")
    }

    /// A fast zoom re-faces a marker kept through a re-cluster: its picture
    /// is re-placed under the transform that slides it to its bubble's left
    /// end — and keeps it there (the owner, 2026-11-09: the marker jumped
    /// back to the middle of its bubble, over the words).
    @Test func aNewFaceKeepsTheMarkerAtItsBubblesEnd() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let pipeline = ImagePipeline(fetcher: PlaceholderImageFetcher())
        func pin(_ id: String, kind: MapPin.Kind) -> MapPin {
            MapPin(postID: PostID(id), latitude: 48.85, longitude: 2.35,
                   thumbnailURL: kind == .text ? nil : URL(string: "mock://media/\(id)"), kind: kind)
        }
        let view = MapAnnotationView(annotation: nil, reuseIdentifier: nil)
        view.configure(with: pin("t", kind: .text), imagePipeline: pipeline)
        view.center = CGPoint(x: 200, y: 400)
        window.addSubview(view)
        view.setFeatured(true, animated: false)
        view.setBubble(Self.content(caption: "Golden hour at the pier"), animated: false)
        let slid = view.card.transform
        #expect(slid.tx < 0, "the marker did not slide to the bubble's left end")
        #expect(view.bubblePostID == PostID("a"))

        view.configure(with: pin("p", kind: .photo), imagePipeline: pipeline)
        #expect(view.card.transform == slid)
        #expect(abs(view.card.center.x - view.bounds.midX) < 0.5 && abs(view.card.center.y - view.bounds.midY) < 0.5,
                "the re-faced marker left its place: \(view.card.center) in \(view.bounds)")
        #expect(view.card.bounds.size == view.bounds.size, "the re-faced picture is not the marker's size")
    }

    /// The featured marker wears no ring: the bubble says which it is (the
    /// owner, 2026-11-09). Only the marker itself and its bubble are drawn.
    @Test func theFeaturedMarkerWearsNoRing() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let (host, card) = marker(at: 179, in: window)
        let halo = MapFeaturedHalo()
        halo.set(true, card: card, in: host, animated: false)
        #expect(host.subviews == [card], "something besides the marker is drawn: \(host.subviews)")
        #expect(card.transform == CGAffineTransform(scaleX: MapFeaturedHalo.scale, y: MapFeaturedHalo.scale))
    }

    /// The bubble ships in every build (#2299): its flag is gone, as the
    /// other text cards' flags are.
    @Test func noFlagIsLeft() {
        let retired: Set<String> = ["-map-text" + "-bubble", "-map-text-card", "-map-text" + "-bubble-around"]
        #expect(!DebugFlags.all.contains { retired.contains($0.argument) })
    }

    /// Nothing gates the bubble any more (#2299): the map features the
    /// nearest text marker with no argument passed. Read off the sources,
    /// since a whole map screen won't stand up in a unit test.
    @Test func nothingGatesTheBubble() throws {
        let maps = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Maps")
        for name in ["MapsViewController.swift", "MapsViewController+TextBubble.swift"] {
            let source = try String(contentsOf: maps.appendingPathComponent(name), encoding: .utf8)
            #expect(!source.contains("usesTextBubble"), "\(name) still gates the bubble")
            #expect(!source.contains("DebugFlags.isOn(\"-map-text"), "\(name) still reads a bubble flag")
        }
    }
}
