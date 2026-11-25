import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import PostGrid
import PostSurfaces
import ShareSheet
import ThreadKit
import UIKit

/// What the full-screen feed's post actions ask of their screen (#2514): the
/// posts it holds, the picture pipeline, the send to someone, the people a
/// post can be sent to, the toolbar's like and the posts no longer available.
///
/// A view controller: the sheets, the report reasons and the toasts are
/// presented from it.
@MainActor
protocol SnapPostActionsHost: UIViewController {
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var imagePipeline: ImagePipeline { get }
    var viewModel: FeedViewModel { get }
    /// The share sheet's quick-send row: the people the viewer can send a
    /// post to.
    var shareTargeting: (any ShareTargeting)? { get }
    var toolbarComposer: SnapToolbarComposer { get }
    var unavailablePostIDs: Set<PostID> { get }
}

/// The full-screen feed's actions on a post (#2514): its share sheet — the
/// app's one share surface (`ShareSheet`), tuned by its configuration — and
/// the sheet's own chips: Repost, Not interested and Report, with the report
/// reasons (`ReportReasonSheet`) and the session's hidden posts.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before; only the report's filing waits.
@MainActor
final class SnapPostActions {
    private unowned let host: any SnapPostActionsHost
    /// Files a post's Report. Nil withholds the row entirely.
    private let reporting: (any ContentReporting)?

    #if DEBUG
    /// The posts whose sheet was raised, in order. Tests.
    private(set) var debugSharedPostIDs: [PostID] = []
    #endif

    init(host: any SnapPostActionsHost, reporting: (any ContentReporting)?) {
        self.host = host
        self.reporting = reporting
    }

    /// The post's share sheet (#1710) — the app's ONE share surface
    /// (`ShareSheet`, the profile's and the place's), tuned rather than
    /// cloned (`ShareSheetConfiguration`): the post's author on the QR card,
    /// the post's own link (`AppRoute.postLink`), Repost after Copy Link. Its escape hatches come back here once it is
    /// gone: the system sheet, and a send to someone (the link, in a DM).
    func presentShareSheet(for id: PostID) {
        guard host.presentedViewController == nil, let model = host.modelsByID[id],
              let link = AppRoute.postLink(id) else { return }
        #if DEBUG
        debugSharedPostIDs.append(id)
        #endif
        let card = ShareCard(
            displayName: model.authorName,
            handle: SnapAuthorIdentityView.pillMetaLine(fromMeta: model.metaText),
            avatarURL: model.avatarURL,
            url: link,
            // A showcase says its channel (#2216), a voice post its voice
            // (#2208), where no card or player is drawn.
            detail: PostEmbeds.shareText(caption: model.caption, embed: model.embed)
                ?? VoicePosts.shareText(caption: model.caption, voice: model.voice)
        )
        let sheet = ShareSheetViewController(
            card: card,
            imagePipeline: host.imagePipeline,
            targeting: host.shareTargeting,
            // Read HERE, where there is a window (the sheet has none yet).
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: host.view),
            fallbackWidth: host.view.bounds.width,
            // The app's appearance (#1718, the owner: no forced dark).
            configuration: ShareSheetConfiguration(extraActions: shareSheetActions(for: id))
        )
        sheet.onSystemShare = { [weak self] card, image in
            guard let self else { return }
            let activity = UIActivityViewController(
                activityItems: [ShareItemSource(card: card, icon: image), image], applicationActivities: nil
            )
            activity.popoverPresentationController?.sourceView = host.view
            host.present(activity, animated: true)
        }
        sheet.onSendToTarget = { [weak self] target, card in
            self?.host.viewModel.sendLink(card.url.absoluteString, to: target.id, stub: ProfileIdentityStub(
                handle: target.handle, displayName: target.displayName
            ))
        }
        host.present(sheet, animated: true)
    }

    /// The post sheet's own chips, after Share and Copy Link: Repost (#1710,
    /// Shots only since #1728), then Not interested and Report (#1712) — the
    /// old ⋯ menu's two, which live only here now: neither on a post no one
    /// may read (#1409), Report only with somewhere to file it. Both leave
    /// the sheet first.
    func shareSheetActions(for id: PostID) -> [ShareSheetAction] {
        // Repost on a text page, whose footer gave its place to the like
        // (#1924); a media post's toolbar carries it (#1728, the owner).
        var actions: [ShareSheetAction] = []
        if host.toolbarComposer.footerLikeFace?.id == id {
            actions.append(ShareSheetAction(title: "Repost", symbol: PostActionSymbol.repost, dismissesSheet: false) {
                [weak self] in self?.repostRequested()
            })
        }
        guard !host.unavailablePostIDs.contains(id) else { return actions }
        actions.append(ShareSheetAction(title: "Not interested", symbol: "hand.thumbsdown") { [weak self] in
            self?.markNotInterested(id)
        })
        if reporting != nil {
            actions.append(ShareSheetAction(title: "Report", symbol: "flag") { [weak self] in
                self?.presentReportReasons(for: id)
            })
        }
        return actions
    }

    /// Repost, from the share sheet (#1710). ⚠️ No client path publishes a
    /// repost yet (`PostComposer` takes no parent — the action column's old
    /// repost button had no action either), so the sheet says so instead of
    /// pretending.
    private func repostRequested() {
        // Over the sheet, which is still up.
        Feedback.info("Reposting is coming soon", symbol: PostActionSymbol.repost, from: host.presentedViewController ?? host)
    }

    /// The posts the viewer has asked not to see again, for as long as this
    /// screen lives.
    ///
    /// ⚠️ THE SESSION, AND NOTHING MORE — and the toast says exactly that.
    /// There is no "not interested" signal anywhere in the contracts: no
    /// ranking feedback in `timeline.v1`, no hide in `post.v1`. What this can
    /// honestly do is stop the post coming back on THIS surface, so that is
    /// what it does and what the confirmation claims. A toast promising a
    /// better feed tomorrow would be the lie.
    private(set) var notInterestedIDs: Set<PostID> = []

    private func markNotInterested(_ id: PostID) {
        notInterestedIDs.insert(id)
        // ⚠️ NOT REMOVED FROM UNDER THE VIEWER. The post is on screen, and
        // pulling the page they are reading out from under their thumb to
        // acknowledge a menu tap is a worse answer than the one they asked for.
        // The next render drops it — see `render(_:)` — so it goes when they
        // move on, which is when "not interested" means anything.
        //
        // With Undo (#957): nothing is sent either way (the hiding is this
        // screen's), so the commit is empty and Undo forgets the id. Not
        // rendered back at once: a post already dropped is one the viewer
        // moved past, and inserting it behind them would shift the page they
        // are on — the next render brings it back.
        Feedback.undoable(
            "Hidden from this feed", symbol: "hand.thumbsdown", from: host,
            commit: {},
            undo: { [weak self] in self?.notInterestedIDs.remove(id) }
        )
    }

    private func presentReportReasons(for id: PostID) {
        ReportReasonSheet.present(from: host, subject: "this post", sourceView: host.view) { [weak self] reason in
            self?.report(id, reason: reason)
        }
    }

    /// Files the report and says which way it went — a report the viewer
    /// believes was filed but wasn't is the worst outcome here.
    private func report(_ id: PostID, reason: ReportReason) {
        guard let reporting else { return }
        // Under way (#1775): said past the loader's grace, the answer in its place.
        let pending = PendingFeedback("Sending report…", from: host)
        Task {
            do {
                // The surface is a triage signal in its own right: the same post
                // reported from the feed and from a profile are different
                // reports.
                try await reporting.report(.post(id), reason: reason, surface: "ios.feed")
                pending.succeed("Report sent", symbol: "flag.fill")
            } catch {
                pending.fail("Couldn't send this report")
            }
        }
    }
}
