import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **THE SPECIFICATION FOR THE CAPTION ROW: it is a comment.**
///
/// ## What it looked like before, and why it changed twice
///
/// First it wore two faces — a Liquid Glass bubble beside an avatar for a post
/// with a photograph, and the gallery card's flat content for a text post. That
/// split had a reason: a text page is opened by a reveal that grows the gallery
/// ROW into the page, so the row's caption and the page's first row were
/// deliberately the same object at the same inset. It was traded away for one
/// face, because a reader should meet one object whatever the post is made of.
///
/// This is the second half of that simplification, and it goes further than
/// unifying: the caption is not a special object at all any more. It is the
/// thread's first message, so it is shaped like every other message in it —
///
/// ```
///  ( )  Ava Moreau · 10 weeks                    ♥ 271
///       Weekend build log: rebuilt the pipeline
///       end to end…
/// ```
///
/// — the same avatar column, the same "Name · time" header, the same trailing
/// counter on that header line, the same body beneath. No bubble, no glass, no
/// second geometry to keep in step with the first.
///
/// ⚠️ These assert what a READER sees: which pieces are drawn, in what order,
/// and at which edge. They name no view class, so an implementation that
/// reuses the comment row and one that rebuilds its shape are equally
/// acceptable — what may not change is the shape.
@MainActor
struct PostCaptionFaceSpecTests {
    // MARK: - Fixtures

    private static let width: CGFloat = 402

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

    private static func row(
        caption: String = "Shipping the new build tonight.",
        hasMedia: Bool,
        likes: Int64? = 271
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

    /// A real comment, built the way the stream builds one — the thing the
    /// caption has to look like. Every comparison below is against THIS, not
    /// against a number written down here: a rule stated as "16pt" would pass
    /// while the two rows drifted apart.
    private static func comment() -> CommentRowView {
        let view = CommentRowView(model: CommentDisplayModel(
            entry: CommentEntry(
                id: "c1", authorID: ProfileID("p2"), authorName: "Kenji Tanaka",
                authorHandle: "kenji", body: "Love this shot",
                createdAt: Date(timeIntervalSince1970: 0), parentID: nil
            ),
            now: Date(timeIntervalSince1970: 20 * 60)
        ))
        view.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        view.layoutIfNeeded()
        return view
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

    private static func isDrawn(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        return true
    }

    /// Every label the reader reads, top to bottom.
    ///
    /// ⚠️ THE MONOGRAM IS NOT ONE. The avatar draws the author's initials in a
    /// label of its own, and it sits at the very top of the row — so an
    /// unfiltered "first label" is the disc's "AM", not the header. Two
    /// assertions failed against that before this filter existed, and both
    /// would have read as the row being built wrong.
    private static func readableLabels(in root: UIView) -> [UILabel] {
        allViews(UILabel.self, in: root)
            .filter { label in
                guard isDrawn(label), !(label.text ?? "").isEmpty else { return false }
                var node: UIView? = label
                while let current = node {
                    if current is MonogramAvatarView { return false }
                    node = current.superview
                }
                return true
            }
            .sorted { $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY }
    }

    /// An attributed title's TEXT. `String(describing:)` renders the attributes
    /// too ("271 {…}"), which is never what a comparison means.
    private static func titleText(of button: UIButton) -> String? {
        button.configuration?.attributedTitle.map { String($0.characters) }
    }

    // MARK: - The shape

    /// ⚠️ NO BUBBLE. The caption is not a card floating in the stream; it is a
    /// message in it.
    @Test func theCaptionIsNotInABubble() {
        for hasMedia in [true, false] {
            let cell = Self.row(hasMedia: hasMedia)
            let glass = Self.allViews(UIVisualEffectView.self, in: cell).filter { Self.isDrawn($0) }
            #expect(glass.isEmpty,
                    Comment(rawValue: "the caption still draws a material (hasMedia: \(hasMedia))"))
        }
    }

    /// The avatar stays, and it is the SAME column a comment uses — that
    /// alignment is the whole of "it reads as the thread's first message".
    @Test func theAvatarSitsInTheCommentsOwnColumn() throws {
        let cell = Self.row(hasMedia: true)
        let comment = Self.comment()

        let captionAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        let commentAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: comment))
        #expect(Self.isDrawn(captionAvatar))

        let captionFrame = captionAvatar.convert(captionAvatar.bounds, to: cell)
        let commentFrame = commentAvatar.convert(commentAvatar.bounds, to: comment)
        #expect(abs(captionFrame.minX - commentFrame.minX) < 0.5, "different avatar column")
        #expect(abs(captionFrame.width - commentFrame.width) < 0.5, "different avatar size")
    }

    /// ⚠️ NAME AND DATE ON ONE LINE, ABOVE THE CAPTION — the comment's header.
    @Test func theHeaderNamesTheAuthorAndTheDateAboveTheCaption() throws {
        let cell = Self.row(caption: "Shipping the new build tonight.", hasMedia: true)

        let labels = Self.readableLabels(in: cell)
        let header = try #require(labels.first)
        #expect(header.text?.contains("Ava Moreau") == true, "the author is not named: \(labels.map(\.text))")
        #expect(header.text?.contains("1h") == true || header.text?.contains("·") == true,
                "the date is not on the header line: \(header.text ?? "")")

        let body = try #require(labels.first { $0.text == "Shipping the new build tonight." })
        #expect(header.convert(header.bounds, to: cell).maxY
                <= body.convert(body.bounds, to: cell).minY + 0.5,
                "the caption is not below the header")
    }

    /// ⚠️ THE LIKE COUNT AT THE TRAILING EDGE OF THAT SAME LINE.
    @Test func theLikeCountClosesTheHeaderLine() throws {
        let cell = Self.row(hasMedia: true, likes: 271)

        let counter = try #require(Self.firstView(UIButton.self, in: cell))
        let counterFrame = counter.convert(counter.bounds, to: cell)
        let header = try #require(Self.readableLabels(in: cell).first)
        let headerFrame = header.convert(header.bounds, to: cell)

        #expect(counterFrame.maxX > cell.bounds.width * 0.7,
                "the count is not at the trailing edge: \(counterFrame)")
        #expect(abs(counterFrame.midY - headerFrame.midY) < 6,
                "the count is not on the header's line")
        #expect(Self.titleText(of: counter) == "271")
    }

    /// A count nobody stated is not a zero — the row shows the header alone.
    @Test func anUnknownCountIsNotDrawnAsAZero() throws {
        let cell = Self.row(hasMedia: true, likes: nil)

        let counter = try #require(Self.firstView(UIButton.self, in: cell))
        #expect(Self.titleText(of: counter) == nil)
    }

    /// And every kind of post wears it. The reader should not be able to tell
    /// which pipeline drew the row.
    @Test func aTextPostAndAMediaPostAreTheSameRow() throws {
        let text = Self.row(hasMedia: false)
        let media = Self.row(hasMedia: true)

        let textAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: text))
        let mediaAvatar = try #require(Self.firstView(MonogramAvatarView.self, in: media))
        #expect(abs(textAvatar.convert(textAvatar.bounds, to: text).minX
                    - mediaAvatar.convert(mediaAvatar.bounds, to: media).minX) < 0.5)

        let textBody = try #require(Self.readableLabels(in: text).last)
        let mediaBody = try #require(Self.readableLabels(in: media).last)
        #expect(abs(textBody.convert(textBody.bounds, to: text).minX
                    - mediaBody.convert(mediaBody.bounds, to: media).minX) < 0.5,
                "the two kinds start their caption at different insets")
    }

    /// ⚠️ AND IT LINES UP WITH THE COMMENTS UNDER IT. The caption's body and a
    /// comment's body start at the same x, because they are the same column.
    @Test func theCaptionsTextStartsWhereACommentsDoes() throws {
        let cell = Self.row(hasMedia: true)
        let comment = Self.comment()

        let captionBody = try #require(Self.readableLabels(in: cell).last)
        let commentBody = try #require(
            Self.allViews(UILabel.self, in: comment).first { $0.text == "Love this shot" }
        )
        #expect(abs(captionBody.convert(captionBody.bounds, to: cell).minX
                    - commentBody.convert(commentBody.bounds, to: comment).minX) < 0.5)
    }

    // MARK: - What it is NOT

    /// A caption is not a comment you can reply to, block, or report. It wears
    /// the shape; it does not inherit the affordances.
    @Test func theCaptionRowOffersNoCommentActions() {
        let cell = Self.row(hasMedia: true)

        let interactions = Self.allViews(UIView.self, in: cell)
            .flatMap(\.interactions)
            .filter { $0 is UIContextMenuInteraction }
        #expect(interactions.isEmpty, "the caption offers a comment's context menu")
    }

    /// Nor is its counter a control: the post's like lives on the toolbar, and
    /// two places to like one post is one too many.
    @Test func theCaptionsCountIsNotAButtonYouCanPress() throws {
        let cell = Self.row(hasMedia: true)

        let counter = try #require(Self.firstView(UIButton.self, in: cell))
        #expect(counter.isUserInteractionEnabled == false)
    }

    // MARK: - What is actually drawn

    /// ⚠️ RENDERED, not asked. A row that reports itself visible and paints
    /// nothing fails here and nowhere else.
    @Test func theRowIsDrawnWithItsAvatarAndItsText() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 300))
        window.overrideUserInterfaceStyle = .light
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: Self.width, height: 200))
        host.view.addSubview(cell)
        cell.configure(
            with: Self.post(caption: "Shipping the new build tonight.", hasMedia: false),
            imagePipeline: nil,
            likeCount: 271
        )
        host.view.layoutIfNeeded()

        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        let centre = avatar.convert(
            CGPoint(x: avatar.bounds.midX, y: avatar.bounds.midY), to: window
        )
        let empty = CGPoint(x: Self.width - 4, y: 290)

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let disc = try #require(Self.colour(of: image, at: centre))
        let ground = try #require(Self.colour(of: image, at: empty))

        #expect(disc != ground, "nothing is drawn where the avatar should be")
    }

    /// The instrument's own check: two points on the empty ground agree.
    @Test func theSamplerReadsTheGroundWhereNothingIsDrawn() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.width, height: 300))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
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
