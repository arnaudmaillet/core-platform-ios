import CoreContracts
import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
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

    /// The caption card is a LIQUID GLASS bubble, and each clause here is a
    /// rule the material imposes that a plain blur did not:
    ///
    /// - the shape lives in `cornerConfiguration`, so `layer.cornerRadius`
    ///   must stay 0 and the view must not clip — a layer radius clips a
    ///   material that doesn't know it has been clipped, and the specular
    ///   edge is drawn on the unclipped shape;
    /// - no border of our own, because the glass draws its own edge (a
    ///   hairline on top reads as an outline sitting ON the material);
    /// - the appearance is pinned dark, so white caption text keeps its
    ///   contrast on a light-mode device over a pale photo;
    /// - and the radius is the app's message-bubble radius, not a local pick.
    @Test func theCaptionCardIsALiquidGlassBubble() throws {
        let card = SnapPostInfoCardView(frame: CGRect(x: 0, y: 0, width: 374, height: 96))
        let glass = try #require(card.subviews.compactMap { $0 as? SnapGlassCardView }.first)
        card.layoutIfNeeded()

        #expect(glass.layer.cornerRadius == 0)
        #expect(glass.clipsToBounds == false)
        #expect(glass.layer.borderWidth == 0)
        #expect(glass.overrideUserInterfaceStyle == .dark)
        #expect(glass.effectiveRadius(corner: .allCorners) == SnapCommentsLayout.stripCardCornerRadius)
        // The bubble radius is the chat transcript's, not a number picked here.
        #expect(SnapCommentsLayout.stripCardCornerRadius == 18)
        // Bubble padding clears the corner on every side.
        #expect(SnapPostInfoCardView.contentInset == Spacing.lg)

        // Unwindowed, the glass stays nil — building a real effect off-screen
        // stalls the render server on headless CI, the rule every glass
        // surface in the app follows.
        glass.setGlassActive(true)
        #expect(glass.effect == nil)
    }

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
        // now — the shrink belongs to the hosted stream — so the footer's
        // band (which lives inside it) and the header's (a sibling) both
        // hold their size at the screen's edge and only fade.
        #expect(container.transform == .identity)
        let frost = try #require(
            cell.contentView.subviews.compactMap { $0 as? ProgressiveFrostView }.first
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
        // The chrome as a whole never fades — only its comment surfaces do;
        // the rail rides both states at full presence.
        #expect(chrome.alpha == 1)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)
        let ticker = try #require(chrome.subviews.compactMap { $0 as? SnapCommentTickerView }.first)
        let subtitle = try #require(chrome.subviews.compactMap { $0 as? SnapSubtitleView }.first)
        #expect(rail.alpha == 1)
        // Fully interactive through the engagement — the keyboard-up
        // overlap with the composer's ✕ is arbitrated in the cell's
        // hitTest, not by disabling the rail.
        #expect(rail.isUserInteractionEnabled == true)
        #expect(ticker.alpha == 0)
        #expect(subtitle.alpha == 0)
        // The "+" anchor is RAIL territory, not ticker content: it holds
        // its native seat at full presence through the engagement (only
        // its frame borrows the ticker band's edges) and it is a declared
        // interaction root, so the cell's tap arbitration yields to it in
        // both states.
        let plus = try #require(chrome.subviews.compactMap { $0 as? SnapRailComposeButton }.first)
        #expect(plus.alpha == 1)
        #expect(chrome.interactionRoots.contains(plus))

        cell.setCommentsEngaged(false)
        #expect(cell.isCommentsEngaged == false)
        #expect(media.transform == .identity)
        #expect(card.transform == .identity)
        #expect(backdrop.dimOpacity == 0)
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
            cell.contentView.subviews.compactMap { $0 as? SnapCommentsContainerView }.first
        )
        let colour = try #require(container.backgroundColor)
        var alpha: CGFloat = -1
        #expect(colour.getWhite(nil, alpha: &alpha))
        #expect(alpha == 0)
        // And it sits ABOVE the media and the backdrop, never below them.
        let subviews = cell.contentView.subviews
        let mediaIndex = try #require(subviews.firstIndex(of: mediaCard(of: cell)))
        let backdropIndex = try #require(subviews.firstIndex(of: backdrop(of: cell)))
        let streamIndex = try #require(subviews.firstIndex(of: container))
        #expect(mediaIndex < backdropIndex)
        #expect(backdropIndex < streamIndex)
    }

    /// The keyboard-up collision rule: wherever the rail and the engaged
    /// composer physically overlap, the composer wins the touch; the rail
    /// keeps everything else. Exercised through the cell's real hitTest
    /// with a composer positioned inside the rail's column.
    @Test func engagedComposerOutranksTheRailWhereTheyOverlap() throws {
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
        // Host a composer whose frame overlaps the rail's column (the
        // keyboard-up geometry), plus a probe point in the rail clear of it.
        let hosted = UIView()
        cell.installComments(hosted)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
        let bar = CommentsInputBar()
        let overlap = CGPoint(x: rail.frame.midX, y: rail.frame.midY)
        let barOrigin = hosted.convert(CGPoint(x: overlap.x - 20, y: overlap.y - 20), from: cell)
        bar.frame = CGRect(origin: barOrigin, size: CGSize(width: 120, height: 46))
        hosted.addSubview(bar)

        let overlapHit = try #require(cell.hitTest(overlap, with: nil))
        #expect(sequence(first: overlapHit, next: { $0.superview }).contains { $0 is CommentsInputBar })
        // Above the composer, the rail still owns its column.
        let railPoint = CGPoint(x: rail.frame.midX, y: rail.frame.minY + 10)
        let railHit = try #require(cell.hitTest(railPoint, with: nil))
        #expect(sequence(first: railHit, next: { $0.superview }).contains { $0 is SnapShortcutRailView })
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
        // chrome it serves lands on the content, which is what the earlier
        // 160pt runway did. Hit-inert throughout.
        let subviews = cell.contentView.subviews
        let frost = try #require(subviews.compactMap { $0 as? ProgressiveFrostView }.first)
        #expect(frost.isHidden == false)
        #expect(frost.frame == CGRect(
            x: 0, y: 0,
            width: Self.container.width,
            height: SnapCommentsLayout.commentsTopInset(topInset: Self.topInset)
        ))
        // The band ENDS at the content line — no overhang, in either
        // direction: this is the whole constraint.
        #expect(frost.frame.maxY == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
        #expect(frost.isUserInteractionEnabled == false)
        let frostMask = try #require(frost.mask)
        #expect(frostMask.frame == frost.bounds)
        // The HEADER ramps endpoint to endpoint across its container:
        // opaque at the screen's edge, clear at the content line, two stops
        // so there is no knee partway down.
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
        // The FOOTER is NOT symmetric, and deliberately so: it fades in over
        // the lead and then HOLDS full material, so the composer sits on the
        // solid part of the band rather than its clear end.
        let footer = SnapCommentsLayout.footerFrostMaskColors
        #expect(footer.count == 3)
        #expect(alpha(footer[0]) == 0)   // clear at the band's top…
        #expect(alpha(footer[1]) == 1)   // …full by the composer's top…
        #expect(alpha(footer[2]) == 1)   // …and solid to the screen's bottom

        // NO caption card in the cell at all any more — the caption is the
        // hosted stream's first row, so the feed cell must not carry a
        // second copy of it floating above.
        #expect(subviews.compactMap { $0 as? SnapPostInfoCardView }.isEmpty)

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
        // The media never moved, so there is no z-order to restore.
        #expect(cell.contentView.subviews.firstIndex(of: media) == 0)
    }

    /// REGRESSION, inverted (stranded center tile): the outbound push's
    /// lifecycle resign runs the Ken Burns stop, which once had to settle
    /// onto a per-state resting transform — a blind identity stranded the
    /// docked tile as a frozen full-bleed center crop that the return could
    /// not heal. With the media full-bleed in BOTH states there is no such
    /// state to get wrong: identity is correct throughout, and the recede
    /// the engagement does own lives on the card, out of the drift's reach.
    @Test func outboundResignLeavesTheBackgroundMediaAlone() throws {
        let cell = makeEngagedCell()
        let card = try mediaCard(of: cell)
        let media = card.imageView
        #expect(media.transform == .identity)

        // The outbound push's lifecycle: activate, then resign (image
        // cells run the Ken Burns stop on this path).
        cell.willBecomeActive()
        cell.didResignActive()
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

    /// The media component — the render surfaces now live inside it, not as
    /// loose cell subviews.
    private func mediaCard(of cell: SnapFeedCell) throws -> SnapMediaCardView {
        try #require(cell.contentView.subviews.compactMap { $0 as? SnapMediaCardView }.first)
    }

    /// The readability layer between the media and the stream.
    private func backdrop(of cell: SnapFeedCell) throws -> SnapMediaBackdropView {
        try #require(cell.contentView.subviews.compactMap { $0 as? SnapMediaBackdropView }.first)
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
            cell.contentView.subviews.compactMap { $0 as? ProgressiveFrostView }.first
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
            // No caption card in the cell on EITHER format.
            #expect(cell.contentView.subviews.compactMap { $0 as? SnapPostInfoCardView }.isEmpty)
            // The stream fills the cell and starts below the chrome zone.
            #expect(hosted.superview?.frame == cell.contentView.bounds)
            #expect(cell.engagedCommentsTopInset(safeAreaTop: Self.topInset)
                == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
            let frost = try #require(cell.contentView.subviews.compactMap { $0 as? ProgressiveFrostView }.first)
            #expect(frost.frame.height == SnapCommentsLayout.commentsTopInset(topInset: Self.topInset))
            // The dead-end lock and the armed page-drive, both formats.
            #expect(SnapFeedCollectionView.claimsTouches(hosted))
            let pan = try #require(cell.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
            #expect(pan.isEnabled == true)
            // The reactions rail reserves its trailing column on both.
            #expect(cell.commentsRailExclusionWidth > 0)
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

    @Test func theCaptionBubblePadsEvenlyAndSizesItself() throws {
        let inset = SnapPostInfoCardView.contentInset
        let side: CGFloat = 300
        let card = SnapPostInfoCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: side).isActive = true
        card.configure(caption: "A caption that comfortably fills a line or two.", timestamp: "10 weeks")
        card.setNeedsLayout()
        card.layoutIfNeeded()
        // SELF-SIZED: nothing set a height, so the fitting size is the
        // bubble's own answer, and it must actually hold its content.
        let height = card.systemLayoutSizeFitting(
            CGSize(width: side, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(height > 2 * inset)
        card.frame = CGRect(x: 0, y: 0, width: side, height: height)
        card.layoutIfNeeded()

        func frame(_ v: UIView) -> CGRect { v.superview?.convert(v.frame, to: card) ?? v.frame }
        var labels: [UILabel] = []
        var stack: [UIView] = [card]
        while let view = stack.popLast() {
            if let l = view as? UILabel, l.text?.isEmpty == false { labels.append(l) }
            stack.append(contentsOf: view.subviews)
        }
        let caption = try #require(labels.first { $0.text?.hasPrefix("A caption") == true })
        let timestamp = try #require(labels.first { $0.text == "10 weeks" })
        let captionFrame = frame(caption), timeFrame = frame(timestamp)

        // All four margins are the same inset.
        #expect(abs(captionFrame.minX - inset) < 0.5)
        #expect(abs(side - captionFrame.maxX - inset) < 0.5)
        #expect(abs(captionFrame.minY - inset) < 0.5)
        #expect(abs(height - timeFrame.maxY - inset) < 0.5)
        // The timestamp is TRAILING-aligned (the message-bubble corner) and
        // clears the caption by the one interior gap.
        #expect(abs(side - timeFrame.maxX - inset) < 0.5)
        #expect(timeFrame.minX > captionFrame.midX)
        #expect(timeFrame.minY >= captionFrame.maxY + SnapPostInfoCardView.captionActionsGap - 0.5)
        // A longer caption yields a TALLER bubble — it grows to its text.
        card.configure(caption: String(repeating: "wrapping caption text ", count: 12), timestamp: "10 weeks")
        let tall = card.systemLayoutSizeFitting(
            CGSize(width: side, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(tall > height)
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

        // The avatar column matches the comment rows' exactly.
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        #expect(avatar.bounds.width == CommentRowView.avatarSize)
        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        #expect(abs(bubble.frame.minX - (avatar.frame.maxX + CommentRowView.avatarGap)) < 0.5)

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

    /// The caption bubble is NON-INTERACTIVE — a standard row in the list,
    /// like every comment beside it. It carried a close tap for one round;
    /// a row that silently dismisses the screen under a stray tap is not
    /// what a message in a thread should do, and the toolbar's ✕ is the
    /// single exit. The AVATAR keeps its own tap.
    @Test func theCaptionBubbleIsAPlainRowAndOnlyTheAvatarTaps() throws {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 374, height: 120))
        cell.configure(with: Self.post(caption: "Weekend build log.", avatar: nil), imagePipeline: nil)
        cell.layoutIfNeeded()

        let bubble = try #require(Self.firstView(SnapPostInfoCardView.self, in: cell))
        let avatar = try #require(Self.firstView(MonogramAvatarView.self, in: cell))
        // No recognizer anywhere on the bubble or its content…
        var stack: [UIView] = [bubble]
        while let view = stack.popLast() {
            #expect(view.gestureRecognizers?.isEmpty ?? true)
            stack.append(contentsOf: view.subviews)
        }
        // …while the avatar keeps exactly its own. (The cell's contentView
        // is not asserted: UIKit puts its own recognizers there.)
        #expect(avatar.gestureRecognizers?.count == 1)

        var profiles = 0
        cell.onAvatarTap = { profiles += 1 }
        cell.onAvatarTap?()
        #expect(profiles == 1)
        cell.prepareForReuse()
        #expect(cell.onAvatarTap == nil)
    }

    private static func post(caption: String, avatar: URL?, id: String = "post-0001") -> PostDetailDisplayModel {
        PostDetailDisplayModel(entry: FeedEntry(
            post: Post(
                id: PostID(id), authorID: ProfileID("p1"), caption: caption,
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p1"), handle: "ava", displayName: "Ava Moreau",
                avatarURL: avatar
            )
        ))
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

    /// The composer's reply state: the placeholder names the target and
    /// restores on clear; an idle keyboard dismissal (empty field) fires
    /// the host's reset seam, a drafted one does not.
    @Test func composerReplyStateSwapsPlaceholderAndResetsOnIdleDismiss() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        func placeholder() -> String? {
            var stack: [UIView] = [bar]
            while let view = stack.popLast() {
                if let label = view as? UILabel, label.text?.hasPrefix("Reply to") == true || label.text == "Add a comment…" {
                    return label.text
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

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

    /// The keyboard-session rail yield: engaged cells concede the rail
    /// (alpha 0 — also retiring it from hit-testing) while the composer
    /// owns its risen band; resting cells never yield, and the restore
    /// side is unconditional so no teardown path can strand a hidden rail.
    @Test func keyboardRailYieldIsEngagementScoped() throws {
        let cell = SnapFeedCell(frame: Self.container)
        cell.applyChromeInsets(UIEdgeInsets(top: Self.topInset, left: 0, bottom: 34, right: 0))
        cell.layoutIfNeeded()
        let chrome = try #require(cell.contentView.subviews.compactMap { $0 as? SnapChromeView }.first)
        let rail = try #require(chrome.subviews.compactMap { $0 as? SnapShortcutRailView }.first)

        cell.setRailConcealed(true) // disengaged: refused
        #expect(rail.alpha == 1)

        cell.setCommentsEngaged(true)
        cell.setRailConcealed(true)
        #expect(rail.alpha == 0)
        cell.setRailConcealed(false)
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
