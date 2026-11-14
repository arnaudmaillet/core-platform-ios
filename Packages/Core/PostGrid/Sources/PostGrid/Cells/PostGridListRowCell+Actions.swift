import CoreModels
import CoreStorage
import DesignSystem
import EmoteKit
import MediaCore
import MediaPlayback
import UIKit
import VoiceKitUI

// The author band, the row's actions, the stake and the counts
extension PostGridListRowCell {
    /// Fired when the viewer taps the band's identity. The HOST navigates —
    /// a cell cannot reach a navigation controller and should not try.
    public var onAuthorTapped: (() -> Void)? {
        get { authorBand.onAuthorTapped }
        set { authorBand.onAuthorTapped = newValue }
    }

    /// Fired when the viewer HOLDS the band's identity (#2145, role 1): the
    /// profile, pushed. Nil: no hold.
    public var onAuthorHeld: (() -> Void)? {
        get { authorBand.onAuthorHeld }
        set { authorBand.onAuthorHeld = newValue }
    }

    /// Fired when the band's face shows the "+" and it is tapped (#2300):
    /// the HOST follows — the cell cannot see the follow.
    public var onAuthorFollowTapped: (() -> Void)? {
        get { authorBand.onFollowTapped }
        set { authorBand.onFollowTapped = newValue }
    }

    /// Whether a long press at `point` (in the cell) is the band's author's
    /// hold (#2145): the card's lift leaves it to the profile.
    public func holdIsAuthors(at point: CGPoint) -> Bool {
        authorBand.takesHold(at: convert(point, to: authorBand))
    }

    /// The relation mark the band's face wears (#2300).
    public var authorRelationMark: PersonPill.Badge { authorBand.relationMark }

    /// Draws the author's relation mark on the band's face (#2300): what the
    /// host's binding answers for the post's author. A bare band draws none.
    public func setAuthorRelationMark(_ mark: PersonPill.Badge, animated: Bool) {
        authorBand.setRelationMark(mark, animated: animated)
    }

    /// The rows the band's "..." offers, asked for when it is pressed. Nil
    /// hides the control — see `PostAuthorBandView.menuActions`.
    public var authorMenuActions: (() -> [PostCardMenuAction])? {
        get { authorBand.menuActions }
        set { authorBand.menuActions = newValue }
    }

    /// What a popover-shaped sheet raised from the menu should point at.
    public var authorMenuAnchor: UIView { authorBand.menuAnchor }

    /// Asks `authorMenuActions` again whether the "..." has rows: the
    /// provider's answer can change after the row was configured.
    public func refreshAuthorMenu() {
        authorBand.refreshMenuVisibility()
    }

    #if DEBUG
    /// Whether the band's "..." is drawn.
    public var debugShowsAuthorMenu: Bool { authorBand.debugShowsMenu }
    /// The band face's badge (#2300). Tests.
    public var debugAuthorBadge: RelationBadgeView { authorBand.debugBadge }
    /// A tap on the band's identity, as a finger's would land (#2145). Tests.
    public func debugTapAuthor() { authorBand.debugOpening.debugTap() }
    /// A hold on the band's identity, recognised. Tests.
    public func debugHoldAuthor() { authorBand.debugOpening.debugHold() }
    #endif

    /// What the VIEWER has staked on this post: the heart turns the points'
    /// red once there is any.
    ///
    /// ⚠️ **THE COUNT STAYS THE POST'S.** Adding the viewer's stake to it was
    /// the first version, and it put two numbers on one post: the card said
    /// 301 while the post page it opens — and the flight card between them —
    /// said 271, because the feed shows the viewer's stake on its own anchor
    /// (the rail's red count) rather than inside the likes. The card follows
    /// the feed instead: the receipt is the red heart and a "+N" rising off
    /// the chip, the rail's own receipt.
    ///
    /// Since #896 the post's count is the app's live one, where the stake is
    /// counted once (`PostCardStaking`, `WalletStakeLikes`): the card, its
    /// flight card, the post page and the feed draw one number.
    public func setViewerStake(_ total: Int) {
        guard total != viewerStake else { return }
        viewerStake = total
        applyReactionCount(animated: true)
    }

    /// The stake landed: "+N" rises off the chip in the points' red and the
    /// heart pops — the rail's confirmation, on a card.
    public func playStakeConfirmation(amount: Int) {
        floatReceipt("+\(amount)", color: LikesSymbol.tint, rising: true)
        StakeReceipt.pop(likesAction.imageView ?? likesAction)
    }

    /// An undo's receipt: "−N" sinking, in grey — an undo is not a payout.
    public func playStakeRefund(amount: Int) {
        floatReceipt("−\(amount)", color: .secondaryLabel, rising: false)
    }

    /// A number floating off the like chip, then dissolving. Drawn in the
    /// cell's content view rather than in the chip, which clips to its
    /// capsule. Pure theatre over state the wallet already changed, so it can
    /// be dropped (hidden chip, mid-reuse) without anything going wrong.
    private func floatReceipt(_ text: String, color: UIColor, rising: Bool) {
        guard !likesAction.isHidden, likesAction.window != nil else { return }
        StakeReceipt.float(text, color: color, rising: rising, from: likesAction, in: contentView)
    }

    /// The wallet refused (balance, or the post's cap): the chip shakes its
    /// head. Additive, so it composes with the press still springing back.
    public func playStakeDenied() {
        StakeReceipt.shake(likesAction)
    }


    public var postLikeCount: Int64? { configuredReactionCount }

    public func showLikeCount(_ count: Int64) {
        guard baseReactionCount != nil, baseReactionCount != count else { return }
        baseReactionCount = count
        applyReactionCount(animated: true)
    }

    #if DEBUG
    /// The like count the card draws — nil while it draws none.
    public var debugReactionCount: Int64? { baseReactionCount }
    #endif

    func applyStakeWiring() {
        let stakes = onStake != nil
        likesKeepsGlyph = stakes
        // A counter until the host stakes through it: with no stake the
        // touch is the card's, and opens the post.
        likesAction.isUserInteractionEnabled = stakes
        likesAction.holdFreezesScrolling = stakes
        likesAction.accessibilityLabel = stakes ? "Like, stakes \(StakeMenu.likes(stakeTapAmount))" : "Likes"
        applyReactionCount(animated: false)
        // A count-less post's heart may have just appeared at the line's end,
        // and the end hangs by what is there.
        syncClosingLine()
    }

    /// The post's own count, and the heart inked by whether the viewer has a
    /// stake on it.
    /// Takes `post`'s counters and nothing else — for a refresh whose only
    /// news is a number. A `configure` (or a collection view's reconfigure)
    /// re-dresses the whole card, media included, and re-measures it; a count
    /// is a capsule's text.
    public func updateCounts(from post: GalleryPost) {
        baseReactionCount = post.reactionCount
        applyReactionCount(animated: true)
        applyCommentCount(showsShowcase ? nil : post.commentCount, animated: true)
    }

    /// The likes: the post's count, and the heart turned to the points' red
    /// glyph once the viewer has a stake — a symbol replace and the state
    /// tint, the count rolling (#934). Animated only for news on the post the
    /// row is already showing, never for a row bound to a new one.
    func applyReactionCount(animated: Bool) {
        let staked = viewerStake > 0
        let content = AppIconButton.Content(
            symbol: staked ? LikesSymbol.glyph : ActionSymbol.like,
            count: baseReactionCount.map { Int(clamping: $0) }
        )
        let animates = animated && actionsAnimate && likesAction.window != nil && !likesAction.isHidden
        likesAction.setContent(content, animated: animates)
        likesAction.setSelected(staked, animated: animates)
        likesAction.isHidden = baseReactionCount == nil && !likesKeepsGlyph
    }

    /// The comment count, the same way; none hides the action.
    func applyCommentCount(_ count: Int64?, animated: Bool) {
        let animates = animated && actionsAnimate && commentsAction.window != nil && !commentsAction.isHidden
        commentsAction.setContent(
            .init(symbol: ActionSymbol.comments, count: count.map { Int(clamping: $0) }), animated: animates
        )
        commentsAction.isHidden = count == nil
    }


    func applyBookmarkGlyph() {
        let animates = actionsAnimate && bookmarkAction.window != nil && !bookmarkAction.isHidden
        bookmarkAction.setContent(.symbol(isBookmarked ? ActionSymbol.saved : ActionSymbol.save), animated: animates)
        bookmarkAction.setSelected(isBookmarked, animated: animates)
        bookmarkAction.accessibilityLabel = isBookmarked ? "Saved" : "Save"
    }

    /// Draws the band's "..." without wiring it — for a transition's stand-in
    /// card, which must look like the row it stands in for. See
    /// `PostAuthorBandView.showMenuControlAsScenery`.
    public func showAuthorMenuControlAsScenery() {
        authorBand.showMenuControlAsScenery()
    }

    /// Draws the band's repost and save controls without wiring them, for the
    /// same reason and with the same care as the "..." above: a stand-in must
    /// show what the ROW shows, and both ways of being wrong end the transition
    /// with a control appearing or disappearing in the last frame.
    ///
    /// The capability existed on the band and nothing in the app called it, so
    /// every text dismissal flew a card whose header was missing its trailing
    /// pill — the one visible difference between the window and the row it
    /// lands on.
    public func showRowActionsAsScenery(repost: Bool, bookmark: Bool, saved: Bool) {
        repostAction.isHidden = !repost
        bookmarkAction.isHidden = !bookmark
        isBookmarked = saved
        syncClosingLine()
    }

    /// Draws the like as a STAKING row draws it, without wiring it: the heart
    /// kept when the post has no count yet, and red when the viewer has
    /// staked. For a stand-in, on the same terms as `showRowActionsAsScenery`
    /// — the landing frame swaps the stand-in for the row, and a heart
    /// changing colour in it is the pop.
    public func showStakeAsScenery(viewerStake: Int) {
        likesKeepsGlyph = true
        setViewerStake(viewerStake)
        applyReactionCount(animated: false)
        syncClosingLine()
    }

    /// What the row's date is CURRENTLY reading, so a stand-in can show the
    /// same string rather than working one out for itself.
    ///
    /// ⚠️ THE ROW'S ANSWER, NOT THE TRUTH. A compact age is a function of the
    /// clock, and the row computed its own when it was configured — minutes
    /// ago, on a post the viewer has been reading. A stand-in that recomputed
    /// it flew "2m" home onto a row that still says "now", which is a word
    /// changing at the end of a transition whose whole purpose is that nothing
    /// changes. Whichever is stale, they must agree.
    public var renderedAgeText: String? { authorBand.model?.age }

    /// The band this row is drawing — the date included — so a reveal's prop
    /// can be configured from the row's own reading rather than from a second
    /// look at the post.
    public var authorBandModel: PostAuthorBandView.Model? {
        // A collapsed band draws nothing, and a prop copying it would draw a
        // "..." over a card that has none — see `PostAuthorBandView.isCollapsed`.
        authorBand.isCollapsed ? nil : authorBand.model
    }

    /// What the row's closing line is actually drawing, so a test can compare
    /// a stand-in against a row rather than against a literal.
    public var visibleRowActions: (repost: Bool, bookmark: Bool, saved: Bool) {
        (!repostAction.isHidden, !bookmarkAction.isHidden, isBookmarked)
    }
}
