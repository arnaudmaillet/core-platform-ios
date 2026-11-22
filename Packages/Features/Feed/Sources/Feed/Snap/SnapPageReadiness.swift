import CoreModels
import PostSurfaces
import UIKit

/// What the pager's readiness asks of its screen (#2514): the pages and
/// their models, the text pages' panel factory, the three places a panel can
/// be (the warm, the preview, the engagement), the settled page, and the warm
/// that prepares the next one.
@MainActor
protocol SnapPageReadinessHost: AnyObject {
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var makeCommentsPanelContent: ((PostID) -> UIViewController)? { get }
    var restingWarm: SnapWarmSlots<PostID, UIViewController> { get }
    var previewRestingID: PostID? { get }
    var commentsEngagedID: PostID? { get }
    var settledPageIndex: Int { get }
    func prewarmRestingComments(for id: PostID)
}

/// How far the full-screen pager may go (#2514): whether a page can be shown
/// without the viewer watching it assemble, the furthest page reachable now,
/// and the ceiling the pager, the page drive and the paging footer clamp to —
/// which prepares the next page before it answers.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every question is answered in the
/// caller's turn — a drag's end, a drive's step, a settle's warm.
@MainActor
final class SnapPageReadiness {
    private unowned let host: any SnapPageReadinessHost

    init(host: any SnapPageReadinessHost) {
        self.host = host
    }

    /// Whether a page can be shown without the viewer watching it assemble.
    ///
    /// A MEDIA page is ready as soon as its model is: the cover arrives into a
    /// laid-out card and the page is legible without it. A TEXT page is not —
    /// what a text page IS is its comments panel, so until that panel is built
    /// the page is a black rectangle, and showing it is the defect this answers.
    ///
    /// ⚠️ A HOST WITH NO PANEL FACTORY HAS READY TEXT PAGES BY DEFINITION.
    /// Without that line every text post would be permanently unreachable on
    /// any surface that does not supply one — a far worse failure than the
    /// pop-in, and silent.
    func isPageReady(_ index: Int) -> Bool {
        guard host.orderedIDs.indices.contains(index),
              let model = host.modelsByID[host.orderedIDs[index]] else { return false }
        guard model.mediaURL == nil, host.makeCommentsPanelContent != nil else { return true }
        // ⚠️ ALL THREE PLACES A PANEL CAN BE, and leaving one out strands the
        // viewer.
        //
        // A panel is built ahead (`restingWarm`), then MOUNTED into the
        // incoming cell as a preview — which consumes the warm — and only later
        // promoted to the engagement. Counting the first and the last but not
        // the middle meant a page that was already on screen, fully drawn, read
        // as "not ready": the ceiling stopped short of it and the pager refused
        // to advance. Two text posts in a row could not be paged through at
        // all, and the console showed only the hero grab correctly declining an
        // upward drag — nothing about the page that was quietly unreachable.
        return host.restingWarm.contains(model.id)
            || host.previewRestingID == model.id
            || host.commentsEngagedID == model.id
    }

    /// The furthest page the viewer may reach right now.
    ///
    /// Scans forward from where they are and stops at the first page that is
    /// not ready — which for a run of text posts is one at a time, since only
    /// the page immediately ahead is ever built. That is the intent: a page the
    /// viewer cannot reach yet reads exactly like the end of the feed, which is
    /// a state this app already has an answer for, rather than like a post that
    /// renders itself while they look at it.
    ///
    /// Never behind the page they are on: a corpus that changes under a settled
    /// viewer must not push them backwards.
    var lastReachablePage: Int {
        let last = max(0, host.orderedIDs.count - 1)
        var index = min(host.settledPageIndex, last)
        while index < last, isPageReady(index + 1) { index += 1 }
        return index
    }

    /// The ceiling the pager actually uses: PREPARE, then allow.
    ///
    /// ⚠️ A GATE THAT CAN STRAND IS WORSE THAN THE POP-IN IT PREVENTS, and this
    /// one stranded twice — each time on a state nobody had thought to count as
    /// "ready", each time reported as the scroll simply not working, with
    /// nothing in the trace to say why. That is the failure mode of asking a
    /// question that can be wrong in a direction with no recovery.
    ///
    /// So the answer is not "is it ready" but "make it ready": the panel is
    /// built synchronously, here, at the moment the viewer asks to move. A page
    /// that can be prepared is reachable BECAUSE it was just prepared, and a
    /// page that cannot be — no factory, no model yet — is reachable anyway,
    /// because being stuck is not an outcome any viewer can act on.
    ///
    /// What remains gated is the only thing a viewer can understand: a page
    /// whose data has not arrived. That is the end of the list, and the loader
    /// says so.
    func reachableCeiling() -> Int {
        let last = max(0, host.orderedIDs.count - 1)
        let settled = min(host.settledPageIndex, last)
        guard settled < last, host.modelsByID[host.orderedIDs[settled + 1]] != nil else { return settled }
        // ⚠️ THE NEXT PAGE ONLY, because the warm holds the window around the
        // settled page (#2059) and one page forward is all a gesture can
        // reach. Walking the run forward would push the
        // previous page's panel out for a guess.
        if !isPageReady(settled + 1) { host.prewarmRestingComments(for: host.orderedIDs[settled + 1]) }
        // Past it, the only question left is whether the data has arrived.
        var ceiling = settled + 1
        while ceiling < last, host.modelsByID[host.orderedIDs[ceiling + 1]] != nil { ceiling += 1 }
        return ceiling
    }
}
