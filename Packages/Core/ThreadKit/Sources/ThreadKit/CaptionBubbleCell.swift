import CoreModels
import DesignSystem
import MediaCore
import MediaUI
import PostGrid
import UIKit
import VoiceKitUI

/// The comment list's FIRST ROW: the post itself, drawn as the thread's first
/// message.
///
/// ```
///  ( )  Ava Moreau · 10 weeks                    ♥ 271
///       Weekend build log: rebuilt the pipeline…
///  ( )  Kenji Tanaka · 20m                       ♥ 3
///       Love this shot 🔥
/// ```
///
/// ⚠️ IT IS A `CommentRowView`, not something shaped like one. The caption has
/// been three things now — a Liquid Glass bubble beside an avatar, the gallery
/// card's flat content for text posts, and a bubble again with its own closing
/// line — and each of them existed to line up with the rows beneath it: same
/// avatar column, same header, same body inset, kept in step by hand. Sharing
/// the row deletes that whole class of drift, and it is also the design: the
/// post is the first message in its own thread, so it looks like one.
///
/// What it does not share is a comment's affordances — see
/// `CommentRowView.configureAsPostCaption`.
public final class CaptionBubbleCell: UICollectionViewCell {
    /// The post's author's face wears the relation mark (#2300).
    private let row = CommentRowView(marksAuthor: true)
    /// A voice post's caption (#2207): the shared voice component, full size,
    /// under the author line — the caption's words under it. The neutral
    /// panel takes the text column's whole width (#2241): the post's page
    /// is the content width's, uncapped, unlike a conversation's message.
    private lazy var voiceView: VoiceView = {
        let view = VoiceView(size: .full)
        return view
    }()
    /// The voice shown, and the id it plays under.
    public private(set) var shownVoiceID: String?
    /// The app's one voice hub; tests put their own in.
    public static var playbackHub: VoicePlaybackHub = .shared
    private var hub: VoicePlaybackHub { Self.playbackHub }
    /// A channel showcase's caption (#2216): the author's words, then the
    /// shared embed card, full size, its action live. Built when first shown.
    private lazy var embedView = PostEmbedView()
    /// The embed shown, if any.
    public private(set) var shownEmbed: PostEmbed?

    /// The avatar was tapped — the host pushes the author's profile, or,
    /// where the screen binds the face (a text page in the feed, #2300), opens
    /// the profile card: a person beside content (#2145).
    public var onAvatarTap: (() -> Void)? {
        get { row.onAvatarTap }
        set { row.onAvatarTap = newValue }
    }

    /// The avatar was held (#2145, role 1): the profile, pushed. Nil: no hold.
    public var onAvatarHold: (() -> Void)? {
        get { row.onAvatarHold }
        set { row.onAvatarHold = newValue }
    }

    /// The relation mark the author's face wears now.
    public var authorMark: PersonPill.Badge { row.authorMark }

    /// Wears `mark` on the author's face — the screen's binding's answer.
    public func setAuthorMark(_ mark: PersonPill.Badge, animated: Bool) {
        row.setAuthorMark(mark, animated: animated)
    }

    /// The author's Follow on the name line, left of the ♥ count (#2419):
    /// what it draws now.
    public var authorFollowOffer: AuthorFollowOffer { row.authorFollowOffer }

    /// Draws `offer` beside the name — the screen's binding's answer, from
    /// the same answer as the face's mark.
    public func setAuthorFollowOffer(_ offer: AuthorFollowOffer, animated: Bool) {
        row.setAuthorFollowOffer(offer, animated: animated)
    }

    /// Follow or Follow back tapped: the host follows.
    public var onAuthorFollowTapped: (() -> Void)? {
        get { row.onAuthorFollowTapped }
        set { row.onAuthorFollowTapped = newValue }
    }

    /// Requested's "Cancel Request" chosen: the host withdraws the request.
    public var onAuthorCancelFollowRequest: (() -> Void)? {
        get { row.onAuthorCancelFollowRequest }
        set { row.onAuthorCancelFollowRequest = newValue }
    }

    #if DEBUG
    /// The author face's badge. Tests.
    public var debugAuthorBadge: RelationBadgeView? { row.debugAuthorBadge }
    /// The author's Follow on the name line. Tests.
    public var debugAuthorFollowButton: AuthorFollowButton? { row.debugAuthorFollowButton }
    /// The name line (`Name · time`). Tests.
    public var debugHeaderLabel: UILabel { row.headerTextLabel }
    /// The caption's words. Tests.
    public var debugBodyLabel: UILabel { row.bodyTextLabel }
    /// A tap on the author's face, as a finger's would land. Tests.
    public func debugTapAuthor() { row.debugCaptionOpening?.debugTap() }
    /// A hold on the author's face, recognised. Tests.
    public func debugHoldAuthor() { row.debugCaptionOpening?.debugHold() }
    #endif

    public override init(frame: CGRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // The inter-row breathing every other stream row uses.
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.lg),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func prepareForReuse() {
        super.prepareForReuse()
        showVoice(nil, postID: nil, authorName: "")
        showEmbed(nil, imagePipeline: nil)
        row.prepareForReuse()
    }

    /// The caption's voice, or none (#2207).
    private func showVoice(_ voice: PostVoice?, postID: PostID?, authorName: String) {
        guard let voice, let postID else {
            if shownVoiceID != nil { hub.unbind(voiceView) }
            shownVoiceID = nil
            row.setBodyAccessory(nil)
            return
        }
        let id = VoicePosts.playbackID(postID)
        shownVoiceID = id
        voiceView.role = .post(author: authorName.isEmpty ? nil : authorName)
        hub.bind(voiceView, id: id, url: voice.url, duration: voice.duration,
                 levels: voice.waveform.isEmpty ? nil : voice.waveform)
        row.setBodyAccessory(voiceView)
    }

    /// The caption's card, or none (#2216): under the author's words.
    private func showEmbed(_ embed: PostEmbed?, imagePipeline: ImagePipeline?) {
        guard let embed else {
            if shownEmbed != nil { embedView.clear() }
            shownEmbed = nil
            row.setBodyFooter(nil)
            return
        }
        shownEmbed = embed
        embedView.show(embed, size: .full, pipeline: imagePipeline)
        row.setBodyFooter(embedView)
    }

    /// The page stopped owning the screen — the row left the window: its
    /// voice stops where it is, and keeps its place (#2207).
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, let shownVoiceID { hub.stop(shownVoiceID) }
    }

    #if DEBUG
    public var debugVoiceView: VoiceView? { shownVoiceID == nil ? nil : voiceView }
    public var debugEmbedView: PostEmbedView? { shownEmbed == nil ? nil : embedView }
    public var debugShowsBody: Bool { !row.bodyTextLabel.isHidden }
    #endif

    /// Measures this row at the width the layout is actually going to give it,
    /// rather than at whatever width the cell happens to be carrying.
    ///
    /// THE RACE THIS CLOSES. A self-sizing cell is asked its height once, and
    /// on the feed's resting engagement it is asked early — the comments are
    /// installed into a feed cell from `willDisplay`, while the page is still
    /// arriving, so the container's width is not final. Measured against a
    /// too-wide box the caption is one line, and one line is the height the
    /// layout keeps: the row never grows back, and the label — which HAS the
    /// full string — renders as much of it as fits and clips the rest. That is
    /// the "clipped to one line, end of the text missing" report, and it
    /// reproduced about one launch in three.
    ///
    /// So the width comes from the ATTRIBUTES, which are authoritative, and the
    /// layout is forced through synchronously before measuring, so nothing
    /// downstream can hand back a cached one-line height.
    public override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        fittedAtLayoutWidth(layoutAttributes) ?? super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    /// Renders from what the FEED already knows, before this screen's own post
    /// fetch returns — enough for the row to exist, occupy its real height, and
    /// be somewhere a flight can aim at.
    ///
    /// The author travels too, and it has to: the row names its author, and a
    /// seeded row that showed an empty disc and no name until the fetch
    /// returned would be a hole in the object the reveal is carrying the eye
    /// to. The feed knows the name and the picture already.
    public func configureSeed(
        caption: String, timestamp: String, authorName: String, monogram: String,
        avatarURL: URL?, likeCount: Int64?, imagePipeline: ImagePipeline?,
        voice: PostVoice? = nil, postID: PostID? = nil, embed: PostEmbed? = nil
    ) {
        showVoice(voice, postID: postID, authorName: authorName)
        showEmbed(embed, imagePipeline: imagePipeline)
        row.configureAsPostCaption(
            authorName: authorName, timestamp: timestamp, caption: caption,
            monogram: monogram, avatarURL: avatarURL, likeCount: likeCount,
            imagePipeline: imagePipeline
        )
    }

    /// `likeCount` comes from the HOST, deliberately, and is not derived here.
    ///
    /// A `PostDetailDisplayModel` carries no engagement at all — the screen
    /// tracks it separately, because it moves: the viewer can like the post
    /// from the toolbar while this row is on screen. The host passes whichever
    /// number is currently true (the live one once the post has landed, the
    /// opener's until then), and `nil` when nobody has said.
    public func configure(
        with model: PostDetailDisplayModel,
        imagePipeline: ImagePipeline?,
        likeCount: Int64? = nil
    ) {
        showVoice(model.voice, postID: model.postID, authorName: model.authorName)
        showEmbed(model.embed, imagePipeline: imagePipeline)
        row.configureAsPostCaption(
            authorName: model.authorName, timestamp: model.timestampText,
            caption: model.caption, monogram: model.avatarMonogram,
            avatarURL: model.avatarURL, likeCount: likeCount,
            imagePipeline: imagePipeline
        )
    }
}
