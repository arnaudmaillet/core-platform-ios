import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import MapKit
import Testing
import UIKit
@testable import Maps

/// `-map-text-card` (the owner, 2026-11-08): the card over the map for the
/// text post nearest its centre.
@MainActor
struct MapTextPostCardTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func post(_ id: String, caption: String, name: String = "Ava Moreau", likes: Int64? = 1_200) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: caption, publishedAtMS: Int64((now.timeIntervalSince1970 - 7_200) * 1000),
            authorID: ProfileID("ava"), authorName: name, authorHandle: "ava", reactionCount: likes
        )
    }

    private static func content(_ id: String, caption: String, place: String? = "Pier 39") -> MapTextPostCardView.Content {
        .of(post(id, caption: caption), place: place, now: now)
    }

    // MARK: - Which post

    /// The nearest to the centre wins; the one shown keeps the card unless
    /// another is nearer by more than the give — two markers at almost the
    /// same distance do not take turns as the map drifts.
    @Test func theNearestTakesTheCardWithAGive() {
        let centre = CGPoint(x: 200, y: 300)
        let a = (id: PostID("a"), point: CGPoint(x: 200, y: 340))   // 40 away
        let b = (id: PostID("b"), point: CGPoint(x: 230, y: 300))   // 30 away
        typealias Map = MapsViewController
        #expect(Map.textCardPick(candidates: [a, b], centre: centre, current: nil) == PostID("b"))
        #expect(Map.textCardPick(candidates: [a, b], centre: centre, current: PostID("a")) == PostID("a"),
                "10 pt nearer is within the give")
        let c = (id: PostID("c"), point: CGPoint(x: 205, y: 300))   // 5 away
        #expect(Map.textCardPick(candidates: [a, c], centre: centre, current: PostID("a")) == PostID("c"))
        #expect(Map.textCardPick(candidates: [], centre: centre, current: PostID("a")) == nil)
    }

    // MARK: - The card

    private func card() -> (MapTextPostCardView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        let card = MapTextPostCardView(imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        card.frame = CGRect(x: 16, y: 600, width: 370, height: 10)
        window.addSubview(card)
        return (card, window)
    }

    private func height(of card: MapTextPostCardView) -> CGFloat {
        card.systemLayoutSizeFitting(
            CGSize(width: 370, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// The words: who, when, what, where.
    @Test func theCardSaysWhoWhenWhatAndWhere() {
        let words = Self.content("p1", caption: "  Golden hour at the pier.  ")
        #expect(words.authorName == "Ava Moreau")
        #expect(words.age == "2h")
        #expect(words.caption == "Golden hour at the pier.")
        #expect(words.place == "Pier 39")
        #expect(words.likes == 1_200)
        let (card, window) = card()
        defer { window.isHidden = true }
        card.show(.content(words), animated: false)
        #expect(!card.isHidden && card.alpha == 1)
        #expect(card.debugFrontCaption == "Golden hour at the pier.")
        #expect(card.debugFrontAuthor == "Ava Moreau")
        #expect(card.accessibilityLabel?.contains("Golden hour") == true)
    }

    /// One height, whatever the words: a short caption or a long one, a
    /// place or none, loading or loaded — the card never jumps on the map.
    @Test func oneHeightWhateverTheWords() {
        let (card, window) = card()
        defer { window.isHidden = true }
        card.show(.content(Self.content("p1", caption: "Short.")), animated: false)
        let short = height(of: card)
        card.show(.content(Self.content("p2", caption: String(repeating: "A much longer caption that runs on. ", count: 6), place: nil)), animated: false)
        let long = height(of: card)
        card.show(.loading(PostID("p3")), animated: false)
        let loading = height(of: card)
        #expect(abs(short - long) < 0.5 && abs(short - loading) < 0.5, "\(short) \(long) \(loading)")
        #expect(card.debugShowsBones)
    }

    /// Bones while the words come, then the words in place; down when no
    /// text post is in view.
    @Test func bonesThenWordsThenDown() {
        let (card, window) = card()
        defer { window.isHidden = true }
        card.show(.loading(PostID("p1")), animated: false)
        #expect(card.debugShowsBones)
        #expect(card.debugFrontCaption == nil)
        card.show(.content(Self.content("p1", caption: "Here now.")), animated: false)
        #expect(!card.debugShowsBones)
        #expect(card.debugFrontCaption == "Here now.")
        card.show(.hidden, animated: false)
        #expect(card.isHidden)
    }

    /// Each post its own card (the owner, 2026-11-08), the one before
    /// peeking out above the front one: a turn forward brings the next to
    /// the front, the one it left above it; a turn back brings back the one
    /// above, the one before it above in turn.
    @Test func theNextPostPeeksFromBehindAndTurnsForward() {
        let (card, window) = card()
        defer { window.isHidden = true }
        let a = Self.content("a", caption: "First.")
        let b = Self.content("b", caption: "Second.")
        let c = Self.content("c", caption: "Third.")
        card.show(.content(a), behind: .content(b), animated: false)
        card.frame.size.height = height(of: card)
        card.layoutIfNeeded()
        #expect(card.debugFrontCaption == "First.")
        #expect(card.debugBehindCaption == "Second.")
        #expect(card.debugBehindPeeks, "the next card does not show above the front one")
        #expect(!card.debugBehindShowsWords, "the card above shows its words through the front one")
        #expect(card.debugFrontShowsWords)
        // A tap on the card above's strip turns back; on the front card, not.
        #expect(card.isOnCardAbove(CGPoint(x: card.bounds.midX, y: 4)))
        #expect(!card.isOnCardAbove(CGPoint(x: card.bounds.midX, y: MapTextPostCardView.peek + 20)))

        card.show(.content(b), behind: .content(c), turn: .next, animated: false)
        card.layoutIfNeeded()
        #expect(card.debugFrontCaption == "Second.")
        #expect(card.debugBehindCaption == "Third.")
        #expect(card.debugBehindPeeks)

        card.show(.content(a), behind: .content(b), turn: .previous, animated: false)
        card.layoutIfNeeded()
        #expect(card.debugFrontShowsWords && !card.debugBehindShowsWords)
        #expect(card.debugFrontCaption == "First.")
        #expect(card.debugBehindCaption == "Second.")

        // Nothing after: no card behind.
        card.show(.content(a), behind: .hidden, animated: false)
        #expect(card.debugBehindCaption == nil)
        #expect(!card.debugBehindPeeks)
    }

    /// The carousel loops (the owner, 2026-11-08): after the last post the
    /// first, before the first the last; a loop of one has no neighbour.
    @Test func theCarouselLoops() {
        func pin(_ id: String) -> MapAnnotation {
            MapAnnotation(pin: MapPin(postID: PostID(id), latitude: 48.85, longitude: 2.35, thumbnailURL: nil, kind: .text))
        }
        let deck: [any MKAnnotation] = [pin("a"), pin("b"), pin("c")]
        typealias Map = MapsViewController
        #expect(Map.neighbour(of: 0, in: deck, by: 1) === deck[1])
        #expect(Map.neighbour(of: 2, in: deck, by: 1) === deck[0], "the last post's next is the first")
        #expect(Map.neighbour(of: 0, in: deck, by: -1) === deck[2], "the first post's previous is the last")
        #expect(Map.neighbour(of: 0, in: [deck[0]], by: 1) == nil)
    }

    /// The flag is the debug dashboard's, read at launch.
    @Test func theFlagIsListed() {
        #expect(DebugFlags.all.contains { $0.argument == "-map-text-card" && $0.appliesAtLaunch })
    }
}
