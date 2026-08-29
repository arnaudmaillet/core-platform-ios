import CoreModels
import DesignSystem
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **THE SPECIFICATION FOR THE CAPTION ROW — one face, whatever the post is
/// made of.**
///
/// ## What changed, and what it costs
///
/// The caption row used to wear two faces: a glass bubble beside an avatar for
/// a post with a photograph, and the gallery card's flat content — no bubble,
/// no avatar, a rule underneath — for a text post. That split had a reason
/// worth stating, because this suite overrides it: a text page is opened by a
/// reveal that grows the gallery ROW into the page, so the row's caption and
/// the page's first row were deliberately the same object at the same inset.
/// A bubble sits 71pt from the screen edge where the row's caption sits at 32.
///
/// The product decision is that a reader meets ONE object — the post, as the
/// first message in its own thread — and that a post's format is not a reason
/// to redraw it. So the bubble is now the only face, and the reveal's job is
/// to carry the eye to it rather than to pretend nothing moved.
///
/// ⚠️ These are about what a reader SEES: which views are drawn, and at which
/// edge. They name no style enum and no branch, so an implementation that
/// deletes the second face entirely satisfies them — which is the point.
@MainActor
struct PostCaptionFaceSpecTests {
    // MARK: - Fixtures

    private static func post(
        caption: String, hasMedia: Bool, id: String = "post-0001"
    ) -> PostDetailDisplayModel {
        PostDetailDisplayModel(entry: FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("p1"), caption: caption,
                attachments: hasMedia ? [MediaAttachment(
                    url: URL(string: "mock://photo/0"),
                    thumbnailURL: URL(string: "mock://poster/0"),
                    mimeType: "image/jpeg", pixelWidth: 1080, pixelHeight: 1080
                )] : [],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p1"), handle: "ava", displayName: "Ava Moreau",
                avatarURL: nil
            )
        ), now: Date(timeIntervalSince1970: 60 * 60))
    }

    private static let width: CGFloat = 402

    private static func row(
        caption: String = "Shipping the new build tonight.",
        hasMedia: Bool,
        likes: Int64? = 40
    ) -> CaptionBubbleCell {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.configure(
            with: post(caption: caption, hasMedia: hasMedia),
            imagePipeline: nil,
            likeCount: likes
        )
        cell.layoutIfNeeded()
        return cell
    }

    private static func allViews<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var found: [T] = []
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let match = view as? T { found.append(match) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func firstView<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        allViews(type, in: root).first
    }

    /// Hidden anywhere up the chain is hidden: a face is off when nothing it
    /// contains reaches the screen, not only when its own flag is set.
    private static func isDrawn(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        return true
    }

    /// Every visible label in the row, so a spec can ask what the reader can
    /// read without knowing which component owns which string.
    private static func drawnLabels(in root: UIView) -> [UILabel] {
        allViews(UILabel.self, in: root).filter { isDrawn($0) && !($0.text ?? "").isEmpty }
    }

    // MARK: - One face

    /// A MEDIA post: avatar, bubble. The face this row has always had.
    @Test func aMediaPostIsAnAvatarAndABubble() throws {
        let cell = Self.row(hasMedia: true)

        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        #expect(Self.isDrawn(bubble))
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        #expect(Self.isDrawn(avatar))
    }

    /// ⚠️ AND SO IS A TEXT POST — the whole of this change.
    ///
    /// Reported as: "on n'a pas de bulle ni l'avatar de l'auteur, juste un
    /// séparateur". A text post is a post; the reader should not be able to
    /// tell from the caption row which pipeline drew it.
    @Test func aTextPostIsTheSameAvatarAndTheSameBubble() throws {
        let cell = Self.row(hasMedia: false)

        let bubble = try #require(
            Self.firstView(SnapPostInfoCardView.self, in: cell),
            "a text post's caption is not in a bubble"
        )
        #expect(Self.isDrawn(bubble), "the bubble exists but is not drawn on a text post")
        let avatar = try #require(
            Self.firstView(MonogramAvatarView.self, in: cell),
            "a text post's caption row has no author avatar"
        )
        #expect(Self.isDrawn(avatar), "the avatar exists but is not drawn on a text post")
    }

    /// Stated as the reader would state it: the two rows are the same shape.
    /// Same avatar at the same x, same bubble at the same x — the caption's
    /// text is all that differs.
    @Test func bothKindsPutTheirCaptionAtTheSamePlace() throws {
        let text = Self.row(hasMedia: false)
        let media = Self.row(hasMedia: true)

        let textBubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: text))
        let mediaBubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: media))
        #expect(abs(textBubble.convert(textBubble.bounds, to: text).minX
                    - mediaBubble.convert(mediaBubble.bounds, to: media).minX) < 0.5)

        let textAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: text))
        let mediaAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: media))
        #expect(abs(textAvatar.convert(textAvatar.bounds, to: text).minX
                    - mediaAvatar.convert(mediaAvatar.bounds, to: media).minX) < 0.5)
    }

    // MARK: - What the bubble's closing line says, and where

    /// ⚠️ THE DATE SITS AT THE LEADING EDGE.
    ///
    /// It used to be pinned trailing, in the message-bubble convention where a
    /// timestamp settles into the bottom-right corner. It reads better at the
    /// reading edge, under the caption it dates.
    @Test func theDateSitsAtTheLeadingEdgeOfTheBubble() throws {
        let cell = Self.row(hasMedia: true)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        let date = try #require(bubble.debugDateLabel)

        let frame = date.convert(date.bounds, to: bubble)
        #expect(abs(frame.minX - SnapPostInfoCardView.contentInset) < 0.5,
                "the date is not at the bubble's leading inset: \(frame)")
    }

    /// ⚠️ AND THE LIKE COUNT AT THE TRAILING ONE, on the same line.
    @Test func theLikeCountSitsAtTheTrailingEdgeOfTheSameLine() throws {
        let cell = Self.row(hasMedia: true)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        let date = try #require(bubble.debugDateLabel)
        let likes = try #require(bubble.debugLikeCounter)

        let likeFrame = likes.convert(likes.bounds, to: bubble)
        #expect(abs(likeFrame.maxX - (bubble.bounds.width - SnapPostInfoCardView.contentInset)) < 0.5,
                "the like count is not at the bubble's trailing inset: \(likeFrame)")

        let dateFrame = date.convert(date.bounds, to: bubble)
        #expect(abs(dateFrame.midY - likeFrame.midY) < 1,
                "the date and the like count are not on one line")
        #expect(dateFrame.maxX <= likeFrame.minX, "the two ends of the line overlap")
    }

    /// A text post's closing line reads the same way — the arrangement is the
    /// row's, not the format's.
    @Test func aTextPostsClosingLineReadsTheSameWay() throws {
        let cell = Self.row(hasMedia: false)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        let date = try #require(bubble.debugDateLabel)
        let likes = try #require(bubble.debugLikeCounter)

        let dateFrame = date.convert(date.bounds, to: bubble)
        let likeFrame = likes.convert(likes.bounds, to: bubble)
        #expect(abs(dateFrame.minX - SnapPostInfoCardView.contentInset) < 0.5)
        #expect(abs(likeFrame.maxX - (bubble.bounds.width - SnapPostInfoCardView.contentInset)) < 0.5)
    }

    /// ABSENT IS NOT ZERO — the grid's rule, kept: an opener that knew no
    /// counts leaves the counter off the line rather than asserting a nought.
    @Test func aRowWithNoKnownLikeCountShowsNoCounter() throws {
        let cell = Self.row(hasMedia: true, likes: nil)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))

        let likes = try #require(bubble.debugLikeCounter)
        #expect(Self.isDrawn(likes) == false, "a nil count was drawn as a counter")
        // …and the date is still there: one end of the line going quiet does
        // not take the other with it.
        let date = try #require(bubble.debugDateLabel)
        #expect(Self.isDrawn(date))
    }

    /// A zero that IS known reads as a zero. Same rule, other direction.
    @Test func aKnownZeroIsDrawnAsAZero() throws {
        let cell = Self.row(hasMedia: true, likes: 0)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        let likes = try #require(bubble.debugLikeCounter)

        #expect(Self.isDrawn(likes))
        #expect(Self.drawnLabels(in: likes).contains { $0.text == "0" })
    }

    // MARK: - What is actually drawn

    /// ⚠️ RENDERED, not asked.
    ///
    /// The row is drawn into a bitmap and the avatar's disc is sampled: a view
    /// that exists, reports itself visible, and paints nothing is exactly the
    /// failure this suite is for — every earlier version of this screen passed
    /// its state assertions while the page was wrong.
    @Test func theAvatarIsDrawnBesideATextPostsBubble() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 300))
        window.overrideUserInterfaceStyle = .light
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false

        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        host.view.addSubview(cell)
        cell.configure(
            with: Self.post(caption: "Shipping the new build tonight.", hasMedia: false),
            imagePipeline: nil,
            likeCount: 40
        )
        host.view.layoutIfNeeded()
        cell.layoutIfNeeded()

        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        let centre = avatar.convert(
            CGPoint(x: avatar.bounds.midX, y: avatar.bounds.midY), to: window
        )
        // A point well clear of the row, on the window's own ground.
        let empty = CGPoint(x: Self.width - 4, y: 290)

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let disc = try #require(Self.colour(of: image, at: centre))
        let ground = try #require(Self.colour(of: image, at: empty))

        #expect(disc != ground,
                "nothing is drawn where the avatar should be: \(disc) == \(ground)")
    }

    /// The instrument's own check: a point the row does NOT cover comes back
    /// as the ground. Without it, "the two differ" could as easily mean the
    /// sampler reads noise.
    @Test func theSamplerReadsTheGroundWhereNothingIsDrawn() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 300))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let a = try #require(Self.colour(of: image, at: CGPoint(x: 10, y: 10)))
        let b = try #require(Self.colour(of: image, at: CGPoint(x: Self.width - 4, y: 290)))

        #expect(a == b, "two empty points disagree — the sampler is not reading the screen")
    }

    private static func colour(of image: UIImage, at point: CGPoint) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = image.scale
        context.draw(cgImage, in: CGRect(
            x: -point.x * scale,
            y: -(image.size.height - point.y) * scale,
            width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        return pixel
    }
}
