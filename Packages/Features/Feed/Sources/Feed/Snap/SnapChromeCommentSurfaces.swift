import UIKit

/// What the comment surfaces ask of the chrome (#2521): whether the page
/// carries media — a text page's chrome takes no comment content.
@MainActor
protocol SnapChromeCommentSurfacesHost: AnyObject {
    var hasMedia: Bool { get }
}

/// The page's comment surfaces over the media, out of `SnapChromeView`
/// (#2521): the danmaku band, the subtitle zone and the empty state —
/// their content, which reaches them only through `updateCommentStreams`,
/// and their visibility seam. The chrome lays them out and fades them.
@MainActor
final class SnapChromeCommentSurfaces {
    private unowned let host: any SnapChromeCommentSurfacesHost

    /// The danmaku band, floating over the media directly above the caption.
    /// Content reaches it only through `updateCommentStreams` — never through
    /// `configure` — so the flight replica renders an empty, invisible band
    /// by construction and the card stays pixel-identical to the landed page.
    let commentTicker = SnapCommentTickerView()

    /// The subtitle zone, directly above the band: a persistent pill of
    /// semantic comments, one at a time, with the count bubble leading it.
    /// Same content contract as the band (arrives only via
    /// `updateCommentStreams`, so the flight replica's zone is empty by
    /// construction) and the same visibility-scoped activation, so the
    /// zone rides a page being dragged in.
    let subtitleView = SnapSubtitleView()

    /// The comments empty state: a static "No comments yet" pill occupying
    /// the band's slot when the post is KNOWN to have zero comments — the
    /// one case where every comment surface above legitimately gates itself
    /// away and the zone would otherwise read as unexplained blank space.
    /// Same content contract as the band and the zone (visible only via
    /// `updateCommentStreams`, on a loaded stream), so the flight replica
    /// never shows it.
    let commentEmptyState = SnapCommentEmptyStateView()

    init(host: any SnapChromeCommentSurfacesHost) {
        self.host = host
    }

    /// Replaces both comment surfaces' content (the ticker's wrap-around
    /// queue and the subtitle zone's cue list). Live cells only — the flight
    /// replica must never receive this (moving/timed content cannot be
    /// pixel-identical across two instances), which is why it is not part of
    /// `configure`. Empty streams hide their surface. Text-only posts refuse
    /// content entirely (empty shell) — gated here, not at the callers, so
    /// every arrival path (dequeue pull, async push) hits the same wall.
    func updateCommentStreams(_ streams: FeedViewModel.CommentStreams) {
        guard host.hasMedia else { return }
        commentTicker.setComments(streams.reactions)
        // Loaded, the band follows the bubbles: none, it goes. A SEED (top
        // comments from the cache, not loaded) knows nearly as well — a seed
        // with cues and no bubbles reserved the band by the card's count and
        // left the pill floating over a hole until the load collapsed it
        // (filmed on a device, 25 September 2026). Only a page with no
        // streams at all keeps the card's guess.
        if streams.isLoaded || streams.commentCount > 0 {
            commentTicker.setReservesBand(!streams.reactions.isEmpty)
        }
        subtitleView.setCommentCount(streams.commentCount)
        subtitleView.setCues(streams.subtitles)
        // THE COUNT IS THE WHOLE CONDITION (product rule 2026-08-08): no
        // comments → the pill; one or more → the comment stream speaks for
        // the post and the pill stays down. The zone is never blank on
        // either side of that line, and this view is not where that is
        // enforced — `SubtitleCommentBuilder` guarantees a non-empty cue
        // list for any post the band isn't already carrying, so "has
        // comments" and "the zone renders" cannot come apart. A count pill
        // ("2 comments") was tried in this slot as a stand-in for the
        // stream and removed; the stream itself is the answer.
        //
        // `isLoaded` is the load/zero seam: an unloaded stream carries a
        // zero count too, so without it the pill would flash on every page
        // while its fetch is in flight.
        commentEmptyState.setVisible(streams.isLoaded && streams.commentCount == 0)
    }

    /// The flight's hold, passed to the ticker: no pre-fill at a transient
    /// width (see `SnapCommentTickerView.setHeldForFlight`).
    func setTickerHeldForFlight(_ held: Bool) {
        commentTicker.setHeldForFlight(held)
    }

    /// See `SnapCommentTickerView.replayEntrance`.
    func replayCommentBandEntrance() {
        commentTicker.replayEntrance()
    }

    /// See `SnapSubtitleView.replayEntrance`.
    func replaySubtitleEntrance() {
        subtitleView.replayEntrance()
    }

    /// Streams while the owning cell is on screen (visibility-scoped — a
    /// page dragged partway in already flows; see the cell's
    /// `setTickerStreaming`).
    func setTickerActive(_ active: Bool) {
        commentTicker.setActive(active)
    }

    /// "Don't Cover People" (#484): the band to mask — always the same view,
    /// shown or not (it appears once its comments arrive).
    var personOcclusionTicker: UIView { commentTicker }
    /// Whether that band is on screen now.
    var isPersonOcclusionBandShown: Bool { !commentTicker.isHidden && commentTicker.window != nil }

    /// Cycles while the owning cell is on screen — the band's visibility
    /// seam (plus the settle backstop for foregrounding), NOT playback's
    /// settle scope: the persistent pill is static content between
    /// handoffs, so it must ride a half-dragged page like the caption
    /// does instead of popping in after settle.
    func setSubtitlesActive(_ active: Bool) {
        subtitleView.setActive(active)
        // The empty state rides the same seam — its label's dwell is a
        // READING clock, so it starts when the page is actually on screen,
        // not when the stream lands on a cell still off in the pager.
        commentEmptyState.setActive(active)
    }
}
