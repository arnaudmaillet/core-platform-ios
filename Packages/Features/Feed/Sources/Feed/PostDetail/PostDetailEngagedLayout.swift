import DesignSystem
import ThreadKit
import UIKit

/// What the engaged layout asks of its panel (#2523): its view, which holds
/// the composer, the frost and the streams' surface and whose keyboard
/// guide the composer rides, the text size, the composer, the surface that
/// moves and hides the streams, the streams themselves, whether the post's
/// actions are shown, and the keyboard's cover (`PostDetailKeyboardWatch`).
@MainActor
protocol PostDetailEngagedLayoutHost: AnyObject {
    var view: UIView! { get }
    var traitCollection: UITraitCollection { get }
    var composeBar: CommentsInputBar { get }
    var streamSurface: UIView { get }
    var streams: [CommentStream] { get }
    var showsPostActions: Bool { get }
    var keyboardHeightFromBottom: CGFloat? { get }
}

/// The engaged layout, out of `PostDetailViewController` (#2523): the
/// composer's rest line, lift and entrance, the footer's frost, the engaged
/// insets and the keyboard's lift. The only writer of the composer's and the
/// streams' bottom constraints, of the frost and of `engagedStreamInsets`.
///
/// ⚠️ ITS CALLERS PICK THE TIME: the entrance runs inside the host's master
/// spring, the insets inside the Snap transitions, and the panel's
/// `viewDidLoad` installs the composer, then the streams. Every entry point
/// runs in the caller's turn: no `Task`, no hop.
@MainActor
final class PostDetailEngagedLayout {
    private unowned let host: any PostDetailEngagedLayoutHost

    init(host: any PostDetailEngagedLayoutHost) {
        self.host = host
    }

    private var composeBottomDefault: NSLayoutConstraint?
    private var composeBottomEngaged: [NSLayoutConstraint] = []
    /// **The action column (`SnapActionColumn`).** The engaged composer
    /// stands its stake and rail slot ON the media layout's like and repost
    /// bubbles — same size, same screen coordinates — so opening and closing
    /// the comments crossfades two bubbles that never move. The slot wears
    /// the post's sound (`publishedRailFace`); the composer's own bubble —
    /// the emote button, the send over a draft — stands beside it, on the
    /// row (#2308).
    ///
    /// - AT REST the bar's input row sits on the toolbar like every composer's
    ///   (`SnapActionColumn.inputRestingGap`) and the bar lifts its column to
    ///   the column's line; its trailing edge is the column's inset from the
    ///   screen's (not `lg`); the entrance is alpha only — no
    ///   micro-translation.
    /// - KEYBOARD UP the bar does NOT move: only its input row rides the
    ///   keyboard's top, `sm` above it, widening into the column's width as it
    ///   rises (`CommentsInputBar.riseWithKeyboard(of:)`). The column's bubbles
    ///   hold the media layout's coordinates under the keyboard (asked
    ///   2026-10-02).
    /// The stream's bottom when not engaged: the composer's top, or the risen
    /// input row's — whichever is higher (`configureViews`).
    private var scrollBottomDefault: [NSLayoutConstraint] = []
    private var scrollBottomEngaged: NSLayoutConstraint?
    /// The engaged footer's frost: rows gliding behind the composer stay
    /// visible but dissolve into a LIGHT blur, so the bar reads over them
    /// without the band reading as an overlay on the post. Clear at the
    /// band's top edge, full material at the screen's bottom — the header
    /// band's ramp, mirrored, and no `topRampLength`: that parameter exists to
    /// finish a ramp EARLY and hold it, which is exactly the plateau this
    /// stopped having. HIT-INERT: it must never eat the bar's taps or the
    /// swipe pan. Effect nil until the engaged entrance IN A WINDOW; it rides
    /// the master spring via `setComposerEntranceState`.
    let composerBackdrop = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.footerFrostMaskColors,
        maskLocations: SnapCommentsLayout.footerFrostMaskLocations
    )

    /// How far the keyboard holds the composer's input row above the bar's
    /// resting top: the room Recent gives up to ride it (#2007). Read off the
    /// solved layout, as a conversation reads it.
    var composerRise: CGFloat {
        guard composerTracksKeyboard, engagedStreamInsets != nil, !host.composeBar.isHidden else { return 0 }
        return max(0, host.composeBar.frame.minY - host.composeBar.occupiedMinY)
    }

    /// The streams' surface, ending at the composer's top: installed after
    /// the composer (`installComposer`), whose anchors it reads.
    func installStream() {
        // Scroll view fills above the compose bar. The default bottom stops
        // at the bar's top at rest, and at its input row's top while the
        // keyboard lifts the row above the bar (the bar itself never moves):
        // the higher of the two, pulled down to the bar by a low-priority
        // reach. The engaged context swaps all three for a full-bleed bottom
        // so the stream glides BEHIND the footer.
        let streamView = host.streamSurface
        let reach = streamView.bottomAnchor.constraint(equalTo: host.composeBar.topAnchor)
        reach.priority = .defaultLow
        scrollBottomDefault = [
            streamView.bottomAnchor.constraint(lessThanOrEqualTo: host.composeBar.topAnchor),
            streamView.bottomAnchor.constraint(lessThanOrEqualTo: host.composeBar.inputRowTopAnchor),
            reach,
        ]
        streamView.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(streamView)
        NSLayoutConstraint.activate([
            streamView.topAnchor.constraint(equalTo: host.view.topAnchor),
            streamView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ] + scrollBottomDefault)
    }

    /// The footer's frost, then the composer over it, with the composer's
    /// resting bottom (`composeBottomDefault`). Before the streams
    /// (`installStream`).
    func installComposer() {
        // The engaged footer band (hidden outside the engagement): below
        // the bar, above the stream.
        composerBackdrop.isHidden = true
        composerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(composerBackdrop)
        host.view.addSubview(host.composeBar)
        host.composeBar.translatesAutoresizingMaskIntoConstraints = false
        // Sits at the safe-area bottom for good; only its input row rides the
        // keyboard (`riseWithKeyboard`). Stored: the engaged context replaces
        // it (`setEngagedInsets`) — there the composer must occupy the NATIVE
        // FOOTER'S band, which the safe area deliberately still contains.
        let bottom = host.composeBar.bottomAnchor.constraint(
            equalTo: host.view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.sm
        )
        composeBottomDefault = bottom
        NSLayoutConstraint.activate([
            host.composeBar.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: Spacing.lg),
            // The column's inset from the screen's edge, so the column stands
            // on the media layout's bubbles.
            host.composeBar.trailingAnchor.constraint(
                equalTo: host.view.trailingAnchor, constant: -SnapActionColumn.trailingInset
            ),
            bottom,
            composerBackdrop.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            composerBackdrop.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            composerBackdrop.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            // The band starts ABOVE the composer by the lead, so its ramp
            // is finished — full material — by the time it reaches the
            // capsule's top edge. Anchored to the composer, so it rides the
            // keyboard with it — to its INPUT ROW, not the bar's top: the
            // stake bubble above the row floats in the ramp, and the band
            // keeps the height it had before the bubble moved up there.
            composerBackdrop.topAnchor.constraint(
                equalTo: host.composeBar.inputRowTopAnchor, constant: -SnapCommentsLayout.footerFrostLead
            ),
        ])
        host.composeBar.riseWithKeyboard(of: host.view.keyboardLayoutGuide)
    }

    /// The STREAM's shrink for the engagement, 0 (engaged) → 1 (dismissed).
    ///
    /// It scales the list and nothing else. The composer and the footer's
    /// blur band are siblings of the list, not children, so they hold their
    /// size and position at the screen's edge while the content pulls away —
    /// which is the whole point: a band that scales stops being chrome and
    /// starts being part of the moving layer.
    func setStreamTransitionProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        let scale = 1 + (SnapCommentsLayout.streamEntranceScale - 1) * t
        host.streamSurface.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    /// The composer's entrance state for the engaged footer handoff:
    /// offstage = invisible. ALPHA ONLY: the column's bubbles stand on the
    /// media layout's like and repost bubbles (`SnapActionColumn`), and a
    /// slide would move them — the two layouts crossfade in place.
    /// Set offstage BEFORE the spring; animate to onstage INSIDE it.
    func setComposerEntranceState(offstage: Bool) {
        host.composeBar.alpha = offstage ? 0 : 1
        // The footer band rides the same seam — this already runs inside the
        // master spring both ways, and `effect` is the one animatable path
        // for a material. Window-guarded (headless CI never pays for a real
        // blur) and gated on the engaged context (outside it there is no
        // band).
        if offstage {
            composerBackdrop.effect = nil
        } else if host.view.window != nil, !composerBackdrop.isHidden, composerBackdrop.effect == nil {
            composerBackdrop.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    /// Extra bottom room so resting content clears the composer: the bar's
    /// resting top above the footer line (its rest gap and its height, the
    /// lifted column and the stake on it included), plus the breath a resting
    /// row keeps above it — the column's two bubbles sit at the trailing
    /// edge, where a resting row's ♥ would be.
    ///
    /// ⚠️ LESS THE SECTION'S OWN BOTTOM INSET (#1923). The last row already
    /// ends `Spacing.lg` above the content's end; counted on top of the
    /// breath, the comments rested ~24 pt higher over the composer than a
    /// conversation's messages over theirs (the owner, 2026-10-30). The two
    /// streams now keep the same `Spacing.sm` there.
    var engagedFooterClearance: CGFloat {
        composerRestingGap + restingComposerHeight(for: .large) + Self.composerTopBreath
            - streamSectionVerticalInsets
    }

    /// The resting composer's height: its column as it stands — the slot
    /// alone once a media page folds its column (#1923).
    func restingComposerHeight(for category: UIContentSizeCategory) -> CGFloat {
        CommentsInputBar.restingHeight(for: category, showsStake: host.composeBar.showsStake)
    }

    /// Between the resting composer's top and the last row resting above it:
    /// a conversation's (`ConversationThreadViewController.syncBottomClearance`).
    private static let composerTopBreath: CGFloat = Spacing.sm

    /// The composer's resting gap above the footer line: its input row
    /// `glassGap` above the toolbar's glass — the bar lifts its own column
    /// (`SnapActionColumn`).
    var composerRestingGap: CGFloat { SnapActionColumn.inputRestingGap + composerLift }

    /// (#1716, #1722): the composer rises with the page's bottom block — one
    /// breath over the bar — so the action column keeps its place.
    private var composerLift: CGFloat = SnapActionColumn.bottomBreath

    func setComposerLift(_ lift: CGFloat) {
        guard lift != composerLift else { return }
        // A rest line already drawn moves by the difference.
        composeBottomEngaged.first?.constant -= lift - composerLift
        composerLift = lift
    }

    func setEngagedInsets(top: CGFloat, bottomInset: CGFloat) {
        // The strip inset is the ONLY top authority in the engaged context:
        // the full-cell scroll view would otherwise also inherit the safe
        // area's automatic adjustment and double-inset the resting position.
        // TOTAL immersion: the stream spans the full height and glides
        // BEHIND the footer too — the scroll's bottom swaps from the
        // compose bar's top to the view's bottom, with a bottom inset so
        // resting content still clears the footer band. The frost keeps
        // the bar legible over the moving rows.
        NSLayoutConstraint.deactivate(scrollBottomDefault)
        if scrollBottomEngaged == nil {
            scrollBottomEngaged = host.streamSurface.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        }
        scrollBottomEngaged?.isActive = true
        // Recorded so the empty page can be sized against the SETTLED
        // geometry on frame 0 — the stream is still growing into these
        // numbers while the transition runs.
        engagedStreamInsets = (
            top: max(0, top),
            bottom: max(0, bottomInset) + engagedFooterClearance
        )
        host.streams.forEach { $0.applyEngagedInsets(top: max(0, top), bottom: max(0, bottomInset) + engagedFooterClearance) }
        updateComposerBackdropVisibility()
        // Z-ORDER, load-bearing: the scroll view is added AFTER the compose
        // bar at build time (harmless while it ended at the bar's top), so
        // at full height it would sit ABOVE the footer and swallow every
        // touch in the band — taps, the ✕, the swipe pan (found via hit
        // logging: bar frame contained the point, a CommentRowView won).
        // The footer must cap the stack in the engaged context.
        host.view.bringSubviewToFront(composerBackdrop)
        host.view.bringSubviewToFront(host.composeBar)

        // The composer OCCUPIES THE NATIVE FOOTER'S BAND: the feed keeps
        // its toolbar structurally present for the whole engagement (the
        // safe area must never move — that's the zero-churn contract), so
        // the resting position anchors to the WINDOW's home-indicator
        // inset (`bottomInset`, toolbar-independent) instead of the safe
        // area. The keyboard never moves the BAR: its input row rides the
        // guide on its own (`riseWithKeyboard`), measured from the screen's
        // edge too.
        host.view.keyboardLayoutGuide.usesBottomSafeArea = false
        composeBottomDefault?.isActive = false
        NSLayoutConstraint.deactivate(composeBottomEngaged)
        // The rest line: the input row `glassGap` above the toolbar's glass. The bar
        // lifts its own column off that line, onto the media layout's like
        // and repost bubbles (`SnapActionColumn`).
        let rest = host.composeBar.bottomAnchor.constraint(
            equalTo: host.view.bottomAnchor, constant: -(max(0, bottomInset) + composerRestingGap)
        )
        composeBottomEngaged = [rest]
        rest.isActive = true
    }

    /// How far the keyboard lifts the composer's input row above where it
    /// rests: the room a short stream gives up, so it rises with the row
    /// rather than going behind the keys (#1799). The keyboard never touches
    /// the stream's insets (`currentEmptyPageFit`).
    var keyboardLift: CGFloat {
        guard composerTracksKeyboard, let covered = host.keyboardHeightFromBottom,
              let engaged = engagedStreamInsets else { return 0 }
        let category = host.traitCollection.preferredContentSizeCategory
        let restingBottomInset = engaged.bottom - engagedFooterClearance
        let restingTop = host.view.bounds.height - restingBottomInset - composerRestingGap
            - restingComposerHeight(for: category)
        let risenTop = host.view.bounds.height - covered - Spacing.sm - CommentsInputBar.restingInputRowHeight(for: category)
        return max(0, restingTop - risenTop)
    }

    /// Whether the composer's input row is allowed to be lifted by the
    /// KEYBOARD (`CommentsInputBar.tracksKeyboard`).
    ///
    /// ⚠️ THE CEILING IS ANCHORED TO THE SCREEN, and a page that is only
    /// partly on it hangs below. `keyboardLayoutGuide` is a window-space guide:
    /// with no keyboard up its top sits at the bottom of the SCREEN, and the
    /// constraint is required — so a panel whose own view extends past the
    /// bottom (a page scrolling in, whose cell is still half below) has its
    /// composer pinned to the screen's edge instead of travelling with the
    /// page. Two composers are then visible at once: the page's, moving, and
    /// this one, stuck. Reported exactly that way.
    ///
    /// Only the page a viewer can actually type on needs it, so it is granted
    /// rather than assumed — off while a panel is standing in for a page that
    /// is arriving, on when that page becomes the one being read.
    func setComposerTracksKeyboard(_ tracks: Bool) {
        composerTracksKeyboard = tracks
        host.composeBar.tracksKeyboard = tracks
    }

    private(set) var composerTracksKeyboard = true

    /// The footer band shows in the engaged context (`setEngagedInsets`)
    /// under a composer that is shown — never under one an unavailable post
    /// took away (#1404).
    func updateComposerBackdropVisibility() {
        composerBackdrop.isHidden = !host.showsPostActions || engagedStreamInsets == nil
    }

    /// The footer's veil, from the post's format (`SnapCommentsLayout.frostVeilOpacity`).
    func setFrostVeilOpacity(_ opacity: CGFloat) {
        composerBackdrop.setVeilOpacity(opacity)
    }

    /// The engaged context's own insets, kept so the settled geometry can be
    /// computed before the transition has produced it. Nil until engaged.
    private(set) var engagedStreamInsets: (top: CGFloat, bottom: CGFloat)?

    /// The empty stream's section insets, mirroring the layout
    /// (`collectionView`): no top inset — the stream leads with its caption
    /// row, even while a draft has none yet — and `Spacing.lg` at the bottom.
    var streamSectionVerticalInsets: CGFloat { Spacing.lg }
}

extension PostDetailViewController: PostDetailEngagedLayoutHost {}
