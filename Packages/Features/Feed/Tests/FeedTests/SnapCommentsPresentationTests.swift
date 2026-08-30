import CoreContracts
import CoreStorage
import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import Testing
import UIKit
@testable import Feed

/// The comments engagement's geometry and choreography contracts: one
/// authority (`SnapCommentsLayout`) sizes the expanded caption card and the
/// comments region so they partition the container exactly, while the post's
/// media stays full-bleed behind both — the engaged layout never moves it,
/// and never touches playback ownership.
@MainActor
struct SnapCommentsPresentationTests {
    private static let container = CGRect(x: 0, y: 0, width: 390, height: 844)
    private static let topInset: CGFloat = 103

    // MARK: - Layout authority

    /// The chrome zone and the comments region tile the cell with no gap and
    /// no overlap. The boundary is now a pure function of the safe area —
    /// no caption is measured into it, because the caption scrolls INSIDE
    /// the region rather than sitting in a reserved band above it.
    @Test func chromeZoneAndCommentsRegionPartitionTheCell() {
        for inset in [CGFloat(0), 20, Self.topInset, 160] {
            let top = SnapCommentsLayout.commentsTopInset(topInset: inset)
            let region = SnapCommentsLayout.commentsRegionHeight(
                containerHeight: Self.container.height, topInset: inset
            )
            #expect(top + region == Self.container.height)
            // It clears the chrome and nothing more: a breath, not a band.
            #expect(top > inset)
            #expect(top - inset < 40)
        }
    }

    /// The background treatment is a real dim that still shows the post:
    /// opaque enough for white body text, never a curtain (the opaque black
    /// container this replaced is exactly what the layout exists to undo).
    @Test func backdropDimsWithoutHidingTheMedia() {
        #expect(SnapCommentsLayout.backdropDimOpacity > 0.25)
        #expect(SnapCommentsLayout.backdropDimOpacity < 0.75)
        // The bands are the system's standard separator blur — adaptive,
        // semi-translucent. The protection comes from the LEAD, not from a
        // denser material (thick was tried and read as too solid).
        #expect(SnapCommentsLayout.frostStyle == .regular)
        // The footer band leads the composer, so its ramp is finished by the
        // capsule's top edge — a ramp that ended AT the composer left it
        // floating over the clearest part of its own band.
        #expect(SnapCommentsLayout.footerFrostLead > 0)
    }

    // ⚠️ THE CAPTION'S GLASS BUBBLE IS GONE, and with it the test that pinned
    // its radius, its inset and its inherited appearance. The caption is drawn
    // with `CommentRowView` now — the same row the comments use, with no
    // material of its own — so there is no second surface to keep in step with
    // the stream's. See `PostCaptionFaceSpecTests`.

    /// The INTERACTIVE pull-down's progress model: the list's OVERSHOOT
    /// past its top maps to a clamped 0…1, and release commits on distance
    /// OR a flick. Driving from the overshoot is what welds the transition
    /// to the rubber band — they are the same number — and what makes
    /// arming unconditional without a rule, since overshoot exists only at
    /// the top.
    @Test func pullDismissProgressTracksTheFingerAndCommitsOnRelease() {
        // Linear over the drag distance, clamped at both ends: an upward
        // drag reads as 0 rather than running the transition backwards past
        // its own resting state, and past the full distance it stays at 1.
        #expect(SnapCommentsLayout.pullDismissProgress(translation: 0) == 0)
        #expect(SnapCommentsLayout.pullDismissProgress(translation: -300) == 0)
        #expect(SnapCommentsLayout.pullDismissProgress(
            translation: SnapCommentsLayout.pullDismissDistance) == 1)
        #expect(SnapCommentsLayout.pullDismissProgress(translation: 900) == 1)
        // The distance is an OVERSHOOT, which UIKit damps to roughly half
        // the finger's travel — so it has to be well under a finger-scale
        // number or the gesture would need an implausible drag.
        #expect(SnapCommentsLayout.pullDismissDistance <= 120)
        let half = SnapCommentsLayout.pullDismissProgress(
            translation: SnapCommentsLayout.pullDismissDistance / 2)
        #expect(abs(half - 0.5) < 0.001)
        // Monotonic through the middle.
        #expect(SnapCommentsLayout.pullDismissProgress(translation: 40)
            < SnapCommentsLayout.pullDismissProgress(translation: 80))

        // Release: a decisive pull finishes…
        #expect(SnapCommentsLayout.shouldCompletePullDismiss(
            progress: SnapCommentsLayout.pullDismissCommitProgress, velocity: 0))
        #expect(SnapCommentsLayout.shouldCompletePullDismiss(progress: 1, velocity: 0))
        // …a hesitant one springs back…
        #expect(SnapCommentsLayout.shouldCompletePullDismiss(progress: 0.1, velocity: 0) == false)
        // …and a FLICK finishes from anywhere, which is what keeps a fast
        // short throw from feeling ignored.
        #expect(SnapCommentsLayout.shouldCompletePullDismiss(
            progress: 0.05, velocity: SnapCommentsLayout.pullDismissCommitVelocity))
        // The commit point is genuinely partial — committing only at the end
        // would make the gesture feel like it had to be completed.
        #expect(SnapCommentsLayout.pullDismissCommitProgress > 0)
        #expect(SnapCommentsLayout.pullDismissCommitProgress < 0.5)
    }

    /// The engagement's interpolatable state is ONE function of progress,
    /// and its endpoints are exactly what the animated engage/disengage
    /// produce. That shared definition is what lets a committed drag hand
    /// off to `dismissComments` mid-gesture without reconciling anything.
    @Test func engagementProgressInterpolatesAndMatchesTheAnimatedEnds() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        let container = try #require(hosted.superview)
        let backdrop = try backdrop(of: cell)

        // Engaged IS progress 0.
        #expect(container.alpha == 1)
        #expect(container.transform == .identity)
        #expect(abs(backdrop.dimOpacity - SnapCommentsLayout.backdropDimOpacity) < 0.001)

        // Mid-drag: every leg sits between its ends, none of them switched.
        cell.setCommentsEngagementProgress(0.5)
        #expect(abs(container.alpha - 0.5) < 0.01)
        #expect(backdrop.dimOpacity < SnapCommentsLayout.backdropDimOpacity)
        #expect(backdrop.dimOpacity > 0)
        // THE BANDS DO NOT SCALE. The container carries no transform at all
        // — the shrink belongs to the hosted stream — so the footer's band
        // (inside it) and the header's (a sibling) both hold their size at
        // the screen's edge and only fade.
        #expect(container.transform == .identity)
        let frost = try #require(
            firstDescendant(of: cell.contentView, ofType: ProgressiveFrostView.self)
        )
        #expect(frost.transform == .identity)
        #expect(abs(frost.alpha - 0.5) < 0.01)

        // Progress 1 lands on exactly what the animated disengage produces —
        // asserted by driving the boolean path and comparing.
        cell.setCommentsEngagementProgress(1)
        let alphaAtOne = container.alpha, frostAtOne = frost.alpha
        let dimAtOne = backdrop.dimOpacity
        cell.setCommentsEngagementProgress(0)
        cell.setCommentsEngaged(false)
        #expect(container.alpha == alphaAtOne)
        #expect(backdrop.dimOpacity == dimAtOne)
        #expect(frost.alpha == frostAtOne)

        // Clamped: nothing runs past either end.
        cell.setCommentsEngagementProgress(-3)
        #expect(container.alpha == 1)
        cell.setCommentsEngagementProgress(9)
        #expect(container.alpha == 0)
    }

    /// The treatment is a WASH AND NOTHING ELSE. No blur, no material, no
    /// gradient anywhere in the layer — two rounds of dark material were
    /// tried and both fogged the photo out, so "is there an effect view in
    /// here" is now a real regression, not a style preference. It is also
    /// what makes the layer free over a playing `AVPlayerLayer` and what
    /// lets it behave identically on a headless CI host (no `UIBlurEffect`
    /// means no render-server contact, so no window guard).
    @Test func theBackdropIsAPlainWashWithNoBlur() throws {
        let cell = makeEngagedCell()
        let backdrop = try backdrop(of: cell)
        var stack: [UIView] = [backdrop]
        while let view = stack.popLast() {
            #expect(view as? UIVisualEffectView == nil)
            stack.append(contentsOf: view.subviews)
        }
        // The wash is the view itself — one layer, opaque black, alpha-driven.
        let colour = try #require(backdrop.backgroundColor)
        var white: CGFloat = -1, alpha: CGFloat = -1
        #expect(colour.getWhite(&white, alpha: &alpha))
        #expect(white == 0 && alpha == 1)
        // And it raises OUT OF A WINDOW — unlike every blur in this feature,
        // which stays nil until the view is windowed.
        #expect(cell.window == nil)
        #expect(abs(backdrop.dimOpacity - SnapCommentsLayout.backdropDimOpacity) < 0.001)
    }

    @Test func degenerateBoundsAreSafe() {
        #expect(SnapCommentsLayout.commentsRegionHeight(containerHeight: 10, topInset: 500) == 0)
    }

    // MARK: - Cell engagement

    /// Configures the cell as a PHOTO post (or a text-only page with
    /// `media: false`): engagement variants key off the model's media, so
    /// every engagement fixture must configure before engaging.
    private func configurePost(_ cell: SnapFeedCell, media: Bool = true) {
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0000"),
                authorID: ProfileID("profile-1"),
                authorName: "Ava",
                metaText: "@ava · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: media ? URL(string: "mock://media/0.jpg") : nil,
                mediaKind: .image,
                thumbnailURL: nil,
                audioText: media ? "Original audio · @ava" : nil,
                likeCount: 0,
                timestampText: "5 days"
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
    }

    /// The standard engaged fixture is a PHOTO post: the dock/crop/card
    /// assertions run against the image surface, proving photo posts ride
    /// the exact video-parity pipeline (the dock loop drives both render
    /// surfaces with one transform — the video-side tests cover the other
    /// face). `media: false` builds a TEXT-ONLY page, whose engagement is
    /// the text-lead resting variant.
    private func makeEngagedCell(media: Bool = true) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell, media: media)
        cell.layoutIfNeeded()
        cell.setCommentsEngaged(true)
        return cell
    }

    /// Engaging leaves the media EXACTLY where it was — full-bleed surfaces
    /// at identity, the page's background rather than a docked tile — and
    /// dims it behind the stream instead. It fades the comment surfaces
    /// while the ACTION RAIL stays untouched (the blueprint's keep);
    /// disengaging clears the treatment completely.
    @Test func engagementBacksTheStreamWithTheMediaAndReverses() throws {
        let cell = makeEngagedCell()
        #expect(cell.isCommentsEngaged)

        let card = try mediaCard(of: cell)
        let media = card.imageView
        // The SURFACES never move: no dock transform, no crop mask. The
        // whole "engagement owns the media transform" doctrine is gone.
        #expect(media.transform == .identity)
        #expect(media.mask == nil)
        #expect(card.renderView.transform == .identity)
        #expect(card.renderView.mask == nil)
        // The engagement's only geometry is the card's own whisper of a
        // recede, and the backdrop's dim over it.
        // The engagement does not touch the media's geometry AT ALL: no
        // scale, no corner rounding, no clip. A 6pt pullback with
        // screen-concentric corners rode the engagement for a while and read
        // as a phantom layer sliding under the content rather than as depth.
        #expect(card.transform == .identity)
        #expect(card.clipsToBounds == false)
        #expect(card.layer.cornerRadius == 0)
        let backdrop = try backdrop(of: cell)
        // Tolerance, not equality: `UIView.alpha` round-trips through a
        // Float, so the CGFloat constant never comes back bit-identical.
        #expect(abs(backdrop.dimOpacity - SnapCommentsLayout.backdropDimOpacity) < 0.001)
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        // THE CHROME IS THE FADED LAYER — one alpha for every surface it
        // owns, which is what makes the engagement one animation instead of
        // seven (see `setCommentsEngagedProgress`).
        #expect(chrome.alpha == 0)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        // The members keep their own alpha and inherit the container's.
        #expect(ticker.alpha == 1)
        #expect(subtitle.alpha == 1)
        // The action column goes with them. It used to ride both states at
        // full presence, floating over the comment list; the engaged layout
        // owns the full width now, so the rail and its "+" anchor fade out
        // together (alpha < 0.01 also retires them from hit-testing, which
        // is what removed the composer-vs-rail overlap entirely).
        let plus = try #require(chrome.subviews.compactMap { $0 as? SnapRailBoostButton }.first)
        #expect(rail.alpha == 1)
        #expect(plus.alpha == 1)
        #expect(chrome.interactionRoots.contains(plus))

        cell.setCommentsEngaged(false)
        #expect(cell.isCommentsEngaged == false)
        #expect(media.transform == .identity)
        #expect(card.transform == .identity)
        #expect(backdrop.dimOpacity == 0)
        #expect(chrome.alpha == 1)
        #expect(ticker.alpha == 1)
        #expect(subtitle.alpha == 1)
        #expect(plus.alpha == 1)
    }

    /// The stream's floor is TRANSPARENT: the container the comments are
    /// hosted in was opaque black for the docked-tile layout, and that one
    /// colour is what hid the post for the whole engagement. Nothing may
    /// quietly reintroduce it — the readability layer is the only thing
    /// between the media and the rows.
    @Test func theCommentsContainerNeverPaintsOverTheMedia() throws {
        let cell = makeEngagedCell()
        let container = try #require(
            firstDescendant(of: cell.contentView, ofType: SnapCommentsContainerView.self)
        )
        let colour = try #require(container.backgroundColor)
        var alpha: CGFloat = -1
        #expect(colour.getWhite(nil, alpha: &alpha))
        #expect(alpha == 0)
        // And it sits ABOVE the media and the backdrop, never below them.
        // ⚠️ THE STAGE'S SUBVIEWS, found through one of them rather than named.
        //
        // The page's layers are siblings inside a frame-managed container, so a
        // transition can move the whole page as one object. WHICH view that is
        // is not this suite's business; that they are stacked in a particular
        // order still is.
        let subviews = try #require(
            firstDescendant(of: cell.contentView, ofType: SnapMediaCardView.self)?.superview
        ).subviews
        let mediaIndex = try #require(subviews.firstIndex(of: mediaCard(of: cell)))
        let backdropIndex = try #require(subviews.firstIndex(of: backdrop(of: cell)))
        let streamIndex = try #require(subviews.firstIndex(of: container))
        #expect(mediaIndex < backdropIndex)
        #expect(backdropIndex < streamIndex)
    }

    /// The engaged cell has NO rail to collide with: the column is faded
    /// out, and a view under alpha 0.01 is not hit-tested, so every touch
    /// in what used to be the rail's territory reaches the stream beneath.
    ///
    /// (This replaces a keyboard-up collision rule — the composer used to
    /// have to out-rank the rail wherever the two physically overlapped,
    /// arbitrated by hand in the cell's hitTest. Fading the rail removed
    /// the collision instead of refereeing it.)
    @Test func engagedCellHasNoRailToCollideWith() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/4"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        cell.layoutIfNeeded()
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let railPoint = CGPoint(x: rail.frame.midX, y: rail.frame.midY)

        // At rest the column owns its touches.
        let restingHit = try #require(cell.hitTest(railPoint, with: nil))
        #expect(sequence(first: restingHit, next: { $0.superview }).contains { $0 is SnapShortcutRailView })

        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        // Engaged, the same point falls through to the comments host.
        let engagedHit = try #require(cell.hitTest(railPoint, with: nil))
        #expect(!sequence(first: engagedHit, next: { $0.superview }).contains { $0 is SnapShortcutRailView })
        #expect(engagedHit === hosted)
    }

    /// The layered engaged hierarchy: the media stays at the BACK, the
    /// readability layer covers it, the comments host spans the FULL cell
    /// (content rides under the card), the wall-to-wall header frost covers
    /// exactly screen-top → strip-bottom, and the glass card floats on top
    /// — the sandwich is media → backdrop → stream → frost → card;
    /// `clearComments` restores everything.
    @Test func installedCommentsLayerOverTheBackgroundMedia() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        // Full-height stream, SQUARE and unclipped — a screen-matched corner
        // was tried twice and removed: `containerConcentric` resolves to ~0
        // for a view flush with its container, and reading the display's own
        // radius meant private API for something visually inert on a
        // transparent container.
        let container = try #require(hosted.superview)
        #expect(container.clipsToBounds == false)
        #expect(container.layer.cornerRadius == 0)
        #expect(container.frame.minY == 0)
        #expect(container.frame.maxY == Self.container.height)
        #expect(container.frame.width == Self.container.width)
        #expect(container.alpha == 1)

        // …under the header frost, which spans EXACTLY its container —
        // screen top to where the stream's content begins — and ramps
        // across all of it. It must not overhang: blur spilling past the
        // chrome it serves lands on the content. Hit-inert throughout.
        // ⚠️ THE STAGE'S SUBVIEWS, found through one of them rather than named.
        //
        // The page's layers are siblings inside a frame-managed container, so a
        // transition can move the whole page as one object. WHICH view that is
        // is not this suite's business; that they are stacked in a particular
        // order still is.
        let subviews = try #require(
            firstDescendant(of: cell.contentView, ofType: SnapMediaCardView.self)?.superview
        ).subviews
        let frost = try #require(firstDescendant(of: cell.contentView, ofType: ProgressiveFrostView.self))
        #expect(frost.isHidden == false)
        #expect(frost.frame == CGRect(
            x: 0, y: 0,
            width: Self.container.width,
            height: SnapCommentsLayout.commentsTopInset(topInset: Self.topInset)
        ))
        #expect(frost.frame.maxY == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
        #expect(frost.isUserInteractionEnabled == false)
        let frostMask = try #require(frost.mask)
        #expect(frostMask.frame == frost.bounds)
        // The HEADER ramps endpoint to endpoint across its container:
        // opaque at the screen's edge, clear at the content line.
        let header = SnapCommentsLayout.headerFrostMaskColors
        #expect(header.count == 2)
        #expect(SnapCommentsLayout.headerFrostMaskLocations == [0, 1])
        func alpha(_ colour: UIColor) -> CGFloat {
            var a: CGFloat = -1
            _ = colour.getWhite(nil, alpha: &a)
            return a
        }
        #expect(alpha(header[0]) == 1)
        #expect(alpha(header[1]) == 0)
        // ⚠️ AND THE FOOTER IS THE SAME RAMP, MIRRORED. It used to fade in
        // over the lead and then HOLD full material to the screen's bottom —
        // right about the composer's legibility, wrong about proportion: the
        // hold made two thirds of the band a flat slab, and over a text page
        // (where a veil stands in for a blur with nothing to refract) it read
        // as a lid. Two stops now, ends reversed, no knee.
        let footer = SnapCommentsLayout.footerFrostMaskColors
        #expect(footer.count == 2)
        #expect(SnapCommentsLayout.footerFrostMaskLocations == [0, 1])
        #expect(alpha(footer[0]) == 0)
        #expect(alpha(footer[1]) == 1)
        // Stated as the mirror it is, so the pair cannot drift apart: whatever
        // the header does at its outer edge, the footer does at its own.
        #expect(alpha(footer.last!) == alpha(header.first!))
        #expect(alpha(footer.first!) == alpha(header.last!))

        // NO caption in the cell at all any more — it is the hosted stream's
        // FIRST ROW, so the feed cell must not carry a second copy floating
        // above. Asserted against the row the caption is drawn with now.
        #expect(subviews.compactMap { $0 as? CommentRowView }.isEmpty)

        // …with the media at the BACK of the stack, under the readability
        // layer — never z-lifted over the stream (the lift is what let the
        // docked tile's invisible full-bleed frame eat stream touches).
        let media = try #require(subviews.compactMap { $0 as? SnapMediaCardView }.first)
        let backdrop = try #require(subviews.compactMap { $0 as? SnapMediaBackdropView }.first)
        let mediaIndex = try #require(subviews.firstIndex(of: media))
        let backdropIndex = try #require(subviews.firstIndex(of: backdrop))
        let containerIndex = try #require(subviews.firstIndex(of: container))
        #expect(mediaIndex == 0)
        #expect(mediaIndex < backdropIndex)
        #expect(backdropIndex < containerIndex)
        // The backdrop covers the WHOLE cell — the stream reads over media
        // at every row, not only under the card.
        #expect(backdrop.frame == cell.contentView.bounds)
        #expect(backdrop.isUserInteractionEnabled == false)

        cell.setCommentsEngaged(false)
        cell.clearComments()
        #expect(hosted.superview == nil)
        #expect(container.isHidden == true)
        #expect(frost.isHidden == true)
        #expect(frost.effect == nil)
        #expect(backdrop.dimOpacity == 0)
        // The media never moved, so there is no z-order to restore. Asked of
        // its own parent rather than the cell's: the page's layers are
        // siblings inside a stage, and this claim is about their order, not
        // about how deep they sit.
        #expect(media.superview?.subviews.firstIndex(of: media) == 0)
    }

    /// REGRESSION, inverted (stranded center tile): the outbound push's
    /// lifecycle resign used to run a Ken Burns stop, which had to settle
    /// onto a per-state resting transform — a blind identity stranded the
    /// docked tile as a frozen full-bleed center crop that the return could
    /// not heal. The drift is gone entirely now (see
    /// `theBackgroundMediaNeverScales`), so identity is not merely correct
    /// throughout: it is the only value these surfaces ever hold.
    @Test func outboundResignLeavesTheBackgroundMediaAlone() throws {
        let cell = makeEngagedCell()
        let card = try mediaCard(of: cell)
        let media = card.imageView
        #expect(media.transform == .identity)

        // The outbound push's lifecycle: activate, then resign (image
        // cells run the Ken Burns stop on this path).
        cell.willBecomeActive()
        cell.didResignActive(releasingPlayback: true)
        #expect(media.transform == .identity)
        // Nothing the engagement does can disturb the media, because the
        // engagement no longer touches it.
        #expect(card.transform == .identity)

        // The appearance re-assert is idempotent, and inert once disengaged.
        cell.reassertEngagedGeometry()
        #expect(media.transform == .identity)
        #expect(card.transform == .identity)
        cell.setCommentsEngaged(false)
        cell.reassertEngagedGeometry()
        #expect(card.transform == .identity)
    }

    /// THE DISENGAGE'S COMPLETION MUST RIDE THE ANIMATION, not the
    /// transaction — this is the regression that made the ✕ leave every
    /// comment entry point dead.
    ///
    /// The teardown is what clears the screen's `commentsEngagedID`, and while
    /// that is set `presentComments` refuses to open. Hanging the completion
    /// off `CATransaction.setCompletionBlock` looked right and never fired:
    /// `animateCommentsEngaged` calls `performWithoutAnimation`, which opens
    /// and commits a NESTED transaction, and the block set on the outer one
    /// was lost. The drag-down exit hid it, because it drives the progress to
    /// the end itself before handing off, so the page looked correct either
    /// way — only the reopen was broken.
    @Test func theDisengageCarriesItsCompletionOnTheAnimation() throws {
        let cell = makeEngagedCell()
        var completions = 0
        cell.animateCommentsEngaged(false, duration: 0.3) { completions += 1 }

        // Some layer in the transition carries it — deliberately not asserting
        // WHICH, because that is the cell's business; what matters is that the
        // completion is attached to an ANIMATION and so cannot be lost by a
        // nested transaction.
        func engageAnimations(_ layer: CALayer) -> [CAAnimation] {
            let mine = layer.animation(forKey: "comments-engage-opacity").map { [$0] } ?? []
            return mine + (layer.sublayers ?? []).flatMap(engageAnimations)
        }
        let animations = engageAnimations(cell.contentView.layer)
        #expect(!animations.isEmpty)
        #expect(animations.contains { $0.delegate != nil })
        #expect(cell.isCommentsEngaged == false)

        // A call with nothing to change still reports back — a caller whose
        // teardown hangs off this must never be stranded by a no-op.
        completions = 0
        cell.animateCommentsEngaged(false, duration: 0.3) { completions += 1 }
        #expect(completions == 1)
    }

    /// A WARM panel is invisible and inert. Building the comments ahead of
    /// the tap is what removed the transition's main-thread stall (~115ms of
    /// construction and layout, measured, which is about seven frames the
    /// video is not shown on), but a panel installed early must not be
    /// VISIBLE early — `installComments` unhides the header frost and a
    /// freshly installed panel has never been through the engagement's
    /// interpolator, so the dismissed pose has to be asserted explicitly.
    ///
    /// Alpha 0 is also what keeps the full-cell container out of hit-testing,
    /// so a warm panel cannot eat the resting page's taps.
    @Test func aWarmCommentsPanelIsInvisibleAndInert() throws {
        let cell = SnapFeedCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
                metaText: "@ana · 3m", avatarURL: nil, caption: "caption",
                mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
                thumbnailURL: nil, audioText: nil
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        let panel = UIView()
        cell.installComments(panel)
        // The warm's pose: fully dismissed, which is progress 1.
        cell.setCommentsEngagementProgress(1)
        cell.layoutIfNeeded()

        let container = try #require(panel.superview)
        #expect(container.alpha == 0)
        // Below UIKit's hit-testing floor, so the resting page keeps its taps.
        #expect(container.alpha < 0.01)
        // The frost band came out of hiding with the install; the pose is
        // what keeps it from being seen.
        let frost = try #require(
            firstDescendant(of: cell.contentView, ofType: ProgressiveFrostView.self)
        )
        #expect(frost.alpha == 0)
        // And the page's own chrome is fully present, as at rest.
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        #expect(chrome.alpha == 1)
        #expect(cell.isCommentsEngaged == false)
    }

    /// THE MEDIA NEVER SCALES — not at rest, not while the comments open,
    /// not while they close, not on any lifecycle edge in between.
    ///
    /// An 8s Ken Burns zoom to 1.12× used to run on photo pages. The
    /// comments have to read over a still background, so engaging stopped it
    /// (a snap back from wherever the zoom had reached) and disengaging
    /// restarted it — beginning a zoom INSIDE the transition's own animation
    /// block. From the reader's side that is the background scaling as the
    /// comments open and close. Nothing sets a transform on these surfaces
    /// any more, and this walks the whole cycle to say so.
    @Test func theBackgroundMediaNeverScales() throws {
        let cell = makeEngagedCell()
        let card = try mediaCard(of: cell)
        let media = card.imageView

        func expectStill(_ stage: String) {
            #expect(media.transform == .identity, "media scaled at: \(stage)")
            #expect(card.transform == .identity, "card scaled at: \(stage)")
            // The presentation layer too: a CA animation in flight would
            // show here even while the model value reads identity, which is
            // exactly how the drift used to hide from a transform check.
            #expect(media.layer.animation(forKey: "transform") == nil, "media animating at: \(stage)")
        }

        expectStill("engaged")
        cell.willBecomeActive()
        expectStill("active + engaged")

        cell.setCommentsEngaged(false)
        expectStill("disengaged")
        // The interactive dismissal's continuous drive, end to end.
        for progress in stride(from: CGFloat(0), through: 1, by: 0.25) {
            cell.setCommentsEngagementProgress(progress)
            expectStill("progress \(progress)")
        }
        cell.setCommentsEngaged(true)
        expectStill("re-engaged")
        cell.didResignActive(releasingPlayback: true)
        expectStill("resigned")
        cell.prepareForReuse()
        expectStill("reused")
    }

    /// REGRESSION, inverted (phantom tile band): the docked video surface
    /// kept its full-bleed FRAME under the dock's uniform scale — the mask
    /// cropped pixels, not hit-testing — so once z-lifted it ate stream
    /// touches ~65pt above and below the visible square, and an avatar tap
    /// on the first comment row dismissed the whole engagement. The media
    /// is now full-bleed AND at the back of the stack, so EVERY point over
    /// the engaged stream must reach the stream, including points squarely
    /// on the video surface.
    @Test func backgroundMediaNeverStealsStreamTouches() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0000"),
                authorID: ProfileID("profile-1"),
                authorName: "Ava",
                metaText: "@ava · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: URL(string: "mock://media/0.mp4"),
                mediaKind: .video,
                thumbnailURL: nil,
                audioText: "Original audio · @ava"
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()

        let video = try mediaCard(of: cell).renderView
        // The premise: the video surface is full-bleed, so it lies under
        // the whole stream — the exact overlap that used to be a bug.
        #expect(video.frame == cell.contentView.bounds)

        // Every probe down the stream reaches the hosted view, never the
        // media beneath it.
        let partition = SnapCommentsLayout.commentsTopInset(topInset: Self.topInset)
        for y in stride(from: partition + 20, to: Self.container.height - 20, by: 120) {
            let hit = try #require(cell.hitTest(CGPoint(x: Self.container.midX, y: y), with: nil))
            #expect(sequence(first: hit, next: { $0.superview }).contains { $0 === hosted })
        }
    }

    /// Reuse must never leak the mutated layout into the next post.
    @Test func reuseResetsEngagement() throws {
        let cell = makeEngagedCell()
        cell.prepareForReuse()
        #expect(cell.isCommentsEngaged == false)
        let card = try mediaCard(of: cell)
        #expect(card.imageView.transform == .identity)
        #expect(card.transform == .identity)
        #expect(card.clipsToBounds == false)
        try #expect(backdrop(of: cell).dimOpacity == 0)
    }

    /// The chrome canvas is hit-transparent: bare-area touches fall through
    /// to the layers beneath (media, engaged comments), while interactive
    /// subviews (the rail) still claim theirs. Without this, the full-cell
    /// chrome swallowed every drag over the engaged comments region and
    /// handed it to the pager.
    @Test func chromeCanvasIsHitTransparent() throws {
        // A configured media chrome, so the rail is populated and visible
        // (it hides itself on an empty payload — a hidden rail can't anchor
        // the positive half of this test).
        let chrome = SnapChromeView(frame: Self.container)
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-0004"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "caption",
            mediaURL: URL(string: "mock://media/4"),
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.setFixedInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        chrome.layoutIfNeeded()
        // A bare-canvas point (mid-page, far from any chrome subview).
        #expect(chrome.hitTest(CGPoint(x: 60, y: 400), with: nil) == nil)
        // A point inside the shortcut rail still resolves to rail territory
        // (frame-based: the rail is a scroll view, so its bounds origin is
        // parked at the resting inset and doesn't map 1:1 to chrome space).
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let hit = chrome.hitTest(CGPoint(x: rail.frame.midX, y: rail.frame.maxY - 20), with: nil)
        #expect(hit != nil)
        #expect(hit.map { SnapFeedCollectionView.claimsTouches($0) } == true)
    }

    /// The swipe exit's finger-connection curve: odd-symmetric, near-1:1
    /// at small drags, saturating toward ±40 — the bar rides the finger
    /// but never leaves its band.
    @Test func swipeNudgeIsDampedAndSaturating() {
        #expect(CommentsInputBar.nudgeOffset(for: 0) == 0)
        #expect(CommentsInputBar.nudgeOffset(for: -20) == -CommentsInputBar.nudgeOffset(for: 20))
        // Near-linear early…
        let small = CommentsInputBar.nudgeOffset(for: 20)
        #expect(small > 8 && small < 20)
        // …saturating late, monotonically, under the cap.
        let large = CommentsInputBar.nudgeOffset(for: 400)
        #expect(large > CommentsInputBar.nudgeOffset(for: 100))
        #expect(large < 40)
    }

    // MARK: - Engaged card content

    private func makeConfiguredCell(audioText: String?, likeCount: Int64) -> SnapFeedCell {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-0004"),
                authorID: ProfileID("profile-1"),
                authorName: "Ana",
                metaText: "@ana · 3m",
                avatarURL: nil,
                caption: "caption",
                mediaURL: URL(string: "mock://media/4"),
                mediaKind: audioText == nil ? .image : .video,
                thumbnailURL: nil,
                audioText: audioText,
                likeCount: likeCount
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    /// ⚠️ FOUND BY SEARCH, not by depth.
    ///
    /// These used to read `contentView.subviews` directly, which made the
    /// page's nesting part of every assertion about its behaviour: putting the
    /// page's layers inside one frame-managed stage (so a transition can move
    /// them as a single object) failed nine tests that were not about nesting
    /// at all. What each of them means is "the cell has one of these", and that
    /// is what this asks.
    private func firstDescendant<V: UIView>(of view: UIView, ofType: V.Type) -> V? {
        for child in view.subviews {
            if let match = child as? V { return match }
            if let match = firstDescendant(of: child, ofType: V.self) { return match }
        }
        return nil
    }

    /// The media component — the render surfaces live inside it, not as loose
    /// cell subviews.
    private func mediaCard(of cell: SnapFeedCell) throws -> SnapMediaCardView {
        try #require(firstDescendant(of: cell.contentView, ofType: SnapMediaCardView.self))
    }

    /// The readability layer between the media and the stream.
    private func backdrop(of cell: SnapFeedCell) throws -> SnapMediaBackdropView {
        try #require(firstDescendant(of: cell.contentView, ofType: SnapMediaBackdropView.self))
    }

    /// The STREAM's entrance choreography: it fades AND expands into place,
    /// and reverses exactly. The expand moved here from the caption card
    /// when the caption became a scrolling row — the motion belongs to the
    /// The engagement's fade, and WHERE THE SHRINK LIVES.
    ///
    /// The container fades but never transforms: the shrink moved to the
    /// hosted stream so the footer's blur band — which lives inside this
    /// container — keeps its size and seat at the screen's edge. A band that
    /// scales stops reading as chrome. The header band, a sibling, fades on
    /// its own alpha for the same reason it never scaled.
    @Test func theEngagementFadesAndLeavesTheBandsUnscaled() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        let container = try #require(hosted.superview)
        let frost = try #require(
            firstDescendant(of: cell.contentView, ofType: ProgressiveFrostView.self)
        )

        // Offstage: transparent, and NOT transformed.
        #expect(container.alpha == 0)
        #expect(container.transform == .identity)

        cell.setCommentsEngaged(true)
        #expect(container.alpha == 1)
        #expect(container.transform == .identity)
        #expect(frost.alpha == 1)
        #expect(frost.transform == .identity)

        // Disengaged: faded out, still untransformed, band gone with it.
        cell.setCommentsEngaged(false)
        #expect(container.alpha == 0)
        #expect(container.transform == .identity)
        #expect(frost.alpha == 0)
        #expect(frost.transform == .identity)

        // The SHRINK is the stream's, and it is a real interpolation.
        let detail = PostDetailViewController(
            viewModel: PostDetailViewModel(
                postID: PostID("p"), repository: EmptyFeedProvider()
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly
        )
        detail.loadViewIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: detail.view))
        detail.setStreamTransitionProgress(0)
        #expect(stream.transform == .identity)
        detail.setStreamTransitionProgress(1)
        #expect(stream.transform.a == SnapCommentsLayout.streamEntranceScale)
        #expect(stream.transform.a == stream.transform.d) // uniform
        detail.setStreamTransitionProgress(0.5)
        #expect(stream.transform.a > SnapCommentsLayout.streamEntranceScale)
        #expect(stream.transform.a < 1)
    }

    /// The engaged tap boundary: a touch anywhere inside the hosted
    /// comments container — rows, gaps, the composer's band — is a STREAM
    /// touch and must never fire the background tap (which closes the
    /// engagement); touches on the strip's layers stay eligible. The
    /// boundary is the pure walk the delegate uses.
    @Test func streamTouchesNeverCollapseTheEngagement() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
        let row = UIView()
        hosted.addSubview(row)

        #expect(SnapFeedCell.isCommentsStreamTouch(row, stopAt: cell.contentView))
        #expect(SnapFeedCell.isCommentsStreamTouch(hosted, stopAt: cell.contentView))
        // …while the cell's own layers stay outside the stream walk.
        let media = try mediaCard(of: cell).imageView
        #expect(SnapFeedCell.isCommentsStreamTouch(media, stopAt: cell.contentView) == false)
    }

    /// The page-drive swipe's territory is the HEADER BAND — everything
    /// above where the stream's content begins. It used to be the floating
    /// caption card; with the caption scrolling as a list row there is no
    /// stationary card to grab, and below this line a vertical drag has to
    /// scroll the comments instead.
    @Test func pageDriveSwipeRegionIsTheHeaderBand() {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let boundary = SnapCommentsLayout.commentsTopInset(topInset: Self.topInset)
        // The nav zone and the breath under it belong to the drive…
        #expect(cell.cardSwipeRegionContains(CGPoint(x: Self.container.midX, y: 10)))
        #expect(cell.cardSwipeRegionContains(CGPoint(x: Self.container.midX, y: boundary - 2)))
        // …and everything from the stream down does not: those drags scroll
        // the comments, which is the whole point of moving the caption in.
        #expect(cell.cardSwipeRegionContains(CGPoint(x: Self.container.midX, y: boundary + 2)) == false)
        #expect(cell.cardSwipeRegionContains(CGPoint(x: Self.container.midX, y: Self.container.midY)) == false)
        #expect(cell.cardSwipeRegionContains(CGPoint(x: Self.container.midX, y: Self.container.height - 60)) == false)
    }

    /// REGRESSION (feed paralysis): the card's exit pan is DISABLED for
    /// the whole default-feed lifetime — an idle enabled pan on the cell
    /// outranks the pager's own pan and eats every vertical drag, dead
    /// feed. The engagement state is the recognizer's only power switch,
    /// through every teardown path (disengage, reuse), and the begin gate
    /// must be its DELEGATE (UIKit consults the hit-tested view's
    /// `gestureRecognizerShouldBegin`, and feed touches hit deep
    /// subviews — a cell-level override alone never runs for them).
    @Test func cardSwipePanIsScopedToTheEngagementLifecycle() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        configurePost(cell)
        cell.layoutIfNeeded()
        let pan = try #require(cell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        #expect(pan.isEnabled == false)
        #expect(pan.delegate === cell)
        cell.setCommentsEngaged(true)
        #expect(pan.isEnabled == true)
        cell.setCommentsEngaged(false)
        #expect(pan.isEnabled == false)
        cell.setCommentsEngaged(true)
        cell.prepareForReuse()
        #expect(pan.isEnabled == false)
    }

    /// FORMAT PARITY, still structural: a text page and a media page build
    /// the IDENTICAL engaged shell — same chrome-zone boundary, same frost
    /// band, same dead-end lock, same armed page-drive. With the caption
    /// living in the hosted stream, the cell itself carries NO per-format
    /// layout at all; the only difference left between the two pages is
    /// whether anything is visible behind the backdrop.
    @Test func textAndMediaEngagementsBuildTheIdenticalShell() throws {
        func engagedShell(media: Bool) throws -> (SnapFeedCell, UIView) {
            let cell = SnapFeedCell(frame: Self.container)
            cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
            configurePost(cell, media: media)
            cell.layoutIfNeeded()
            let hosted = UIView()
            cell.installComments(hosted)
            cell.setCommentsEngaged(true)
            cell.contentView.layoutIfNeeded()
            return (cell, hosted)
        }

        let (text, textHosted) = try engagedShell(media: false)
        let (media, mediaHosted) = try engagedShell(media: true)

        for (cell, hosted) in [(text, textHosted), (media, mediaHosted)] {
            // No caption in the cell on EITHER format — it belongs to the
            // hosted stream, which is where its row is.
            #expect(cell.contentView.subviews.compactMap { $0 as? CommentRowView }.isEmpty)
            // The stream fills the cell and starts below the chrome zone.
            #expect(hosted.superview?.frame == cell.contentView.bounds)
            #expect(cell.engagedCommentsTopInset(safeAreaTop: Self.topInset)
                == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
            let frost = try #require(
                firstDescendant(of: cell.contentView, ofType: ProgressiveFrostView.self)
            )
            #expect(frost.frame.height == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
            // The dead-end lock and the armed page-drive, both formats.
            #expect(SnapFeedCollectionView.claimsTouches(hosted))
            let pan = try #require(cell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
            #expect(pan.isEnabled == true)
            // The engaged layout owns the FULL width on both formats: the
            // reactions rail (which used to hold a trailing column open) is
            // faded out with the rest of the page chrome.
            let chrome = try #require(
                cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first
            )
            let rail = try #require(
                chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first
            )
            #expect(rail.superview?.alpha == 0) // the chrome carries the fade
        }
    }

    /// `SnapMediaCardView` is HIT-TRANSPARENT: it hosts the surfaces
    /// full-bleed, so its own frame must never eat touches — only its
    /// surfaces are hittable (a self-hit returns nil, falling through to
    /// whatever is beneath). Load-bearing for the background layout too:
    /// a full-bleed view that answered every point would claim the whole
    /// page's background taps.
    @Test func mediaCardIsHitTransparentExceptItsSurfaces() {
        let card = SnapMediaCardView()
        card.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        card.configure(kind: .video) // the render surface hit-tests
        card.layoutIfNeeded()
        // A point on the (full-bleed) video surface hits the surface…
        let onSurface = card.hitTest(CGPoint(x: 195, y: 400), with: nil)
        #expect(onSurface === card.renderView)
        // …but the card never returns ITSELF (image posts, whose surface
        // is hit-inert, fall clean through).
        card.configure(kind: .image)
        card.layoutIfNeeded()
        #expect(card.hitTest(CGPoint(x: 195, y: 400), with: nil) == nil)
    }


    @Test func commentSortButtonKeepsHonestSelectionState() throws {
        let button = SnapCommentSortButton()
        #expect(button.order == .recent)
        let titles = (button.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
        #expect(titles == SnapCommentSortButton.Order.allCases.map(\.rawValue))

        var changes: [SnapCommentSortButton.Order] = []
        button.onOrderChange = { changes.append($0) }
        button.select(.trending)
        #expect(button.order == .trending)
        // Menu rebuilt around the new state: exactly one checkmark, on it.
        let checked = (button.menu?.children ?? [])
            .compactMap { $0 as? UIAction }.filter { $0.state == .on }
        #expect(checked.map(\.title) == ["Trending"])
        // Re-selection is not a change; reset restores the default silently.
        button.select(.trending)
        button.reset()
        #expect(button.order == .recent)
        #expect(changes == [.trending])
    }

    /// The trailing slot's three faces, and the one that changed: the ✕ is
    /// GONE from this bar (the exit moved to the toolbar) and a MICROPHONE
    /// holds the idle slot instead — the affordance a message composer
    /// actually wants there. The page-swipe drive marks a feed engagement;
    /// the pushed comments screen wires none and keeps a permanent send.
    @Test func composerTrailingSlotFollowsKeyboardAndText() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        func button(_ label: String) -> UIButton? {
            bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
        }
        let send = try #require(button("Send comment"))

        // Keyboard closed, empty: the microphone — and NO close affordance
        // anywhere on the bar.
        #expect(button("Record voice comment") != nil)
        #expect(button("Close comments") == nil)
        #expect(send.alpha == 0)

        // Keyboard closed, text drafted: STILL the mic (send needs the
        // keyboard; a parked draft does not claim the slot).
        bar.draftText = "draft"
        #expect(button("Record voice comment") != nil)
        #expect(send.alpha == 0)

        // Keyboard opens over the draft: send takes the slot.
        bar.setKeyboardOpen(true)
        #expect(send.alpha == 1)
        #expect(send.isEnabled)

        // Text cleared with the keyboard up: the dismiss-keyboard face —
        // tapping must retire the keyboard, never the engagement.
        bar.draftText = ""
        #expect(button("Dismiss keyboard") != nil)
        #expect(button("Record voice comment") == nil)
        #expect(send.alpha == 0)

        // Keyboard retires: back to the mic.
        bar.setKeyboardOpen(false)
        #expect(button("Record voice comment") != nil)

        // Pushed screen (no engagement): permanent send, no utility face.
        let pushed = CommentsInputBar()
        let pushedSend = try #require(
            pushed.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Send comment" }
        )
        #expect(pushedSend.alpha == 1)
        pushed.setKeyboardOpen(true)
        #expect(pushedSend.alpha == 1)
    }

    // MARK: - Screen chrome

    /// Builds a feed screen far enough to have real bars, on a nav stack it
    /// can go back from (so the back item exists to be displaced).
    private static func chromeHost() -> (nav: UINavigationController, feed: SnapFeedViewController) {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        // A root beneath it: `isClosable` is what mints the back item, and it
        // is false for a stack root.
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        return (nav, feed)
    }

    private static func leadingLabels(_ feed: SnapFeedViewController) -> [String?] {
        (feed.navigationItem.leftBarButtonItems ?? []).map {
            ($0.customView as? UIButton)?.accessibilityLabel
        }
    }

    /// The FOOTER IS STATE-INVARIANT: ⋯ holds the trailing corner in every
    /// state. It used to swap to a red ✕ while a media post's comments were
    /// open — which meant text and media engagements disagreed about what
    /// that corner meant.
    /// The trailing run is ONE item, so iOS 26 gives it ONE glass platter.
    ///
    /// It reads as an implementation detail and is not: adjacent bar items
    /// share a platter, and a fixed space between them is the only thing that
    /// makes two. Re-introducing a spacer here would silently put the second
    /// bubble back. (Worth knowing before trying: platter COUNT is not what
    /// the hero push is paying for — see `configureToolbarItems` — so do not
    /// split this on the theory that merging it was the performance fix.)
    @Test func theToolbarsTrailingRunIsTwoPlatters() {
        let (_, feed) = Self.chromeHost()
        let items = feed.toolbarItems ?? []
        // [attribution][flexible space][🔖 ⇄][fixed space][⋯]
        //
        // It was one platter holding all three for a while, to save a glass
        // host on the hero flight's push. The arms were then measured and the
        // saving was ~2 ms — inside the noise — so the grouping went back to
        // being a design question. `SnapToolbarCompositionTests` owns the
        // reason; this pins the shape.
        #expect(items.count == 5)
        #expect((items.dropFirst(2).first?.customView as? UIStackView)?.arrangedSubviews.count == 2)
        #expect(items.last?.customView is UIButton)
    }

    /// ⚠️ THE FOOTER'S CORNER KEEPS ITS ⋯ IN EVERY STATE — and the toolbar is
    /// state-invariant again, which is where it started.
    ///
    /// The exit borrowed this corner for a while, on the reading that a bubble
    /// changing glyph is cheaper than a run re-composing. What it actually cost
    /// was the ⋯ itself for as long as the thread was open: Share, Report and
    /// Not interested, gone exactly when a reader is deepest in the post. The
    /// exit lives in the TRAILING NAV slot now (see
    /// `theExitTakesTheAuthorsSlotWhileTheThreadIsOpen`), where what it
    /// displaces has already been read.
    @Test func theFooterCornerKeepsItsMenuInEveryState() throws {
        let (_, feed) = Self.chromeHost()
        let resting = feed.toolbarItems ?? []
        #expect(!resting.isEmpty)
        func cornerLabel() -> String? {
            (feed.toolbarItems?.last?.customView as? UIButton)?.accessibilityLabel
        }
        #expect(cornerLabel() == "More actions")

        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect(cornerLabel() == "More actions")
        #expect(feed.toolbarItems ?? [] == resting)

        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        #expect(feed.toolbarItems ?? [] == resting)

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(feed.toolbarItems ?? [] == resting)
    }

    /// ⚠️ THE EXIT TAKES THE AUTHOR'S SLOT while a media post's thread is open.
    ///
    /// The two are the same kind of thing — the outermost item at the end that
    /// says what the screen is ABOUT — and only one of them is worth the slot
    /// at a time: with the thread open, whose post it is has already been read
    /// and the way back to the picture has not. A TEXT post keeps its author,
    /// because its comments ARE the page and there is nothing to close.
    @Test func theExitTakesTheAuthorsSlotWhileTheThreadIsOpen() throws {
        let (_, feed) = Self.chromeHost()
        func trailingFirst() -> UIView? {
            feed.navigationItem.rightBarButtonItems?.first?.customView
        }
        #expect(trailingFirst() is SnapAuthorIdentityView)

        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect((trailingFirst() as? UIButton)?.accessibilityLabel == "Close comments")

        feed.setEngagedChrome(true, hasMedia: false, animated: false)
        #expect(trailingFirst() is SnapAuthorIdentityView)

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(trailingFirst() is SnapAuthorIdentityView)
    }

    /// A TEXT page's corner never changes: its comments are its resting state,
    /// so a ✕ would promise a media layout that does not exist.
    @Test func aTextPagesCornerKeepsTheMenu() {
        let (_, feed) = Self.chromeHost()
        let resting = feed.toolbarItems ?? []

        feed.setEngagedChrome(true, hasMedia: false, animated: false)

        #expect(feed.toolbarItems ?? [] == resting)
    }

    /// ⚠️ AND THE BACK ARROW KEEPS THE EDGE, in every state.
    ///
    /// The exit used to take this slot on a media post, which cost the screen
    /// its way OUT while the layout was open: leaving the post meant closing
    /// the comments first and then going back — two gestures for one
    /// intention. The two answer different questions (leave the screen vs.
    /// leave the layout) and now have different places to say so.
    ///
    /// The group GROWS around it — the sort joins inboard while the thread is
    /// open — so the assertion is that the arrow is still the item at the
    /// screen's edge, not that the group is untouched.
    @Test func theBackArrowKeepsTheEdgeThroughTheEngagement() throws {
        let (_, feed) = Self.chromeHost()
        let arrow = try #require(feed.navigationItem.leftBarButtonItems?.first)

        for hasMedia in [true, false] {
            feed.setEngagedChrome(true, hasMedia: hasMedia, animated: false)
            #expect(feed.navigationItem.leftBarButtonItems?.first === arrow,
                    Comment(rawValue: "the arrow lost the edge (hasMedia: \(hasMedia))"))
            #expect(!Self.leadingLabels(feed).contains("Close comments"))
        }

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(feed.navigationItem.leftBarButtonItems ?? [] == [arrow])
    }

    /// A TAB-ROOT feed has no back arrow — and still gains the ✕, at the
    /// trailing end. The two answer different questions, and only the second is
    /// always available.
    ///
    /// ⚠️ AND THE SORT STANDS ALONE THERE, with no spacer: the leading group's
    /// fixed space exists to keep the arrow and the sort two pills, and with no
    /// arrow there is nothing to keep apart. A leading run that opened with a
    /// spacer would indent the sort off the screen's edge for no reason.
    @Test func aTabRootFeedWithNoBackArrowStillGetsTheExit() throws {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let nav = UINavigationController(rootViewController: feed) // root: not closable
        _ = nav
        feed.loadViewIfNeeded()
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()
        #expect(feed.navigationItem.leftBarButtonItems ?? [] == [])

        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        #expect((feed.navigationItem.rightBarButtonItems?.first?.customView as? UIButton)?
                    .accessibilityLabel == "Close comments")
        let leading = feed.navigationItem.leftBarButtonItems ?? []
        #expect(leading.count == 1)
        #expect(leading.first?.customView is SnapCommentSortButton)

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(feed.navigationItem.leftBarButtonItems ?? [] == [])
    }

    /// ⚠️ THE SORT SITS BESIDE THE BACK ARROW: [‹ back] [⇅ sort], and
    /// `leftBarButtonItems` is indexed LEFT to right, so the arrow is index 0
    /// and the sort lands inboard of it — separated by the fixed space that
    /// keeps them two pills instead of one shared iOS 26 platter.
    ///
    /// It rode the TRAILING run twice, inboard of the author and then outboard
    /// of the balance, and neither read: the sort is a control over the thread
    /// below, and the trailing end of this bar is where the post's own identity
    /// lives. This end is the one that says what the screen is doing.
    @Test func commentModeAddsTheSortPillBesideTheBackArrow() throws {
        let (_, feed) = Self.chromeHost()
        let resting = feed.navigationItem.leftBarButtonItems ?? []
        #expect(resting.count == 1) // the back arrow alone

        feed.setEngagedChrome(true, hasMedia: true, animated: false)
        let engaged = feed.navigationItem.leftBarButtonItems ?? []
        #expect(engaged.count == 3)
        #expect(engaged[0] === resting.first)   // the arrow keeps the edge
        #expect(engaged[1].customView == nil)   // the fixed space
        #expect(engaged[2].customView is SnapCommentSortButton)
        // …and the trailing run is untouched by the engagement.
        #expect((feed.navigationItem.rightBarButtonItems ?? []).count == 1)

        feed.setEngagedChrome(false, hasMedia: true, animated: false)
        #expect(feed.navigationItem.leftBarButtonItems ?? [] == resting)
    }

    /// ⚠️ THE WHOLE BAR, ENGAGED ON A MEDIA POST: [‹ back] [⇅ sort] ———
    /// [◎ balance] [✕].
    ///
    /// Stated end to end in one place, because the arrangement is the product
    /// decision and it has moved four times: the two groups say different kinds
    /// of thing — what the screen is DOING on the left, what the post IS on the
    /// right — and a rule that only pins one half cannot catch an item crossing
    /// between them. The ✕ is at the right edge because with the thread open
    /// the way back to the picture outranks whose post it is; a TEXT post keeps
    /// its author there, having nothing to close.
    @Test func theEngagedBarReadsBackSortThenBalanceExit() throws {
        let suite = "snap.chrome.order.test"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyFeedProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: WalletStore(defaults: defaults)
        )
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.pushViewController(feed, animated: false)
        feed.loadViewIfNeeded()
        feed.beginAppearanceTransition(true, animated: false)
        feed.endAppearanceTransition()

        feed.setEngagedChrome(true, hasMedia: true, animated: false)

        // LEADING, left to right: the arrow then the sort.
        let leading = feed.navigationItem.leftBarButtonItems ?? []
        #expect(leading.count == 3, "the leading group is [back][space][sort]: \(leading.count)")
        #expect(leading[1].customView == nil) // the fixed space that keeps them two pills
        #expect(leading[2].customView is SnapCommentSortButton)

        // TRAILING, right to left: the exit at the edge, the balance inboard.
        let trailing = feed.navigationItem.rightBarButtonItems ?? []
        #expect(trailing.count == 3, "the trailing run is [✕][space][balance]: \(trailing.count)")
        #expect((trailing[0].customView as? UIButton)?.accessibilityLabel == "Close comments")
        #expect(trailing[1].customView == nil)
        #expect(trailing[2].customView is WalletBadgeButton)
        // Nothing crossed between the groups.
        #expect(trailing.contains { $0.customView is SnapCommentSortButton } == false)
    }

    /// The author pill goes COMPACT so both pills fit the trailing run.
    ///
    /// This is the guard on a width budget, not a style preference: at full
    /// size the run overflowed and iOS 26 hid the WHOLE author item behind a
    /// `•••` menu — the "[sort] [author]" layout silently became "[sort]
    /// [menu]". The compact pill must therefore stay meaningfully narrower
    /// than the resting one, and the meta line and follow "+" are what it
    /// sheds to get there.
    @Test func authorPillCompactsWhenTheSortPillJoinsIt() throws {
        let view = SnapAuthorIdentityView()
        view.setAuthor(
            FeedItemDisplayModel(
                id: PostID("post-1"),
                authorID: ProfileID("profile-1"),
                authorName: "Sam Whitfield",
                metaText: "@sam.whitfield · 28 May",
                avatarURL: nil,
                caption: "a photo",
                mediaURL: URL(string: "https://example.com/a.jpg"),
                mediaKind: .image,
                thumbnailURL: nil,
                audioText: nil
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        func settledWidth() -> CGFloat {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }
        let resting = settledWidth()

        // THE PILL NEVER CHANGES WHAT IT IS. It used to drop the handle line
        // and the follow button for the engagement, which made it a visibly
        // different component in the two states. It pays the bar's width
        // budget in WIDTH now: same two lines, same follow button, same
        // platter — the name truncates earlier, exactly as a long name
        // already does at rest.
        view.setWidthBudget(160)
        let budgeted = settledWidth()
        #expect(budgeted <= 160)
        #expect(budgeted < resting)

        // And it comes back whole.
        view.setWidthBudget(nil)
        #expect(abs(settledWidth() - resting) < 0.5)
    }

    /// The order the trailing run gives way in, rung by rung. The handle
    /// outranks the name, so a budget that only bites into the name leaves
    /// the handle whole — and `widthKeepingHandleWhole` is the threshold
    /// that says when the sort pill should surrender its word instead.
    @Test func theAuthorPillYieldsItsNameBeforeItsHandle() throws {
        let view = SnapAuthorIdentityView()
        view.setAuthor(
            FeedItemDisplayModel(
                id: PostID("post-1"), authorID: ProfileID("profile-1"),
                authorName: "Quentin Dubois", metaText: "@quentin.dubois · 71d",
                avatarURL: nil, caption: "c", mediaURL: URL(string: "mock://media/1"),
                mediaKind: .image, thumbnailURL: nil, audioText: nil
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        view.setNeedsLayout()
        view.layoutIfNeeded()

        // The threshold is everything that is NOT the name: the chrome plus
        // the handle's own width. Above it the name absorbs the squeeze.
        let threshold = view.widthKeepingHandleWhole
        // `<=`, not `<`: this author's handle is WIDER than their name, so
        // the name contributes nothing to the natural width and the two
        // coincide. That is the threshold doing its job, not a miss.
        #expect(threshold > 0)
        #expect(threshold <= ceil(view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width))

        // The name label is the designated absorber; the handle resists.
        func labels(in root: UIView) -> [UILabel] {
            root.subviews.flatMap { [$0 as? UILabel].compactMap { $0 } + labels(in: $0) }
        }
        let found = labels(in: view)
        let name = try #require(found.first { $0.text == "Quentin Dubois" })
        let meta = try #require(found.first { $0.text == "@quentin.dubois · 71d" })
        #expect(
            name.contentCompressionResistancePriority(for: .horizontal)
                < meta.contentCompressionResistancePriority(for: .horizontal)
        )
    }

    /// Rung two: the sort pill trades its word for the glyph, and gives the
    /// reserved width back with it — a pill that kept its footprint would
    /// have bought the author nothing.
    @Test func theSortPillCanSurrenderItsTitleForWidth() {
        let button = SnapCommentSortButton()
        button.setNeedsLayout()
        button.layoutIfNeeded()
        let titled = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        #expect(button.isTitleHidden == false)
        #expect(button.configuration?.attributedTitle != nil)

        button.setTitleHidden(true)
        let glyphOnly = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        #expect(button.isTitleHidden)
        #expect(button.configuration?.attributedTitle == nil)
        #expect(glyphOnly < titled)
        // The glyph alone still announces the control and its current order.
        #expect(button.accessibilityLabel?.contains("Recent") == true)
        // Selection still works, and still says so.
        button.select(.trending)
        #expect(button.accessibilityLabel?.contains("Trending") == true)
        #expect(button.configuration?.attributedTitle == nil)

        // Restored: the title is back AND so is the longest-title floor, so
        // the wider "Trending" is not asked to fit a "Recent"-sized platter.
        button.setTitleHidden(false)
        #expect(button.configuration?.attributedTitle != nil)
        #expect(button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width >= titled - 0.5)
    }

    /// The bar's four slots, in order: the viewer's AVATAR opens it, the
    /// field takes the flexible width, then the mic/send toggle, then "+"
    /// at the trailing edge.
    ///
    /// The "+" used to lead the bar. It moved so the avatar could — a
    /// composer says who is speaking before it offers what to attach — which
    /// also gathers both action controls into one thumb cluster.
    @Test func composerSlotsRunAvatarFieldToggleThenAttach() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        bar.frame = CGRect(x: 0, y: 0, width: 340, height: 38)
        bar.layoutIfNeeded()

        // TWO effect views in the bar now (the avatar's bubble and the
        // field), so identify them by content rather than by order.
        let effects = bar.subviews.compactMap { $0 as? UIVisualEffectView }
        #expect(effects.count == 2)
        let avatar = try #require(
            effects.first { Self.firstView(MonogramAvatarView.self, in: $0) != nil }
        )
        let field = try #require(
            effects.first { Self.firstView(UITextView.self, in: $0) != nil }
        )
        let buttons = bar.subviews.compactMap { $0 as? UIButton }
        let send = try #require(buttons.first { $0.accessibilityLabel == "Send comment" })
        let mic = try #require(buttons.first { $0.accessibilityLabel == "Record voice comment" })
        let attach = try #require(buttons.first { $0.configuration?.image != nil && $0 !== send && $0 !== mic })

        // Leading to trailing, no overlaps — except the toggle pair, which
        // SHARE one slot by design.
        #expect(avatar.frame.minX == 0)
        #expect(field.frame.minX >= avatar.frame.maxX)
        #expect(send.frame.minX >= field.frame.maxX)
        #expect(attach.frame.minX >= send.frame.maxX)
        #expect(attach.frame.maxX == bar.bounds.width)
        #expect(mic.frame == send.frame)

        // Every control keeps a full tap target, and they share the bottom
        // baseline the field grows away from.
        for control in [avatar, send, attach] {
            #expect(control.frame.height == 38)
            #expect(control.frame.maxY == bar.bounds.height)
        }
    }

    /// The avatar is a GLASS BUBBLE, matching the mic and "+" beside it, and
    /// the whole 38pt bubble is the tap target — not just the 30pt face,
    /// which would leave the glass rim dead and the target under the 44pt
    /// guidance by even more than it already is.
    @Test func composerAvatarSitsInAnInteractiveGlassBubble() throws {
        let bar = CommentsInputBar()
        bar.frame = CGRect(x: 0, y: 0, width: 340, height: 38)
        bar.layoutIfNeeded()

        let bubble = try #require(
            bar.subviews.compactMap { $0 as? UIVisualEffectView }
                .first { Self.firstView(MonogramAvatarView.self, in: $0) != nil }
        )
        // Capsule via the corner CONFIGURATION, the house rule for glass —
        // never `layer.cornerRadius` + `clipsToBounds`.
        #expect(bubble.cornerConfiguration != nil)
        let face = try #require(Self.firstView(MonogramAvatarView.self, in: bubble))
        #expect(face.bounds.width == 30)
        #expect(bubble.bounds.width == 38)

        // The button spans the bubble and lives in the CONTENT view (adding
        // it to the effect view itself raises).
        let button = try #require(Self.firstView(UIButton.self, in: bubble))
        #expect(button.superview === bubble.contentView)
        #expect(button.bounds.size == bubble.bounds.size)
        #expect(button.showsMenuAsPrimaryAction)
    }

    /// The switcher menu arms the face and nothing else does: with no menu
    /// the button is disabled, so a host that wires no switcher (the pushed
    /// comments screen) can't present an empty one.
    @Test func profileMenuArmsTheAvatarAndNilDisarmsIt() throws {
        let bar = CommentsInputBar()
        let button = try #require(
            Self.firstView(UIButton.self, in: bar.subviews.compactMap { $0 as? UIVisualEffectView }
                .first { Self.firstView(MonogramAvatarView.self, in: $0) != nil }!)
        )
        #expect(button.isEnabled == false)
        #expect(button.menu == nil)

        bar.setProfileMenu(UIMenu(children: [UIAction(title: "Ava") { _ in }]))
        #expect(button.isEnabled)
        #expect(button.menu != nil)

        bar.setProfileMenu(nil)
        #expect(button.isEnabled == false)
        #expect(button.menu == nil)
    }

    /// The disc is never blank: before any identity resolves the bar already
    /// wears the unknown-viewer monogram, which is the whole point of
    /// "the monogram is the rendered state".
    @Test func composerAvatarIsNeverAnEmptyDisc() {
        let bar = CommentsInputBar()
        #expect(Self.monogramText(in: bar) == "?")
        #expect(Self.avatarImage(in: bar) == nil)
    }

    /// The composer's avatar follows the app-wide contract: the monogram is
    /// the rendered identity (drawn on the configuring frame), the picture
    /// layers over it, and an unknown viewer keeps a neutral disc rather
    /// than borrowing anyone's face.
    @Test func composerAvatarRendersTheViewerMonogramImmediately() async throws {
        let bar = CommentsInputBar()

        // Unknown viewer: the placeholder, never a stranger's initials.
        bar.setViewerIdentity(nil, imagePipeline: nil)
        #expect(Self.monogramText(in: bar) == "?")
        #expect(Self.avatarImage(in: bar) == nil)

        // Identity resolves: initials NOW, picture when the fetch lands.
        let gate = GateddImageFetcher()
        bar.setViewerIdentity(
            ViewerIdentity(name: "Ava Moreau", avatarURL: URL(string: "mock://avatar/me")!),
            imagePipeline: ImagePipeline(fetcher: gate)
        )
        #expect(Self.monogramText(in: bar) == "AM")
        #expect(Self.avatarImage(in: bar) == nil)
        await gate.release()
        await settle()
        #expect(Self.avatarImage(in: bar) != nil)
    }

    /// THE FOUR WAYS THERE IS NO PICTURE, in one place: no URL, no pipeline,
    /// a fetch still in flight, and a fetch that failed. All four land on the
    /// same outcome — the monogram, already drawn — so the bar never shows a
    /// blank disc, a spinner, or a broken-image state.
    @Test func composerAvatarFallsBackToInitialsOnEveryFailurePath() async {
        let name = "Ava Moreau"
        let url = URL(string: "mock://avatar/me")!

        // 1. An identity with no avatar at all.
        let noURL = CommentsInputBar()
        noURL.setViewerIdentity(
            ViewerIdentity(name: name, avatarURL: nil),
            imagePipeline: ImagePipeline(fetcher: GateddImageFetcher(openFrom: true))
        )
        await settle()
        #expect(Self.monogramText(in: noURL) == "AM")
        #expect(Self.avatarImage(in: noURL) == nil)

        // 2. A URL but no pipeline to load it with.
        let noPipeline = CommentsInputBar()
        noPipeline.setViewerIdentity(ViewerIdentity(name: name, avatarURL: url), imagePipeline: nil)
        await settle()
        #expect(Self.monogramText(in: noPipeline) == "AM")
        #expect(Self.avatarImage(in: noPipeline) == nil)

        // 3. Still loading — the readable state is on screen meanwhile.
        let loading = CommentsInputBar()
        loading.setViewerIdentity(
            ViewerIdentity(name: name, avatarURL: url),
            imagePipeline: ImagePipeline(fetcher: GateddImageFetcher())
        )
        await settle()
        #expect(Self.monogramText(in: loading) == "AM")
        #expect(Self.avatarImage(in: loading) == nil)

        // 4. The fetch failed outright.
        let failed = CommentsInputBar()
        failed.setViewerIdentity(
            ViewerIdentity(name: name, avatarURL: url),
            imagePipeline: ImagePipeline(fetcher: FailingImageFetcher())
        )
        await settle()
        #expect(Self.monogramText(in: failed) == "AM")
        #expect(Self.avatarImage(in: failed) == nil)
    }

    /// The composer is re-identified per engagement, so it needs the rows'
    /// reuse guard: a slow fetch for one viewer must never land on the next.
    @Test func composerAvatarRefusesAStaleFetch() async throws {
        let gate = GateddImageFetcher()
        let pipeline = ImagePipeline(fetcher: gate)
        let bar = CommentsInputBar()

        bar.setViewerIdentity(
            ViewerIdentity(name: "Ava Moreau", avatarURL: URL(string: "mock://avatar/ava")!),
            imagePipeline: pipeline
        )
        // Re-identified onto someone with no picture before the first
        // fetch completes — the disc must stay bare.
        bar.setViewerIdentity(ViewerIdentity(name: "Bo Chen", avatarURL: nil), imagePipeline: pipeline)
        #expect(Self.monogramText(in: bar) == "BC")

        await gate.release()
        await settle()
        #expect(Self.avatarImage(in: bar) == nil)
    }

    /// The monogram rule, at its edges — the comment stream's rule applied
    /// to the viewer (first letters of the first two words).
    @Test func composerMonogramMatchesTheStreamRule() {
        #expect(CommentsInputBar.monogram("Ava Moreau") == "AM")
        #expect(CommentsInputBar.monogram("ava moreau nguyen") == "AM")
        #expect(CommentsInputBar.monogram("Ava") == "A")
        #expect(CommentsInputBar.monogram("") == "?")
        #expect(CommentsInputBar.monogram(nil) == "?")
    }

    /// TEXT-POST parity: a text engagement wires the page-swipe drive and
    /// nothing else, and its bar must behave exactly like a media post's —
    /// the mic when idle, the dismiss chevron with the keyboard up over an
    /// empty field, send the moment text is entered. (Before the ✕ left the
    /// bar this was an edge case, because text posts had no close handler
    /// to key off; the mic made both formats one path.)
    @Test func textPostBarMatchesTheMediaBar() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in } // feed engagement, text post
        let buttons = bar.subviews.compactMap { $0 as? UIButton }
        let send = try #require(buttons.first { $0.accessibilityLabel == "Send comment" })
        let utility = try #require(buttons.first { $0.accessibilityLabel == "Record voice comment" })

        // Keyboard down: the mic owns the slot, exactly as on media.
        #expect(utility.alpha == 1)
        #expect(send.alpha == 0)

        // Keyboard up over an empty field: the dismiss-keyboard face.
        bar.setKeyboardOpen(true)
        #expect(utility.accessibilityLabel == "Dismiss keyboard")
        #expect(utility.alpha == 1)
        #expect(send.alpha == 0)

        // Text entered: swaps back to send.
        bar.draftText = "hi"
        #expect(send.alpha == 1)
        #expect(send.isEnabled)
        #expect(utility.alpha == 0)
        // Cleared with the keyboard still up: back to the dismiss face.
        bar.draftText = ""
        #expect(utility.accessibilityLabel == "Dismiss keyboard")
        #expect(utility.alpha == 1)
        #expect(send.alpha == 0)

        // …and back to the mic once the keyboard retires.
        bar.setKeyboardOpen(false)
        #expect(utility.accessibilityLabel == "Record voice comment")
        #expect(utility.alpha == 1)
    }

    /// The 2-level thread order: each top-level comment immediately
    /// followed by its replies oldest-first; orphaned replies (parent not
    /// in the page) are dropped, never stranded at the wrong depth.
    @Test func commentThreadingInterleavesRepliesUnderParents() {
        func view(_ id: String, parent: String = "", age: Int64 = 0) -> Comment_V1_CommentView {
            var v = Comment_V1_CommentView()
            v.commentID = id
            v.parentID = parent
            v.createdAtMs = age
            return v
        }
        let thread = CommentsRepository.threaded(
            topLevel: [view("a"), view("b"), view("c")],
            repliesByParent: [
                "a": [view("a-r1", parent: "a", age: 200), view("a-r0", parent: "a", age: 100)],
                "c": [view("c-r0", parent: "c", age: 50)],
                "ghost": [view("ghost-r0", parent: "ghost")],
            ]
        )
        #expect(thread.map(\.commentID) == ["a", "a-r0", "a-r1", "b", "c", "c-r0"])
    }

    /// A reply's display model carries the level-2 marker, and its row
    /// steps in by the standard reply indent while a parent row fills the
    /// width — the indent is the depth cue.
    @Test func replyRowsIndentByOneAvatarColumn() throws {
        let parentEntry = CommentEntry(
            id: "c0", authorID: ProfileID("p1"), authorName: "Ana Reyes",
            authorHandle: "ana", body: "parent", createdAt: Date()
        )
        let replyEntry = CommentEntry(
            id: "c0-r0", authorID: ProfileID("p2"), authorName: "Bo Chen",
            authorHandle: "bo", body: "reply", createdAt: Date(), parentID: "c0"
        )
        let parentModel = CommentDisplayModel(entry: parentEntry)
        let replyModel = CommentDisplayModel(entry: replyEntry)
        #expect(parentModel.isReply == false)
        #expect(replyModel.isReply == true)

        func settledRow(_ model: CommentDisplayModel) throws -> CGRect {
            let row = CommentRowView(model: model)
            row.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
            row.layoutIfNeeded()
            return try #require(row.subviews.first { $0 is UIStackView }).frame
        }
        #expect(try settledRow(parentModel).minX == 0)
        #expect(try settledRow(replyModel).minX == CommentRowView.replyIndent)
    }

    // MARK: - Comment avatars

    /// Initials are the RENDERED state, not a loading state: two letters,
    /// drawn SYNCHRONOUSLY at configure time, before any fetch exists. A
    /// row is fully readable on the frame it appears.
    @Test func commentRowsRenderTwoLetterInitialsImmediately() throws {
        let model = CommentDisplayModel(entry: CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ava Moreau",
            authorHandle: "ava", body: "hi", createdAt: Date()
        ))
        #expect(model.monogram == "AM")
        // A one-word name still yields something; a mid-name never yields
        // three letters (the disc is sized for two).
        #expect(CommentDisplayModel(entry: CommentEntry(
            id: "c2", authorID: ProfileID("p"), authorName: "Prince",
            authorHandle: "p", body: "b", createdAt: Date()
        )).monogram == "P")
        #expect(CommentDisplayModel(entry: CommentEntry(
            id: "c3", authorID: ProfileID("p"), authorName: "Ana Lucia Reyes Diaz",
            authorHandle: "a", body: "b", createdAt: Date()
        )).monogram == "AL")

        // No pipeline at all — the disc still carries the initials.
        let row = CommentRowView()
        row.configure(with: model)
        #expect(monogramText(in: row) == "AM")
        #expect(avatarImage(in: row) == nil)
    }

    /// The URL travels: `comment.v1` carries no picture, so the repository
    /// hydrates one from profile.v1 onto the ENTRY — and the display model
    /// must actually forward it. It was dropped here for the whole life of
    /// the comments surface, which is why the rows had nothing to load.
    @Test func commentDisplayModelForwardsTheHydratedAvatarURL() {
        let url = URL(string: "mock://avatar/1")!
        let entry = CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ava Moreau",
            authorHandle: "ava", authorAvatarURL: url, body: "hi", createdAt: Date()
        )
        #expect(CommentDisplayModel(entry: entry).avatarURL == url)
        // Absent is a first-class outcome, not an error.
        #expect(CommentDisplayModel(entry: CommentEntry(
            id: "c2", authorID: ProfileID("p"), authorName: "Bo Chen",
            authorHandle: "bo", body: "b", createdAt: Date()
        )).avatarURL == nil)
    }

    /// The caption row aligns to the COMMENT rows, to the point: same
    /// avatar diameter, same gap. That alignment is the whole reason the
    /// caption reads as the thread's first message instead of a header
    /// pasted above it — the bubble's glass is the only thing setting it
    /// apart. It also carries the same async-avatar contract: monogram
    /// first, picture over it, and an id guard so a recycled row can't
    /// catch the previous post's face.
    @Test func theCaptionRowIsAMessageInTheSameColumnAsTheComments() async throws {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 374, height: 120))
        let post = Self.post(caption: "Weekend build log.", avatar: URL(string: "mock://avatar/9"))
        cell.configure(with: post, imagePipeline: nil)
        cell.layoutIfNeeded()

        // The avatar column matches the comment rows' exactly — trivially now
        // that the caption IS a comment row, which is the point of the change.
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        #expect(avatar.bounds.width == CommentRowView.avatarSize)
        let caption = try #require(
            Self.firstView(UILabel.self, in: cell, matching: { $0.text == "Weekend build log." })
        )
        #expect(abs(caption.convert(caption.bounds, to: cell).minX
                    - (avatar.frame.maxX + CommentRowView.avatarGap)) < 0.5)

        // Initials render immediately; no picture without a pipeline.
        #expect(Self.monogramText(in: cell) == post.avatarMonogram)
        #expect(Self.avatarImage(in: cell) == nil)

        // The picture lands over the monogram when one is available…
        let open = ImagePipeline(fetcher: GateddImageFetcher(openFrom: true))
        cell.configure(with: post, imagePipeline: open)
        await settle()
        #expect(Self.avatarImage(in: cell) != nil)
        #expect(Self.monogramText(in: cell) == post.avatarMonogram)

        // …and a recycled row never catches it.
        let gate = GateddImageFetcher()
        let slow = ImagePipeline(fetcher: gate)
        cell.prepareForReuse()
        #expect(Self.avatarImage(in: cell) == nil)
        cell.configure(with: post, imagePipeline: slow)
        cell.prepareForReuse()
        cell.configure(
            with: Self.post(caption: "A different post entirely.", avatar: nil, id: "post-0002"),
            imagePipeline: slow
        )
        await gate.release()
        await settle()
        #expect(Self.avatarImage(in: cell) == nil)
    }

    /// ⚠️ EVERY POST WEARS THE COMMENT ROW — text and media alike.
    ///
    /// This has changed twice. It was two faces (a glass bubble for media, the
    /// gallery card's flat content for text), then one bubble for both, and now
    /// no bubble at all: the caption is the thread's first message, so it is
    /// drawn with the thread's own row. `PostCaptionFaceSpecTests` states the
    /// shape from the reader's side; this keeps the check where the old ones
    /// were, so the change is legible in the history of this file.
    @Test func everyPostsCaptionIsTheCommentRow() throws {
        for hasMedia in [true, false] {
            let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 402, height: 120))
            cell.configure(
                with: Self.post(
                    caption: "Shipping the new build tonight.", avatar: nil, hasMedia: hasMedia
                ),
                imagePipeline: nil,
                likeCount: 40
            )
            cell.layoutIfNeeded()

            let row = try #require(Self.firstView(CommentRowView.self, in: cell))
            #expect(!Self.isEffectivelyHidden(row))
            let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
            #expect(!Self.isEffectivelyHidden(avatar))
            // And no material anywhere: a bubble is what this stopped being.
            #expect(Self.allViews(UIVisualEffectView.self, in: cell).isEmpty)
        }
    }


    /// Absent is not zero: a page whose opener knew no count shows the header
    /// alone, exactly as a comment with no likes does.
    @Test func aCaptionRowWithNoKnownCountShowsNoCounter() throws {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 402, height: 120))
        cell.configure(
            with: Self.post(caption: "Shipping the new build tonight.", avatar: nil, hasMedia: false),
            imagePipeline: nil,
            likeCount: nil
        )
        cell.layoutIfNeeded()

        let counter = try #require(Self.firstView(UIButton.self, in: cell))
        #expect(counter.configuration?.attributedTitle == nil)
    }

    /// The caption row takes NO comment interactions — no reply tap, no
    /// context menu, no like control — while the avatar keeps its own tap. It
    /// wears the comment's shape; it does not inherit its affordances.
    @Test func theCaptionRowIsInertExceptForItsAvatar() throws {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 374, height: 120))
        cell.configure(with: Self.post(caption: "Weekend build log.", avatar: nil), imagePipeline: nil)
        cell.layoutIfNeeded()

        let row = try #require(Self.firstView(CommentRowView.self, in: cell))
        #expect(row.gestureRecognizers?.allSatisfy { !$0.isEnabled } ?? true)
        #expect(row.interactions.contains { $0 is UIContextMenuInteraction } == false)
        let counter = try #require(Self.firstView(UIButton.self, in: cell))
        #expect(counter.isUserInteractionEnabled == false)

        // …while the avatar keeps exactly its own. (The cell's contentView is
        // not asserted: UIKit puts its own recognizers there.)
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        #expect(avatar.gestureRecognizers?.count == 1)

        var profiles = 0
        cell.onAvatarTap = { profiles += 1 }
        cell.onAvatarTap?()
        #expect(profiles == 1)
    }

    /// MEDIA by default. The format no longer changes the caption's FACE —
    /// every post is drawn with the comment row — but it still changes the page
    /// around it, so both are exercised.
    private static func post(
        caption: String, avatar: URL?, id: String = "post-0001", hasMedia: Bool = true
    ) -> PostDetailDisplayModel {
        PostDetailDisplayModel(entry: FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("p1"), caption: caption,
                attachments: hasMedia ? [MediaAttachment(
                    url: URL(string: "mock://photo/0"),
                    thumbnailURL: URL(string: "mock://poster/0"),
                    mimeType: "image/jpeg",
                    pixelWidth: 1080,
                    pixelHeight: 1080
                )] : [],
                publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p1"), handle: "ava", displayName: "Ava Moreau",
                avatarURL: avatar
            )
        ))
    }

    /// Hidden by itself or by any ancestor up to `root` — the question a
    /// toggled face has to answer, since neither view is ever removed.
    private static func isEffectivelyHidden(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden { return true }
            node = current.superview
        }
        return false
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

    private static func firstView<T: UIView>(
        _ type: T.Type, in root: UIView, matching predicate: (T) -> Bool
    ) -> T? {
        allViews(type, in: root).first(where: predicate)
    }

    private static func firstView<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let match = view as? T { return match }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func monogramText(in root: UIView) -> String? {
        firstView(MonogramAvatarView.self, in: root)?
            .subviews.compactMap { $0 as? UILabel }.first?.text
    }

    private static func avatarImage(in root: UIView) -> UIImage? {
        firstView(AvatarImageView.self, in: root)?.image
    }

    /// THE REUSE CONTRACT, exercised as the bug it prevents: a row starts a
    /// slow fetch for one author, gets recycled onto another comment, and
    /// the first fetch only then completes. The late image must not land —
    /// the wrong person's face on a stranger's comment is the failure mode.
    ///
    /// Both recycling sequences are covered, because they are not the same
    /// path: going through `prepareForReuse` cancels the task, while a
    /// straight re-`configure` (the collection view reusing a still-live
    /// cell) relies on the identity check. The row keeps both guards for
    /// that reason — the shipped chat-inbox pattern.
    @Test func aRecycledRowNeverCatchesThePreviousAuthorsFace() async throws {
        let slow = URL(string: "mock://avatar/slow")!
        func stale(_ id: String) -> CommentDisplayModel {
            CommentDisplayModel(entry: CommentEntry(
                id: id, authorID: ProfileID("p1"), authorName: "Ava Moreau",
                authorHandle: "ava", authorAvatarURL: slow, body: "b", createdAt: Date()
            ))
        }
        func faceless(_ id: String) -> CommentDisplayModel {
            CommentDisplayModel(entry: CommentEntry(
                id: id, authorID: ProfileID("p2"), authorName: "Bo Chen",
                authorHandle: "bo", body: "b", createdAt: Date()
            ))
        }

        for viaPrepareForReuse in [true, false] {
            let gate = GateddImageFetcher()
            let pipeline = ImagePipeline(fetcher: gate)
            let row = CommentRowView()
            row.configure(with: stale("first"), imagePipeline: pipeline)

            // Recycled onto a DIFFERENT comment whose author has no
            // picture — the disc must stay bare.
            if viaPrepareForReuse { row.prepareForReuse() }
            row.configure(with: faceless("second"), imagePipeline: pipeline)
            #expect(monogramText(in: row) == "BC")

            // Only NOW does the first author's fetch finish.
            await gate.release()
            await settle()
            #expect(avatarImage(in: row) == nil)
            #expect(monogramText(in: row) == "BC")
        }
    }

    /// The happy path, and the contract's shape: the picture arrives and is
    /// drawn OVER the monogram, never swapped for it — so the disc is never
    /// empty, at any point, and a failed fetch degrades to exactly what was
    /// already on screen.
    @Test func theAvatarLandsOverTheMonogramAndFailureLeavesIt() async throws {
        let pipeline = ImagePipeline(fetcher: GateddImageFetcher(openFrom: true))
        let row = CommentRowView()
        row.configure(with: CommentDisplayModel(entry: CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ava Moreau",
            authorHandle: "ava", authorAvatarURL: URL(string: "mock://avatar/1")!,
            body: "b", createdAt: Date()
        )), imagePipeline: pipeline)
        await settle()
        #expect(avatarImage(in: row) != nil)
        #expect(monogramText(in: row) == "AM") // still there, underneath

        // A FAILING fetch is indistinguishable from no avatar at all.
        let failing = ImagePipeline(fetcher: FailingImageFetcher())
        let row2 = CommentRowView()
        row2.configure(with: CommentDisplayModel(entry: CommentEntry(
            id: "c2", authorID: ProfileID("p2"), authorName: "Bo Chen",
            authorHandle: "bo", authorAvatarURL: URL(string: "mock://avatar/2")!,
            body: "b", createdAt: Date()
        )), imagePipeline: failing)
        await settle()
        #expect(avatarImage(in: row2) == nil)
        #expect(monogramText(in: row2) == "BC")
    }

    /// The cell owns ONE row for its lifetime and re-points it — it does
    /// not rebuild a view tree, two gesture recognizers, and a context-menu
    /// interaction for every row that scrolls past. `prepareForReuse` is
    /// the seam that lets the row drop its fetch and its stale handlers.
    @Test func theCommentCellReusesItsRowAndResetsItOnRecycle() throws {
        let cell = CommentCell(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        let row = cell.row
        let model = CommentDisplayModel(entry: CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ava Moreau",
            authorHandle: "ava", body: "b", createdAt: Date()
        ))
        row.configure(with: model)
        row.onAvatarTap = {}
        #expect(monogramText(in: row) == "AM")

        cell.prepareForReuse()
        #expect(cell.row === row)            // same instance, not rebuilt
        #expect(row.onAvatarTap == nil)      // stale seams dropped
        #expect(avatarImage(in: row) == nil)

        // And it re-points cleanly, including switching thread depth.
        let reply = CommentDisplayModel(entry: CommentEntry(
            id: "c2", authorID: ProfileID("p2"), authorName: "Bo Chen",
            authorHandle: "bo", body: "b", createdAt: Date(), parentID: "c1"
        ))
        row.configure(with: reply)
        row.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        row.layoutIfNeeded()
        #expect(monogramText(in: row) == "BC")
        let stack = try #require(row.subviews.first { $0 is UIStackView })
        #expect(stack.frame.minX == CommentRowView.replyIndent)
    }

    /// The monogram label inside the row's identity disc.
    private func monogramText(in row: CommentRowView) -> String? {
        var stack: [UIView] = [row]
        while let view = stack.popLast() {
            if view is MonogramAvatarView {
                return view.subviews.compactMap { $0 as? UILabel }.first?.text
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The picture layered over that disc, if one has landed.
    private func avatarImage(in row: CommentRowView) -> UIImage? {
        var stack: [UIView] = [row]
        while let view = stack.popLast() {
            if let image = view as? AvatarImageView { return image.image }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Lets the row's detached avatar task run to completion. Yields rather
    /// than sleeping — a fixed sleep is the flake this suite has been bitten
    /// by before.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// The fold's two faces: a collapsed popular thread shows the
    /// threshold's worth of replies plus the view-more seam; expansion
    /// shows the pool WITH the collapse seam at the block's bottom; small
    /// threads never grow either seam — and removing the parent from the
    /// expanded set folds the thread back exactly.
    @Test func threadPresentationTruncatesPopularThreads() {
        func model(_ id: String, parent: String? = nil) -> CommentDisplayModel {
            CommentDisplayModel(entry: CommentEntry(
                id: id, authorID: ProfileID("p"), authorName: "Ana", authorHandle: "ana",
                body: "b", createdAt: Date(timeIntervalSince1970: 0), parentID: parent
            ))
        }
        let models = [
            model("a"),
            model("a-r0", parent: "a"), model("a-r1", parent: "a"),
            model("a-r2", parent: "a"), model("a-r3", parent: "a"),
            model("b"),
            model("b-r0", parent: "b"),
        ]

        let collapsed = CommentThreadPresentation.items(from: models, expanded: [])
        #expect(collapsed == [
            .comment(models[0]), .comment(models[1]), .comment(models[2]),
            .viewMoreReplies(parentID: "a", hiddenCount: 2),
            .comment(models[5]), .comment(models[6]),
        ])

        let expanded = CommentThreadPresentation.items(from: models, expanded: ["a"])
        #expect(expanded == [
            .comment(models[0]), .comment(models[1]), .comment(models[2]),
            .comment(models[3]), .comment(models[4]),
            .collapseReplies(parentID: "a"),
            .comment(models[5]), .comment(models[6]),
        ])

        // The fold is a pure function of the set: removing the parent
        // restores the collapsed shape byte-identically.
        #expect(CommentThreadPresentation.items(from: models, expanded: []) == collapsed)
    }

    /// The header's like control: far-right on the name/time axis, count
    /// shown only when real, filled state on demand — session-local
    /// optimistic (no comment-like API yet).
    @Test func commentRowLikeControlRendersState() throws {
        let model = CommentDisplayModel(entry: CommentEntry(
            id: "c1", authorID: ProfileID("p1"), authorName: "Ana Reyes",
            authorHandle: "ana", body: "body", createdAt: Date()
        ))
        let row = CommentRowView(model: model)
        var stack: [UIView] = [row]
        var like: UIButton?
        while let view = stack.popLast() {
            if let button = view as? UIButton, button.accessibilityLabel == "Like comment" { like = button }
            stack.append(contentsOf: view.subviews)
        }
        let button = try #require(like)
        #expect(button.configuration?.attributedTitle == nil) // bare heart at zero
        row.setLiked(true, count: 1)
        #expect(button.configuration?.attributedTitle.map { String($0.characters) } == "1")
        row.setLiked(false, count: 0)
        #expect(button.configuration?.attributedTitle == nil)

        // Right-aligned on the header axis: after layout, the control's
        // trailing sits at the row's trailing edge.
        row.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        row.layoutIfNeeded()
        let frameInRow = button.superview!.convert(button.frame, to: row)
        #expect(abs(frameInRow.maxX - 320) < 1)
    }

    /// The composer's placeholder label — found by ELIMINATION rather than by
    /// matching its text, so it is still found when the copy changes.
    private static func placeholderText(in bar: UIView) -> String? {
        var stack: [UIView] = [bar]
        while let view = stack.popLast() {
            // The text view carries its own (empty) label; the placeholder is
            // the standalone one.
            if let label = view as? UILabel, !(label.superview is UITextView) {
                return label.text
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The placeholder NAMES the viewer, and re-names them on a switch.
    ///
    /// It matters on this bar specifically: the avatar beside it can change
    /// which of your profiles is speaking, and a picture alone is a weak
    /// answer to "who am I posting as".
    @Test func placeholderNamesTheViewerAndFollowsAProfileSwitch() {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        #expect(Self.placeholderText(in: bar) == "Add a comment…")

        bar.setViewerIdentity(ViewerIdentity(name: "Ava Moreau", avatarURL: nil), imagePipeline: nil)
        #expect(Self.placeholderText(in: bar) == "Comment as Ava Moreau")

        // The switcher lands a new identity: the prompt follows the face.
        bar.setViewerIdentity(ViewerIdentity(name: "Demo Viewer", avatarURL: nil), imagePipeline: nil)
        #expect(Self.placeholderText(in: bar) == "Comment as Demo Viewer")

        // An unresolvable viewer falls back rather than naming nobody.
        bar.setViewerIdentity(nil, imagePipeline: nil)
        #expect(Self.placeholderText(in: bar) == "Add a comment…")
    }

    /// REPLYING WINS the slot: the target of a reply is the more urgent fact,
    /// and the avatar keeps answering "as whom". Clearing the reply returns
    /// to the viewer's name — not to the generic prompt, which would read as
    /// having forgotten who is posting.
    @Test func replyTargetOutranksTheViewerNameInThePlaceholder() {
        let bar = CommentsInputBar()
        bar.setViewerIdentity(ViewerIdentity(name: "Ava Moreau", avatarURL: nil), imagePipeline: nil)
        #expect(Self.placeholderText(in: bar) == "Comment as Ava Moreau")

        bar.setReplyPlaceholder(name: "Kenji Tanaka")
        #expect(Self.placeholderText(in: bar) == "Reply to Kenji Tanaka…")

        // A switch made mid-reply must not steal the slot back.
        bar.setViewerIdentity(ViewerIdentity(name: "Demo Viewer", avatarURL: nil), imagePipeline: nil)
        #expect(Self.placeholderText(in: bar) == "Reply to Kenji Tanaka…")

        bar.setReplyPlaceholder(name: nil)
        #expect(Self.placeholderText(in: bar) == "Comment as Demo Viewer")
    }

    /// The composer's reply state: the placeholder names the target and
    /// restores on clear; an idle keyboard dismissal (empty field) fires
    /// the host's reset seam, a drafted one does not.
    @Test func composerReplyStateSwapsPlaceholderAndResetsOnIdleDismiss() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        func placeholder() -> String? { Self.placeholderText(in: bar) }

        // No viewer resolved: the generic prompt is the floor.
        #expect(placeholder() == "Add a comment…")
        bar.setReplyPlaceholder(name: "Ana Reyes")
        #expect(placeholder() == "Reply to Ana Reyes…")

        var resets = 0
        bar.onIdleDismiss = { resets += 1 }
        // Drafted dismissal keeps the reply state armed…
        bar.setKeyboardOpen(true)
        bar.draftText = "half a thought"
        bar.setKeyboardOpen(false)
        #expect(resets == 0)
        // …an idle dismissal resets it.
        bar.setKeyboardOpen(true)
        bar.draftText = ""
        bar.setKeyboardOpen(false)
        #expect(resets == 1)

        bar.setReplyPlaceholder(name: nil)
        #expect(placeholder() == "Add a comment…")
    }

    /// A TEXT page's ground follows the system appearance; a MEDIA page's
    /// stays black, because black is what letterboxing should be.
    @Test func textPagesTakeAnAdaptiveGroundAndMediaPagesStayBlack() throws {
        func cell(media: Bool) -> SnapFeedCell {
            let cell = SnapFeedCell(frame: Self.container)
            cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
            cell.configure(
                with: FeedItemDisplayModel(
                    id: PostID(media ? "post-media" : "post-text"),
                    authorID: ProfileID("profile-1"),
                    authorName: "Ana",
                    metaText: "@ana · 3m",
                    avatarURL: nil,
                    caption: "a caption",
                    mediaURL: media ? URL(string: "mock://media/1") : nil,
                    mediaKind: .image,
                    thumbnailURL: nil,
                    audioText: nil
                ),
                pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                videoPlayback: nil
            )
            return cell
        }

        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        // Media: black in BOTH appearances — a fixed colour, not a dynamic one.
        let mediaGround = try #require(cell(media: true).contentView.backgroundColor)
        #expect(mediaGround.resolvedColor(with: light) == UIColor.black)
        #expect(mediaGround.resolvedColor(with: dark) == UIColor.black)

        // Text: genuinely dynamic — the two appearances must differ, which is
        // what a hardcoded colour could never satisfy.
        let textGround = try #require(cell(media: false).contentView.backgroundColor)
        #expect(textGround.resolvedColor(with: light) != textGround.resolvedColor(with: dark))
        #expect(textGround.resolvedColor(with: light) == UIColor.systemBackground.resolvedColor(with: light))

        // Reuse must not strand the adaptive ground under an incoming photo.
        let recycled = cell(media: false)
        recycled.prepareForReuse()
        #expect(recycled.contentView.backgroundColor?.resolvedColor(with: light) == UIColor.black)
    }

    /// The readability wash is FOR MEDIA. Pouring 50% black over a text
    /// page's own ground was invisible while that ground was black; with an
    /// adaptive ground it would read as flat grey in light mode.
    @Test func theReadabilityWashSkipsTextPages() throws {
        func engagedBackdropOpacity(media: Bool) throws -> CGFloat {
            let cell = SnapFeedCell(frame: Self.container)
            cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
            cell.configure(
                with: FeedItemDisplayModel(
                    id: PostID("post-1"),
                    authorID: ProfileID("profile-1"),
                    authorName: "Ana",
                    metaText: "@ana · 3m",
                    avatarURL: nil,
                    caption: "a caption",
                    mediaURL: media ? URL(string: "mock://media/1") : nil,
                    mediaKind: .image,
                    thumbnailURL: nil,
                    audioText: nil
                ),
                pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                videoPlayback: nil
            )
            cell.setCommentsEngaged(true)
            return try backdrop(of: cell).dimOpacity
        }

        #expect(try abs(engagedBackdropOpacity(media: true) - SnapCommentsLayout.backdropDimOpacity) < 0.001)
        #expect(try engagedBackdropOpacity(media: false) == 0)
    }

    /// …and the RE-ASSERT path must agree with it. That path used
    /// `setActive(true)`, a convenience that applies the full wash
    /// unconditionally, so a text page got its wash back every time the
    /// screen re-appeared from a pushed profile — which is how the sim
    /// showed a flat #7F7F7F page over what should have been white.
    @Test func reassertingEngagedGeometryKeepsTextPagesUnwashed() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.configure(
            with: FeedItemDisplayModel(
                id: PostID("post-text"),
                authorID: ProfileID("profile-1"),
                authorName: "Ana",
                metaText: "@ana · 3m",
                avatarURL: nil,
                caption: "a thought",
                mediaURL: nil,
                mediaKind: .image,
                thumbnailURL: nil,
                audioText: nil
            ),
            pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            videoPlayback: nil
        )
        cell.setCommentsEngaged(true)
        cell.reassertEngagedGeometry()
        #expect(try backdrop(of: cell).dimOpacity == 0)
    }

    /// THE CAPTION ROW IS NEVER FADED IN, and that is a rendering
    /// requirement rather than a taste one.
    ///
    /// Diffable animates an insertion by fading the cell, and the caption
    /// cell hosts a `UIVisualEffectView` — alpha on an effect view is
    /// unsupported and renders the material as a flat opaque grey for the
    /// fade's duration. In light mode that read as the bubble loading dark
    /// and snapping to light (measured #8F8F8F → #A7A7A7 → #AEAEAE →
    /// #FCFCFC, an alpha ramp, while the glass logged `.light` throughout).
    ///
    /// Later applies — sorts, folds, submissions — still animate; only the
    /// one that introduces the caption is exempt.
    @Test func theApplyThatIntroducesTheCaptionNeverAnimates() {
        // Cold: nothing to animate from.
        #expect(PostDetailViewController.animatesStreamApply(
            hasAppliedStream: false, introducesCaption: true) == false)
        #expect(PostDetailViewController.animatesStreamApply(
            hasAppliedStream: false, introducesCaption: false) == false)
        // The post lands after the skeletons: the stream HAS been applied,
        // and this is exactly the apply that used to fade the glass in.
        #expect(PostDetailViewController.animatesStreamApply(
            hasAppliedStream: true, introducesCaption: true) == false)
        // Everything else keeps its native animation.
        #expect(PostDetailViewController.animatesStreamApply(
            hasAppliedStream: true, introducesCaption: false) == true)
    }


    /// The cell is the theme's authority for everything it OWNS — the frost
    /// band and the hosted comment panel both inherit from its content view
    /// rather than each pinning a style of their own.
    ///
    /// This is what makes the page internally consistent: the panel used to
    /// pin itself dark, so it stayed dark on a text page that had gone
    /// light. Anything hosted later inherits for free.
    @Test func theCellPropagatesOnePageThemeToEverythingItOwns() throws {
        func themedCell(media: Bool) -> SnapFeedCell {
            let cell = SnapFeedCell(frame: Self.container)
            cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
            cell.configure(
                with: FeedItemDisplayModel(
                    id: PostID(media ? "post-media" : "post-text"),
                    authorID: ProfileID("profile-1"),
                    authorName: "Ana",
                    metaText: "@ana · 3m",
                    avatarURL: nil,
                    caption: "a caption",
                    mediaURL: media ? URL(string: "mock://media/1") : nil,
                    mediaKind: .image,
                    thumbnailURL: nil,
                    audioText: nil
                ),
                pipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
                videoPlayback: nil
            )
            return cell
        }

        let mediaCell = themedCell(media: true)
        #expect(mediaCell.contentView.overrideUserInterfaceStyle == .dark)
        let textCell = themedCell(media: false)
        #expect(textCell.contentView.overrideUserInterfaceStyle == .unspecified)

        // A hosted panel takes the cell's answer, not one of its own.
        let hosted = UIView()
        textCell.installComments(hosted)
        #expect(hosted.overrideUserInterfaceStyle == .unspecified)
        #expect(hosted.traitCollection.userInterfaceStyle
            == textCell.contentView.traitCollection.userInterfaceStyle)

        // Reuse hands the cell back as a MEDIA page — a text page's
        // inherited theme must not be stranded under an incoming photo.
        textCell.prepareForReuse()
        #expect(textCell.contentView.overrideUserInterfaceStyle == .dark)
    }

    /// THE FROST VEIL, and why it only exists on text pages.
    ///
    /// Blur is refraction: it can only show what it has to work with. Over a
    /// photo it is obvious; over a text page's flat ground it is
    /// arithmetically almost a no-op, which is why the bands read as
    /// "missing" there (measured: #F9F9F9 against a #FFFFFF page). Over
    /// media a veil would only mute the thing the layout exists to show.
    @Test func theFrostVeilIsForFlatGroundsOnly() {
        #expect(SnapCommentsLayout.frostVeilOpacity(hasMedia: true) == 0)
        #expect(SnapCommentsLayout.frostVeilOpacity(hasMedia: false)
            == SnapCommentsLayout.frostVeilOpacity)
        // A ramp, not a lid: the solid end stays short of fully opaque so
        // the blur still contributes there.
        #expect(SnapCommentsLayout.frostVeilOpacity > 0.5)
        #expect(SnapCommentsLayout.frostVeilOpacity < 1)
    }

    /// The veil rides INSIDE the effect view's content view, so the gradient
    /// that masks the blur masks it too — one ramp governs both layers and
    /// they cannot disagree about where the band ends.
    ///
    /// Its colour is `secondarySystemBackground`, one step recessed from the
    /// page. The page's OWN colour was the first attempt and is invisible by
    /// construction — a white veil over a white page changes nothing.
    @Test func theFrostVeilSharesTheBlursRampAndRecedesFromThePage() throws {
        let frost = ProgressiveFrostView(
            maskColors: SnapCommentsLayout.headerFrostMaskColors,
            maskLocations: SnapCommentsLayout.headerFrostMaskLocations
        )
        frost.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        frost.layoutIfNeeded()

        let veil = try #require(frost.contentView.subviews.first { $0.backgroundColor != nil })
        #expect(veil.superview === frost.contentView)
        #expect(frost.mask != nil)
        #expect(veil.bounds.size == frost.bounds.size)

        // Semantic and dynamic, so it follows the page's theme…
        let colour = try #require(veil.backgroundColor)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        #expect(colour.resolvedColor(with: light) != colour.resolvedColor(with: dark))
        // …and RECESSED from the page in both, never equal to it.
        for traits in [light, dark] {
            #expect(colour.resolvedColor(with: traits)
                != UIColor.systemBackground.resolvedColor(with: traits))
        }

        // Off by default: a band must opt in, so media pages stay unveiled.
        #expect(veil.alpha == 0)
        frost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity)
        #expect(abs(veil.alpha - SnapCommentsLayout.frostVeilOpacity) < 0.001)
        frost.setVeilOpacity(0)
        #expect(veil.alpha == 0)
    }

    /// ONE THEME RULE for the whole page, and it follows from what is behind
    /// the chrome: a media page pins dark (contrast over an arbitrary photo
    /// cannot come from the device's appearance), a text page inherits (its
    /// own ground already follows the system).
    @Test func chromeThemeIsPinnedOverMediaAndInheritedOverText() {
        #expect(SnapChromeTheme.style(hasMedia: true) == .dark)
        #expect(SnapChromeTheme.style(hasMedia: false) == .unspecified)
    }

    /// The bars carry NO private opinion about light and dark. Their text is
    /// semantic and resolves from the theme above; `setOverMedia` moves only
    /// the SHADOW, which is not a theme question — it exists because a pill
    /// over a photo has no background of its own.
    ///
    /// The two used to be one switch (white+shadow vs semantic+none), which
    /// is how the bars ended up disagreeing with the page: the colour said
    /// "dark page" while the platter behind it was drawn light.
    @Test func barTextIsSemanticAndOnlyTheShadowFollowsTheGround() throws {
        let identity = SnapAuthorIdentityView()
        let attribution = SnapMediaAttributionView()

        func labels(_ root: UIView) -> [UILabel] {
            var found: [UILabel] = []
            var stack: [UIView] = [root]
            while let view = stack.popLast() {
                if let label = view as? UILabel { found.append(label) }
                stack.append(contentsOf: view.subviews)
            }
            return found
        }

        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for view in [identity, attribution] as [UIView] {
            func setOverMedia(_ value: Bool) {
                (view as? SnapAuthorIdentityView)?.setOverMedia(value)
                (view as? SnapMediaAttributionView)?.setOverMedia(value)
            }

            setOverMedia(true)
            let withShadow = labels(view).filter { $0.textColor != nil }
            #expect(withShadow.contains { $0.layer.shadowOpacity > 0 })
            // Colours are dynamic in BOTH states — they never hardcode white.
            for label in withShadow {
                let colour = try #require(label.textColor)
                #expect(colour.resolvedColor(with: light) != colour.resolvedColor(with: dark))
            }

            setOverMedia(false)
            let withoutShadow = labels(view)
            #expect(withoutShadow.allSatisfy { $0.layer.shadowOpacity == 0 })
            // …and the colours did NOT move: only the shadow did.
            for label in withoutShadow where label.textColor != nil {
                let colour = try #require(label.textColor)
                #expect(colour.resolvedColor(with: light) != colour.resolvedColor(with: dark))
            }
        }
    }

    /// The rail is ENGAGEMENT-scoped, through the cell: a resting page keeps
    /// its action column, an engaged one hands the width to the comments.
    ///
    /// This replaces a keyboard-session "rail yield" — the rail used to
    /// survive the engagement and concede its band only while the composer
    /// rose into it. The engagement fades it outright now, so the keyboard
    /// has no overlap left to arbitrate and the observers that drove it are
    /// gone.
    @Test func railIsEngagementScopedThroughTheCell() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)

        #expect(rail.alpha == 1) // at rest

        cell.setCommentsEngaged(true)
        #expect(rail.superview?.alpha == 0) // the chrome carries the fade

        cell.setCommentsEngaged(false)
        #expect(rail.alpha == 1)
    }

    /// The comments skeleton row is the messages doctrine transplanted:
    /// three shimmer bones (avatar, header, body) on the real row's
    /// geometry — and ONLY the organic content shimmers: the trailing
    /// band where the real row's like control stands is reserved empty,
    /// so no bone (not even the widest body pill) crosses into it.
    @Test func commentSkeletonRowMimicsOrganicContentOnly() {
        let row = CommentSkeletonRowView(index: 3) // widest body fraction (0.94)
        var bones: [UIView] = []
        var stack: [UIView] = [row]
        while let view = stack.popLast() {
            if view is SkeletonBoneView { bones.append(view) }
            stack.append(contentsOf: view.subviews)
        }
        #expect(bones.count == 3)
        #expect(row.isUserInteractionEnabled == false)

        row.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        row.layoutIfNeeded()
        let clearBandStart = 320 - CommentSkeletonRowView.likeColumnReservation
        for bone in bones {
            let boneMaxX = row.convert(bone.bounds, from: bone).maxX
            #expect(boneMaxX <= clearBandStart)
        }
    }

    /// The skeleton snapshot's density is viewport math, never a fixed
    /// integer: count = ceil(viewport / estimate), with the estimate a
    /// deliberate low-ball of the real row height so every form factor
    /// over-provisions (the list clips the excess) and none strands
    /// blank space above the input bar.
    @Test func skeletonDensityScalesWithTheViewport() {
        let se = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 667)
        let proMax = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 932)
        let pad = SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 1366)

        // Coverage: estimate × count ≥ viewport on every device.
        #expect(CGFloat(se) * SnapCommentsLayout.skeletonRowEstimate >= 667)
        #expect(CGFloat(proMax) * SnapCommentsLayout.skeletonRowEstimate >= 932)
        #expect(CGFloat(pad) * SnapCommentsLayout.skeletonRowEstimate >= 1366)
        // Monotonic: taller viewports never get fewer rows.
        #expect(se <= proMax && proMax <= pad)
        // The estimate stays a low-ball of the measured row (~48pt) — the
        // direction that makes the division OVER-provision.
        #expect(SnapCommentsLayout.skeletonRowEstimate <= 48)
        // Pre-layout fallback (zero bounds) still blankets every iPhone.
        #expect(SnapCommentsLayout.skeletonPlaceholderCount(viewportHeight: 0) >= proMax)
    }

    /// The comments-only empty PAGE row. `EmptyStateView` centres its block
    /// and has no vertical intrinsic size, so a self-sizing list row has to
    /// be told a height. The seed claims the whole available region (which
    /// already excludes header, composer and safe areas); the correction
    /// gives back whatever the caption row above it turned out to take.
    @Test func theEmptyPageRowSeedsFromTheAvailableRoom() {
        #expect(SnapCommentsLayout.emptyPageHeight(availableHeight: 700) == 700)
        // The floor covers the pre-layout call, where bounds are still zero.
        #expect(
            SnapCommentsLayout.emptyPageHeight(availableHeight: 0)
                == SnapCommentsLayout.emptyPageMinimumHeight
        )
        #expect(SnapCommentsLayout.emptyPageMinimumHeight > 0)
    }

    // MARK: - Entry point

    /// Every comments surface is an engagement entry point — the empty-state
    /// pill, the subtitle zone, and the ticker band all fan into the one
    /// `onCommentsTapped` path, and each is a declared interaction root so
    /// play/pause arbitration yields to it.
    @Test func everyCommentsSurfaceIsATapEntryPoint() throws {
        let chrome = SnapChromeView(frame: Self.container)
        let pill = try #require(chrome.subviews.compactMap { $0 as? SnapCommentEmptyStateView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        for surface in [pill, subtitle, ticker] {
            #expect(surface.isUserInteractionEnabled)
            #expect(chrome.interactionRoots.contains(where: { $0 === surface }))
        }

        var fires = 0
        chrome.onCommentsTapped = { fires += 1 }
        pill.onTap?()
        subtitle.onTap?()
        ticker.onTap?()
        #expect(fires == 3)
    }

    /// The interactive page-drive's rubber-band past the feed ends: maps
    /// [0, ∞) into [0, dimension) — zero at zero, monotonic, and always
    /// resisting (the mapped excess is strictly less than the raw drag), so
    /// you can drag past the first/last post but never fling off the feed.
    @Test func pageDriveRubberBandResistsPastTheEnds() {
        let d: CGFloat = 800
        #expect(SnapFeedViewController.rubberBand(0, dimension: d) == 0)
        // Monotonic and bounded below the dimension…
        var previous: CGFloat = 0
        for raw in stride(from: CGFloat(40), through: 4000, by: 40) {
            let mapped = SnapFeedViewController.rubberBand(raw, dimension: d)
            #expect(mapped > previous)         // increasing
            #expect(mapped < d)                // never reaches a full page
            #expect(mapped < raw)              // always resists
            previous = mapped
        }
    }

}

/// A fetcher whose completion the test controls, so the "slow avatar lands
/// on a recycled row" race can be exercised deterministically instead of
/// raced against a sleep.
private actor GateddImageFetcher: ImageFetching {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(openFrom: Bool = false) { isOpen = openFrom }

    /// Lets every pending (and future) fetch complete.
    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func fetchImageData(for url: URL) async throws -> Data {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return Self.onePixelPNG
    }

    /// The smallest thing `CGImageSourceCreateThumbnailAtIndex` will decode.
    private static let onePixelPNG = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
}

/// Every fetch fails — the "no picture ever arrives" path, which must be
/// indistinguishable from having no avatar URL at all.
private struct FailingImageFetcher: ImageFetching {
    func fetchImageData(for url: URL) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

/// The least a `PostDetailViewController` needs to stand up for a layout
/// assertion — no network, no comments, no router.
private final class EmptyFeedProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "hi",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
