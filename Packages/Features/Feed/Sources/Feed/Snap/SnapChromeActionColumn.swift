import DesignSystem
import MediaCore
import PostSurfaces
import ThreadKit
import UIKit

/// What the action column asks of the chrome (#2521): whether the page carries
/// media, the image pipeline its sound cover loads through, the wheel it
/// carries in its layer, the two stations it stands its bubbles on, and the
/// lift its glide drops by.
@MainActor
protocol SnapChromeActionColumnHost: UIView {
    var hasMedia: Bool { get }
    var imagePipeline: ImagePipeline? { get }
    var shortcutRail: SnapShortcutRailView { get }
    var boostStation: UIView { get }
    var soundStation: UIView { get }
    var currentColumnLineLift: CGFloat { get }
}

/// The page's action column, out of `SnapChromeView` (#2521): the like pill and
/// the sound bubble, their one glass (`SnapGlassColumn`) and the wheel's layer,
/// mounted above the chrome by the cell; the bubble's tap, hold and way back,
/// the like count, the column's ink and its glide with the comments (#2326).
/// The chrome keeps the stations and every constraint against them, and
/// builds this in its `init` (`buildLayout` reaches the like pill).
@MainActor
final class SnapChromeActionColumn {
    private unowned let host: any SnapChromeActionColumnHost

    // MARK: The action column (#695)
    //
    // ⚠️ ONE COLUMN FOR BOTH LAYOUTS. The like pill and the sound bubble are
    // the page's — and they stay on screen when the comments take the page,
    // where the composer used to draw a SECOND pill and slot on the same
    // frames and the two crossfaded (the owner, on a device: "it looks
    // replaced"). The composer now only reserves their room.
    //
    // So the two buttons live in `columnLayer`, which the owning cell mounts
    // ABOVE this chrome (`installActionColumn(in:)`): this view's engagement
    // fade, a single container alpha, never reaches them. They are framed by
    // two invisible STATIONS that keep every constraint the buttons had —
    // the caption, the band and the composer's reserved room all stop short
    // of the same places. A chrome nobody installs (the hero flight's
    // replica) keeps the layer inside itself, as before.

    /// The wheel's own layer in the column's, faded with the chrome through
    /// the comments' engagement — the fade it had as the chrome's child.
    let railLayer = SnapActionColumnLayer()
    /// The fixed boost affordance: a Liquid Glass circle filling the
    /// square where the rail overlaps the ticker band (diameter == the
    /// band's height), the zone's ONLY layer — the old frosted backdrop
    /// chip was removed in its favor. A chrome sibling ABOVE the rail
    /// (never a scroll subview), so it holds still while emotes scroll —
    /// and escapes the rail's edge-fade mask, which would otherwise
    /// dissolve it. The rail reserves its bottom strip
    /// (`bottomReservedInset`) so nothing settles behind it; the band's
    /// bubbles are born under this glass and slide out of its seam.
    /// Present on every MEDIA page and no text page — set from `configure`,
    /// never from the stream (see there for why the band's hidden state is
    /// the wrong authority for it).
    let boostButton = SnapRailBoostButton()
    /// The post's like count on the like button's corner (#668) — or, in the
    /// like pill (#669), under its heart.
    /// The post's like count — `configure`'s, then the live one
    /// (`setPostLikeCount`), the viewer's stake in it.
    private var postLikeCount: Int64?
    /// The SOUND bubble (#671), under the like pill on the field line, beside
    /// the caption and the page strip — see `SnapActionColumn`. Media chrome,
    /// like the pill (`applySoundVisibility`).
    let soundBubble = SnapSoundBubbleButton()
    /// (#1924, the owner): a TEXT page's like stands in the screen's footer —
    /// its heart and count beside save and repost — so the column floats no
    /// pill over the composer, and a short comment list rests on it. A media
    /// page keeps its pill; so does a screen with no footer.
    var likeInFooter = false {
        didSet {
            guard likeInFooter != oldValue else { return }
            applyLikePillVisibility()
        }
    }

    private func applyLikePillVisibility() {
        let hidden = likeInFooter && !host.hasMedia
        guard boostButton.isHidden != hidden else { return }
        boostButton.isHidden = hidden
        glassColumn.refresh(animated: false)
    }
    let columnLayer = SnapActionColumnLayer()
    /// The column's bubbles as ONE glass (#1872): the like and the sound
    /// fuse, split and fold into the sound — the
    /// buttons are its items, on their stations.
    let glassColumn = SnapGlassColumn()
    /// Where `columnLayer` is mounted: this chrome, or the cell's content.
    private weak var columnHost: UIView?
    /// What the sound bubble draws for the represented post — nil when the
    /// post has no sound bubble (the feed pushes it, `setSoundFace`).
    private var soundFace: SnapSoundFace?
    /// The sound bubble was tapped: open the sound sheet (#683).
    var onSoundSheetRequested: (() -> Void)?
    /// The sound bubble's way back was tapped (#1929): the stream goes back
    /// to its start.
    var onSoundReturnRequested: (() -> Void)?
    /// The bubble wears the post's Share (#1999) and was tapped.
    var onShareRequested: (() -> Void)?
    /// Whether the way back's hold arms Share (#1999): a media page's.
    private var holdArmsShare = false
    /// The way back's hold (#1929): the disc rises with the cover, and once
    /// full the sound sheet opens — the bubble's own tap action.
    private(set) var soundHold: HoldToArmPresenter?

    init(host: any SnapChromeActionColumnHost) {
        self.host = host
    }

    /// The column's glass, the wheel's layer and the bubble's tap and hold —
    /// the chrome's `installSoundBubble`, in its turn.
    func assemble() {
        // The buttons are the glass column's items (#1872): the column is
        // their one glass, standing them on their stations.
        boostButton.drawsGlass = false
        soundBubble.drawsGlass = false
        for (id, button) in [(ColumnItem.like, boostButton as UIView), (ColumnItem.sound, soundBubble)] {
            button.translatesAutoresizingMaskIntoConstraints = true
            glassColumn.register(button, for: id)
        }
        glassColumn.anchorID = ColumnItem.sound
        glassColumn.gap = SnapActionColumn.gap
        glassColumn.layout = { [weak self] in self?.columnSlots() ?? [] }
        glassColumn.frame = columnLayer.bounds
        glassColumn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        columnLayer.addSubview(glassColumn)
        // The wheel over the glass (#1872), its capsule in it.
        railLayer.frame = columnLayer.bounds
        railLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        railLayer.addSubview(host.shortcutRail)
        columnLayer.addSubview(railLayer)
        let capsule = host.shortcutRail.capsule
        capsule.likeHeight = SnapActionColumn.likePillHeight
        capsule.onLikeCover = { [weak self] cover in self?.glassColumn.setCover(ColumnItem.like, amount: cover) }
        capsule.onReturnShown = { [weak self] shown in self?.boostButton.setShowsReturn(shown) }
        boostButton.onReturn = { [weak capsule] in capsule?.returnToRest() }
        capsule.host = { [weak self] glass in self?.glassColumn.insertAccessory(glass) }
        mountColumn(in: host)
        soundBubble.onTap = { [weak self] in
            guard let self else { return }
            if soundBubble.showsReturn {
                onSoundReturnRequested?()
            } else if soundBubble.sharesPost {
                onShareRequested?()
            } else {
                onSoundSheetRequested?()
            }
        }
        // No hold of its own since #1931 (no in-app mute): only the way back
        // has one, arming the sheet (#1929).
        let hold = HoldToArmPresenter(view: soundBubble) { [weak self] in
            guard let self else { return .picture(nil) }
            return soundBubble.sharesPost ? .symbol(CommentsInputBar.shareRailSymbol) : .picture(soundBubble.coverImage)
        }
        // The hold arms the slot's own action (#1929): the sheet, or Share
        // on a media page's Share (#1999).
        hold.onFire = { [weak self] in
            guard let self else { return }
            if soundBubble.sharesPost { onShareRequested?() } else { onSoundSheetRequested?() }
        }
        hold.isEnabled = false
        soundHold = hold
    }

    /// The column item (the sound cover, the like) under `point`, if one
    /// takes touches there.
    func columnItemHit(at point: CGPoint, with event: UIEvent?) -> UIView? {
        for item in [soundBubble, boostButton] as [UIView] {
            guard !item.isHidden, item.alpha > 0.01, item.isUserInteractionEnabled, item.window != nil else { continue }
            let local = host.convert(point, to: item)
            guard item.point(inside: local, with: event), let hit = item.hitTest(local, with: event) else { continue }
            return hit
        }
        return nil
    }

    /// Scrolled away from the comments' start (#1929): the sound bubble
    /// offers the way back to the top, and its sheet moves to a hold — kept
    /// for VoiceOver as a custom action.
    func setSoundShowsReturn(_ shows: Bool, down: Bool = false, animated: Bool = true) {
        guard shows != soundBubble.showsReturn || down != soundBubble.returnPointsDown else { return }
        soundBubble.setShowsReturn(shows, down: down, animated: animated)
        applySoundHold()
    }

    /// The way back's hold, and VoiceOver's road to the sheet, as the
    /// bubble stands: only on the chevron, only for a sound the post plays.
    private func applySoundHold() {
        let returns = soundBubble.showsReturn
        // Over Share (#1999) the hold arms Share on a media page — "a hold
        // arms its own action" — and nothing on a text page.
        let armsSheet = returns && !soundBubble.sharesPost && soundFace?.isAvailable == true
        let armsShare = returns && soundBubble.sharesPost && holdArmsShare
        soundHold?.isEnabled = armsSheet || armsShare
        if armsSheet {
            soundBubble.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Sound") { [weak self] _ in
                    self?.onSoundSheetRequested?()
                    return true
                },
            ]
        } else if returns, soundBubble.sharesPost {
            // Share stays reachable with the chevron up: VoiceOver's road.
            soundBubble.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Share") { [weak self] _ in
                    self?.onShareRequested?()
                    return true
                },
            ]
        } else {
            soundBubble.accessibilityCustomActions = nil
        }
    }

    /// The bubble as the post's Share (#1999) on a pushed page: a text
    /// page's column is Share alone on the sound's frame, a media page's
    /// ends on Share where the sound was (the sound moves to the footer).
    /// `holdArmsShare`: the way back's hold arms Share — a media page's.
    func setSlotSharesPost(_ shares: Bool, holdArmsShare: Bool = false) {
        self.holdArmsShare = shares && holdArmsShare
        soundBubble.setSharesPost(shares)
        applySoundHold()
        applySoundVisibility()
    }

    /// The sound bubble: shown for a post with a face — every media post has
    /// one, greyed when it has no sound — or wearing a pushed text page's
    /// Share (#1999), on the same frame.
    func applySoundVisibility() {
        soundBubble.isHidden = soundFace == nil && !soundBubble.sharesPost
        // The glass column stands what shows (#1872).
        host.setNeedsLayout()
    }

    /// The sound bubble's face for the represented post (#671): its cover, the
    /// mute state, greyed for a post with no audio; nil for none.
    func setSoundFace(_ face: SnapSoundFace?) {
        soundFace = face
        soundBubble.setFace(face, pipeline: host.imagePipeline)
        applySoundHold()
        applySoundVisibility()
    }

    /// Turns the sound bubble's cover while the post plays.
    func setSoundSpinning(_ spinning: Bool) {
        soundBubble.setSpinning(spinning)
    }

    // MARK: - The column's glide with the comments (#2326)

    /// How far the comments' opening has gone, as the in-page engagement
    /// tells it (`setCommentsEngagedProgress`): 0 at rest, 1 engaged.
    var engagementColumnShare: CGFloat = 0
    /// How far the comments sheet has taken the page's interface
    /// (`setCommentsSheetShare`): 0 at rest, 1 the sheet up.
    var sheetColumnShare: CGFloat = 0

    /// ⚠️ THE COLUMN GLIDES WITH THE COMMENTS, ON THEIR CLOCK (#2326). Its
    /// two positions:
    /// - AT REST, on the caption's line: the stations' constraints, risen by
    ///   `columnLineLift` (`applyColumnSeat`);
    /// - ENGAGED, on the composer's line (`inputRestingGap`), where the
    ///   engaged composer's stake and rail stand on the like pill and the
    ///   sound bubble (#669, #680): the same stations, shown that lift lower.
    ///
    /// Between them, the drop is the lift times how far the comments'
    /// transition has gone — the in-page engagement's progress or the sheet's
    /// share of the interface, whichever is further — so the column follows
    /// the finger, the spring and the sheet's own movement with no clock of
    /// its own: a drag that cancels takes it back with the finger.
    ///
    /// A translation of the column's glass and of the wheel's layer: the
    /// stations — and every constraint the caption, the band and the strip
    /// keep against them — stay at rest, nothing is laid out again on a
    /// frame of the transition, and the glass column's own morph is left
    /// alone. Inside an animation block (the engagement's spring), the
    /// translation animates on that block's curve.
    func applyColumnGlide() {
        let share = min(max(0, max(engagementColumnShare, sheetColumnShare)), 1)
        let drop = host.currentColumnLineLift * share
        let shift: CGAffineTransform = drop == 0 ? .identity : CGAffineTransform(translationX: 0, y: drop)
        guard glassColumn.transform != shift || railLayer.transform != shift else { return }
        glassColumn.transform = shift
        railLayer.transform = shift
        // The wheel's capsule is glass of the column's container: placed
        // again against the wheel, both moved alike.
        host.shortcutRail.capsule.layout()
    }

    /// How far the comments SHEET has taken the page's interface (#2087,
    /// #2326): 0 at rest, 1 the sheet up — the pose's `interface`, read
    /// every frame from the sheet's own movement. The column glides down to
    /// the composer's line with it, and back up as it comes back.
    func setCommentsSheetShare(_ share: CGFloat) {
        let clamped = min(max(0, share), 1)
        guard clamped != sheetColumnShare else { return }
        sheetColumnShare = clamped
        applyColumnGlide()
    }

    /// Mounts the column ABOVE this chrome in `host` (the cell's content
    /// view), so the engagement fade leaves it on screen. The buttons stay on
    /// their stations: same frames, by construction.
    func installActionColumn(in host: UIView) {
        mountColumn(in: host)
    }

    private func mountColumn(in host: UIView) {
        columnHost = host
        columnLayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(columnLayer)
        let constraints = [
            columnLayer.leadingAnchor.constraint(equalTo: self.host.leadingAnchor),
            columnLayer.trailingAnchor.constraint(equalTo: self.host.trailingAnchor),
            columnLayer.topAnchor.constraint(equalTo: self.host.topAnchor),
            columnLayer.bottomAnchor.constraint(equalTo: self.host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
    }

    /// The glass column's items (#1872).
    enum ColumnItem {
        static let like = "like"
        static let sound = "sound"
    }

    /// Where the column's items stand: on their stations, each a bubble of
    /// its own.
    func columnSlots() -> [[SnapGlassColumn.Slot]] {
        func slot(_ id: String, _ item: UIView, _ station: UIView) -> SnapGlassColumn.Slot? {
            guard !item.isHidden, station.bounds.width > 0 else { return nil }
            // Into the column's layer, which the glass fills: the glass's own
            // glide (#2326) is not undone by the conversion.
            return SnapGlassColumn.Slot(id: id, frame: station.convert(station.bounds, to: columnLayer))
        }
        let sound = slot(ColumnItem.sound, soundBubble, host.soundStation)
        return [
            slot(ColumnItem.like, boostButton, host.boostStation),
            sound,
        ].compactMap { $0.map { [$0] } }
    }

    /// Shows or hides the column — the like (boost) pill and the sound
    /// bubble — for a post the viewer may still act on (#1409). Its own
    /// switch, not the flight's hold (`setColumnHeld`, an alpha): a post
    /// that turned unavailable keeps it down whatever the flight does.
    func setActionColumnShown(_ shown: Bool) {
        columnLayer.isHidden = !shown
    }

    /// Hides the column with the page while a flight covers it — the
    /// replica carries its own. Unlike the chrome's own hold, released into
    /// the engaged state too: the column belongs to both.
    func setColumnHeld(_ held: Bool) {
        columnLayer.alpha = held ? 0 : 1
    }

    /// The column's ink: dark glass and white ink on a media page — in
    /// BOTH layouts, the comments' included (the owner, on a device: the
    /// column stays dark) — and a text page's own theme.
    func applyColumnStyle() {
        let style: UIUserInterfaceStyle = host.hasMedia ? .dark : .unspecified
        columnLayer.overrideUserInterfaceStyle = style
        // ⚠️ AND ON EACH ITEM (#1872): a glass's content takes the ink the
        // glass picks over what is behind it, and the column's ink is the
        // page's choice — white over media, whatever the picture.
        for item in [boostButton as UIView, soundBubble] {
            item.overrideUserInterfaceStyle = style
        }
    }

    /// The column for the post the chrome configures (`SnapChromeView.configure`).
    func configure(with model: FeedItemDisplayModel) {
        // THE BOOST ANCHOR IS FORMAT-SCOPED, NOT STATE-SCOPED — the rule the
        // compose "+" that held this slot established. Every media page owns
        // it from its first frame; its predecessor used to mirror the
        // ticker's hidden state (`updateCommentStreams`), which meant it
        // vanished on every page the band declined to animate: zero-comment
        // posts, the sparse seed, and any page at all under Reduce Motion —
        // the anchor disappearing where it was most useful.
        //
        // Text-only pages keep it hidden. Their engagement is a permanent
        // resting state with its own composer bar, and that bar carries its
        // OWN boost button — so the anchor here would be a second spend
        // control for one post; setting it here rather than leaving the
        // engagement's fade to swallow it also kills the flash it used to
        // make in the frames before that engagement mounts.
        //
        // Owned by `configure` (static chrome, like the rail's emotes), so
        // it needs no stream to appear and the flight replica — which never
        // receives one — draws the identical corner.
        // ⚠️ THE LIKE PILL IS ALWAYS THERE (#1713, the owner): no post hides
        // its likes. On every page (#695) — but a text page's stands in the
        // screen's footer when it has one (#1924, `likeInFooter`).
        boostButton.isHidden = likeInFooter && !host.hasMedia
        // The badge's count, from what the card knew; the screen then pushes
        // the post's live one (`setPostLikeCount`).
        postLikeCount = model.likeCount
        applyLikeBadge(animated: false)
        applySoundVisibility()
    }

    /// The column for the next post (`SnapChromeView.reset`, cell reuse).
    func reset() {
        boostButton.isHidden = true
        boostButton.setSpentTotal(0)
        postLikeCount = nil
        applyLikeBadge(animated: false)
        soundFace = nil
        setSoundShowsReturn(false, animated: false)
        soundBubble.setFace(nil, pipeline: nil)
        soundBubble.setSharesPost(false)
        soundBubble.isHidden = true
        // Back to the unwired default (enabled, nothing undoable) — the
        // next configure pushes the real context.
        boostButton.setWalletContext(balance: .max, undoableAmount: 0)
    }

    /// The viewer's cumulative spend on the represented post — turns the like
    /// heart red (#668); the count moves through the store
    /// (`setPostLikeCount`). Owned by the cell's configurator (the chrome has
    /// no wallet); reset to 0 with the rest of the post state on reuse.
    /// `animated` is kept for the callers' stake and undo theatre.
    func setBoostTotal(_ total: Int, animated: Bool = false) {
        boostButton.setSpentTotal(total)
        applyLikeBadge(animated: animated)
    }

    /// The post's live like count (#896) — the app's `EntityStore`, where
    /// the viewer's stakes already are (`WalletStakeLikes`).
    func setPostLikeCount(_ count: Int64?) {
        guard count != postLikeCount else { return }
        postLikeCount = count
        applyLikeBadge(animated: false)
    }



    /// The badge's count: the post's, the viewer's stake included (product
    /// decision 2026-10-08) — and included ONCE, by the store the count
    /// comes from (`WalletStakeLikes`, #896). Adding the stake here counted a
    /// committed stake twice (the server's count already holds it), and the
    /// card the post opened from showed another number.
    private func applyLikeBadge(animated: Bool) {
        // Drawn by the pill itself, under its heart (#692).
        boostButton.setLikeCount(postLikeCount)
    }

    /// The anchor's wallet context: what the balance can still afford and
    /// how much of this post's spend is session-undoable — the enable state
    /// and the menu's live contents both derive from it.
    func setBoostContext(balance: Int, undoable: Int, stakeShots: Int = 0) {
        boostButton.setWalletContext(balance: balance, undoableAmount: undoable, stakeShots: stakeShots)
    }
}
