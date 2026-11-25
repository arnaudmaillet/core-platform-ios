import DesignSystem
import ThreadKit
import UIKit

/// What the composer's rail slot asks of its panel (#2523): the composer,
/// whether the post is a draft, the stream on screen (its way back) and
/// the scroll to its start.
@MainActor
protocol PostDetailRailSlotHost: AnyObject {
    var composeBar: CommentsInputBar { get }
    var viewModel: PostDetailViewModel { get }
    var stream: CommentStream { get }
    /// A text page's way back, above the own bubble (#2488).
    var wayBackBubble: PostDetailWayBackBubble { get }
    func scrollToStart(animated: Bool)
}

/// The composer's rail slot, out of `PostDetailViewController` (#2523): the
/// face it wears — Share (#1999), the sound (#671), the way back (#1929) —
/// its tap, its hold and their VoiceOver roads, and the record's turn.
///
/// ⚠️ THE ONLY WRITER OF `composeBar.railFace`: the panel asks it for the
/// opening face (`applyOpeningFace`) and the published one
/// (`applyPublishedFace`), and writes none itself.
@MainActor
final class PostDetailRailSlot {
    private unowned let host: any PostDetailRailSlotHost

    init(host: any PostDetailRailSlotHost) {
        self.host = host
    }

    /// What a published post's rail slot wears: Share on a pushed text page
    /// (`setRailShare`, #1999), else the sound's cover the snap feed hands
    /// over (`setRailSoundFace`, #671) — nothing for a post with neither.
    private var publishedRailFace: CommentsInputBar.RailFace {
        guard railKeepsSlot else { return .noSlot }
        guard railShareAction != nil || railSoundFace != nil else { return .empty }
        // The way back (#1929), on a slot this composer draws; under a page's
        // column the page's own bubble wears it (`onScrollAwayChange`).
        if host.stream.showsScrollAwayReturn, host.composeBar.hostsActionColumn { return .returnTo(down: host.stream.returnsDown) }
        if railShareAction != nil { return .share }
        return railSoundFace.map { .sound($0) } ?? .empty
    }

    /// The sound's tap action, the host's (`setRailSoundActions`).
    private var soundTapAction: (() -> Void)?
    /// The way back's hold on the composer's own slot.
    private(set) var railSoundHold: HoldToArmPresenter?
    /// Whether the host asked the slot's record to turn, kept while the way
    /// back hides it (#692).
    private var railSpinning = false

    /// The composer's slot as the way back stands — and the bubble above the
    /// own bubble, where a slotless text page shows it (#2488).
    func applyRailWayBack() {
        host.wayBackBubble.refresh()
        if !host.viewModel.isDraft { host.composeBar.railFace = publishedRailFace }
        let returns = host.composeBar.railFace == .returnTo(down: host.stream.returnsDown)
        if !returns { host.composeBar.setRailSpinning(railSpinning) }
        // Over Share (#1999) the hold arms Share on a media page — the
        // slot's own action — and nothing on a text page.
        let armsSheet = returns && railShareAction == nil && soundTapAction != nil
            && railSoundFace?.isAvailable == true
        let armsShare = returns && railShareAction != nil && railShareHoldArms
        railSoundHold?.isEnabled = armsSheet || armsShare
        // What the slot stood for stays reachable with the chevron up:
        // VoiceOver's road — the sound, or Share.
        if armsSheet {
            host.composeBar.railHoldTarget.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Sound") { [weak self] _ in
                    self?.soundTapAction?()
                    return true
                },
            ]
        } else if returns, railShareAction != nil {
            host.composeBar.railHoldTarget.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Share") { [weak self] _ in
                    self?.railShareAction?()
                    return true
                },
            ]
        } else {
            host.composeBar.railHoldTarget.accessibilityCustomActions = nil
        }
    }

    func installRailWayBack() {
        host.composeBar.onRailAction = { [weak self] in
            guard let self else { return }
            if case .returnTo = host.composeBar.railFace { return host.scrollToStart(animated: true) }
            if host.composeBar.railFace == .share {
                railShareAction?()
            } else {
                soundTapAction?()
            }
        }
        let hold = HoldToArmPresenter(view: host.composeBar.railHoldTarget) { [weak self] in
            guard let self else { return .picture(nil) }
            return railShareAction != nil ? .symbol(CommentsInputBar.shareRailSymbol) : .picture(host.composeBar.railCoverImage)
        }
        hold.onFire = { [weak self] in
            guard let self else { return }
            if let railShareAction { railShareAction() } else { soundTapAction?() }
        }
        hold.isEnabled = false
        railSoundHold = hold
    }

    private var railSoundFace: SnapSoundFace?
    /// False for a text post with nothing in its slot (#1790, #1999): the
    /// composer has no slot, its field widens into it.
    private var railKeepsSlot = true
    /// The post's Share, when the slot wears it (#1999): a pushed page.
    private var railShareAction: (() -> Void)?
    /// Whether the way back's hold arms Share (#1999): a media page's.
    private var railShareHoldArms = false

    /// Share in the slot (#1999), the toolbar's old action, on a pushed page:
    /// a text page's (a text post has no sound) and a media page's (its sound
    /// moves to the footer). `holdArms`: the way back's hold arms Share — a
    /// media page's. Nil gives the slot back to the sound.
    func setRailShare(_ action: (() -> Void)?, holdArms: Bool = false) {
        railShareAction = action
        railShareHoldArms = action != nil && holdArms
        if action != nil { railKeepsSlot = true }
        guard !host.viewModel.isDraft else { return }
        applyRailWayBack()
    }

    /// The snap feed's sound bubble face, for the rail slot that stands on it
    /// (#671); `keepsSlot` false takes the slot away (#1790).
    func setRailSoundFace(_ face: SnapSoundFace?, keepsSlot: Bool = true) {
        railSoundFace = face
        railKeepsSlot = keepsSlot
        guard !host.viewModel.isDraft else { return }
        host.composeBar.railFace = publishedRailFace
    }

    /// The opening face, from `configureComposeBar`.
    func applyOpeningFace() {
        // A post's rail slot wears its sound (`publishedRailFace`). A draft
        // is not a post: its slot stays empty until it is.
        host.composeBar.railFace = host.viewModel.isDraft ? .empty : publishedRailFace
    }

    /// A published draft's face, from `becomePublished`.
    func applyPublishedFace() {
        host.composeBar.railFace = publishedRailFace
    }

    /// The slot's half of `setComposerBare`: no Share, no sound, no slot.
    func clearForBareComposer() {
        railShareAction = nil
        railShareHoldArms = false
        setRailSoundFace(nil, keepsSlot: false)
    }

    /// The slot's cover turns while the post plays aloud (#692).
    func setRailSoundSpinning(_ spinning: Bool) {
        railSpinning = spinning
        host.composeBar.setRailSpinning(spinning)
    }

    /// The slot's sound actions: `tap` is what the sound does (the sheet);
    /// while the way back shows, a tap goes back to the top and a hold arms
    /// `tap` (#1929).
    func setRailSoundActions(tap: (() -> Void)?, hold: (() -> Void)?) {
        soundTapAction = tap
        host.composeBar.onRailLongPress = hold
        applyRailWayBack()
    }
}

extension PostDetailViewController: PostDetailRailSlotHost, PostDetailWayBackBubbleHost {}
