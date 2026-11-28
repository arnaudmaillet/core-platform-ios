import CoreModels
import CoreNavigation
import DesignSystem
import MediaCore
import PostGrid
import ProfileData
import ShareSheet
import UIKit

/// What the relation actions ask of their screen (#2522): the view model,
/// the header and the relationship it shows, what the share sheet is built
/// with, and the relationship's own path (`followTapped`). The screen itself
/// presents, anchors the toasts and walks the responder chain (`Feedback`,
/// `present`, `MemberGates.gate(from:)`, `ReportReasonSheet`,
/// `closeScreen()`), never this object.
@MainActor
protocol ProfileRelationActionsHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var headerView: ProfileHeaderView { get }
    var followButtonState: ProfileViewModel.FollowButton { get }
    var imagePipeline: ImagePipeline { get }
    var shareTargeting: (any ProfileShareTargeting)? { get }
    /// What the sheets and popovers anchor on: the page's view on the page
    /// (its ⋯ is a bar item, #2475), the card's view on the card.
    var actionAnchor: UIView { get }
    /// Where a block's toast is shown from — the screen that stays once
    /// the blocked profile has left: the page's stack, the card's
    /// presenter.
    var blockToastSource: UIViewController { get }
    /// Follow, Requested's withdrawal, and Unfollow: the member gate, the
    /// optimistic flip, its haptic — one path for every control.
    func followTapped()
    /// Message: the member gate, then the conversation.
    func messageTapped()
}

/// The profile's relation actions and what they do, out of
/// `ProfileViewController` (#2522): the relationship's bottom toolbar
/// (`ProfileRelationToolbar`, one source with the card's, #2475) and its
/// bell's Mute menu, the "…" menu and the map rails' rows, share, copy link,
/// block, report, the gallery rows' menus, the outcome of each command, the
/// Undo toast, and leaving after a block. The profile card uses it too, for
/// share, copy link, report, block, the outcomes and the Undo toast.
@MainActor
final class ProfileRelationActions {
    private unowned let host: any ProfileRelationActionsHost

    init(host: any ProfileRelationActionsHost) {
        self.host = host
    }

    /// Someone else's toolbar (#2475): the card's own items and rules.
    private(set) lazy var toolbar = ProfileRelationToolbar(actions: .init(
        follow: { [weak self] in self?.host.followTapped() },
        message: { [weak self] in self?.host.messageTapped() },
        qrCode: { [weak self] in self?.presentShareSheet() },
        openProfile: {},
        muteScopes: { [weak self] in self?.host.viewModel.muteScopes ?? .none },
        toggleMute: { [weak self] scope in self?.host.viewModel.toggleMute(scope) }
    ))

    #if DEBUG
    /// Mute-change toasts shown (#1951): their ARRIVAL, which a test cannot
    /// miss, where their presence on the bar lasts only a few seconds.
    private(set) var debugMuteToastsShown = 0
    /// The Undo toasts this screen has shown, and the latest — counted at
    /// their arrival: on a starved runner one can come and go between two
    /// looks (#1951). Tests.
    private(set) var debugUndoToastsShown = 0
    private(set) weak var debugLastUndoToast: ToastView?
    #endif

    /// The map rails' rows for the current state (`ProfileMenuBuilder`).
    func mapFavoriteMenuActions() -> [UIAction] {
        ProfileMenuBuilder.mapFavoriteMenuActions(host.viewModel.mapPinButton) { [weak self] category in
            self?.host.viewModel.toggleMapCategory(category)
        }
    }

    /// Whether the bell stands — in the toolbar, where Follow was, since
    /// #2302 (the owner, 2026-11-11): a profile the viewer FOLLOWS, in a
    /// composition that can mute, for a member (`ProfileRelationControl.showsMuteBell`).
    /// The same rule the see-more menu's Mute submenu had (#689): a guest has
    /// no account to mute from.
    ///
    /// ⚠️ NO BELL UNTIL THE READ SAYS FOLLOWING (the owner, 2026-10-18,
    /// #1398): there is nothing of theirs to mute until they are followed,
    /// and an unknown relationship is not "followed".
    private var showsMuteBell: Bool {
        guard !host.viewModel.namesNoOne else { return false }
        return ProfileRelationControl.showsMuteBell(
            followButton: host.followButtonState, canMute: host.viewModel.canMute,
            isGuest: MemberGates.gate(from: host)?.isMember == false
        )
    }

    /// The toolbar's items for the profile now: someone else's relationship
    /// (`ProfileRelationToolbar.items`), nothing for the viewer's own (its
    /// actions are its bar's, #2475) nor for a page for no one.
    var toolbarItems: [ProfileRelationToolbar.Item] {
        guard !host.viewModel.namesNoOne, host.followButtonState != .edit,
              !host.viewModel.isOwnProfile else { return [] }
        return ProfileRelationToolbar.items(
            for: host.followButtonState, showsBell: showsMuteBell,
            showsQR: host.viewModel.shareCard != nil || host.viewModel.profile == nil
        )
    }

    /// Someone else's bottom toolbar for the relationship (#2475): Follow or
    /// Requested beside Message's glyph, the bell once followed beside
    /// Message's word, the QR. On every change of the relationship, the
    /// scopes (on the tap, a refusal, an Undo, #2143), and the lookup's
    /// answer. Nothing changed, nothing is handed to the bar.
    func applyToolbar(animated: Bool) {
        let items = toolbarItems
        toolbar.apply(
            items, muteScopes: host.viewModel.muteScopes, bellEnabled: isMuteBellEnabled,
            to: host, animated: animated
        )
        // A toolbar that emptied (a page for no one) or filled on a screen
        // at rest on top goes away or comes up with it; appearances are the
        // screen's own (`viewWillAppear`, `viewWillDisappear`).
        guard let navigation = host.navigationController, navigation.topViewController === host,
              host.view.window != nil, host.transitionCoordinator == nil,
              navigation.isToolbarHidden != items.isEmpty else { return }
        navigation.setToolbarHidden(items.isEmpty, animated: animated)
    }

    /// Whether the bell can be used yet: a handle or link route has no one to
    /// mute until the relationship read says the lookup found someone else.
    private var isMuteBellEnabled: Bool {
        !host.viewModel.wasOpenedByReference || host.viewModel.canModerate
    }

    /// The scoped Mute menu for the current scopes (`ProfileMenuBuilder`).
    func muteMenuElements() -> [UIMenuElement] {
        ProfileMenuBuilder.muteMenuElements(host.viewModel.muteScopes) { [weak self] scope in
            self?.host.viewModel.toggleMute(scope)
        }
    }

    /// Wears the relationship on the header's avatar (#2014).
    func applyRelationMark() {
        host.headerView.configureRelationMark(
            host.followButtonState, mutual: host.viewModel.isMutualFollow, blocked: host.viewModel.isBlocked,
            isOwnProfile: host.viewModel.isOwnProfile
        )
    }

    /// An action shown with Undo (#957): its toast, from the screen.
    func presentUndoable(_ action: UndoableAction) {
        let toast = Feedback.undoable(
            action.message, symbol: action.symbol, from: host,
            commit: action.commit, undo: action.undo
        )
        #if DEBUG
        debugUndoToastsShown += 1
        debugLastUndoToast = toast
        #else
        _ = toast
        #endif
    }

    // MARK: - Overflow menu

    /// The ⋯ menu, its children built at OPEN time through an uncached
    /// deferred element (the feed's "..." precedent), not at wiring time:
    /// whether the moderation group belongs, and whether it reads Block or
    /// Unblock, depends on a relationship that usually resolves after this
    /// runs and can change while the screen is up.
    func makeMoreMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.moreMenuElements() ?? [])
            }
        ])
    }

    func moreMenuElements() -> [UIMenuElement] {
        ProfileMenuBuilder.moreMenuElements(
            ProfileMenuBuilder.MoreMenuState(
                canShare: host.viewModel.shareCard != nil,
                mapPin: host.viewModel.mapPinButton,
                canModerate: host.viewModel.canModerate,
                isGuest: MemberGates.gate(from: host)?.isMember == false,
                canRestrict: host.viewModel.canRestrict,
                isRestricted: host.viewModel.isRestricted,
                isBlocked: host.viewModel.isBlocked,
                canClearHistory: host.viewModel.isOwnProfile && host.viewModel.hasHistory,
                isFollowing: host.followButtonState == .following && !host.viewModel.namesNoOne,
                // The own profile's QR code is a row of its ⋯ (#2475);
                // someone else's is their toolbar's.
                showsQRCode: host.viewModel.isOwnProfile || host.followButtonState == .edit
            ),
            handlers: ProfileMenuBuilder.MoreMenuHandlers(
                share: { [weak self] in self?.presentShareSheet() },
                copyLink: { [weak self] in self?.copyProfileLink() },
                toggleMapCategory: { [weak self] category in self?.host.viewModel.toggleMapCategory(category) },
                report: { [weak self] in self?.presentReportReasons() },
                toggleRestrict: { [weak self] in self?.host.viewModel.toggleRestrict() },
                unblock: { [weak self] in self?.host.viewModel.unblock() },
                confirmBlock: { [weak self] in self?.confirmBlock() },
                clearHistory: { [weak self] in self?.confirmClearHistory() },
                unfollow: { [weak self] in self?.unfollowTapped() },
                qrCode: { [weak self] in self?.presentShareSheet() }
            )
        )
    }

    /// The "…" menu's Unfollow (#2302): the toolbar's own path — the member
    /// gate, the optimistic flip, the silent off (#1886) — only while the
    /// viewer still follows: a menu opened before a change must not follow
    /// back.
    private func unfollowTapped() {
        guard host.followButtonState == .following else { return }
        host.followTapped()
    }

    /// "Clear History" asks once (#1344): the list cannot be brought back.
    private func confirmClearHistory() {
        let alert = UIAlertController(
            title: "Clear History?",
            message: "Posts you watched will no longer appear in History.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Clear History", style: .destructive) { [weak self] _ in
            self?.host.viewModel.clearHistory()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        host.present(alert, animated: true)
    }

    /// Opens the unified share surface — the QR sheet — rather than jumping
    /// straight to the system share sheet. The toolbar's QR, the own ⋯'s QR
    /// Code and the menu's Share land here, so there is exactly one answer to "share this
    /// profile"; the system sheet is reachable from inside it.
    func presentShareSheet() {
        guard let card = host.viewModel.shareCard else { return }
        let sheet = ProfileShareViewController(
            card: card,
            imagePipeline: host.imagePipeline,
            targeting: host.shareTargeting,
            // Read HERE, where there is a window: the sheet has none until it
            // is already on screen, and reading it there made the corners snap
            // after the presentation animation instead of riding it.
            deviceCornerRadius: ScreenGeometry.cornerRadius(behind: host.view),
            // The sheet is full-width on iPhone, so this is its width for the
            // frames before it has been laid out.
            fallbackWidth: host.view.bounds.width
        )
        // Both escape hatches come back HERE, after the sheet has dismissed
        // itself: the system sheet would otherwise stack on top of this one,
        // and a pushed thread would land behind it.
        sheet.onSystemShare = { [weak self] card, image in
            self?.presentActivitySheet(for: card, image: image)
        }
        sheet.onSendToTarget = { [weak self] target, card in
            self?.host.viewModel.sendProfile(card, to: target)
        }
        host.present(sheet, animated: true)
    }

    /// The system share sheet, opened once the QR sheet is gone. Two items:
    /// the link (carrying the metadata that gives the sheet a branded header)
    /// and the rendered card — the image is what makes Save Image and image
    /// targets work, which is why this feature needs no photo-library
    /// permission of its own.
    private func presentActivitySheet(for card: ProfileViewModel.ShareCard, image: UIImage) {
        let source = ProfileShareItemSource(card: card, icon: image)
        let activity = UIActivityViewController(activityItems: [source, image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = host.actionAnchor
        host.present(activity, animated: true)
    }

    func copyProfileLink() {
        guard let link = host.viewModel.shareLink else { return }
        // Both slots: `.url` is what other apps paste as a rich link, `.string`
        // is what plain-text fields read. Setting only the former leaves a
        // Notes paste empty.
        UIPasteboard.general.url = link
        UIPasteboard.general.string = link.absoluteString
        Feedback.success("Link copied", symbol: "link", from: host)
    }

    /// Block is destructive and, here, one-way out of the screen — so it asks
    /// first. Named with the handle so it can't be answered on autopilot.
    ///
    /// An action sheet rather than an alert, because the question is not
    /// yes/no but *how far*: this app treats one account as owning several
    /// profiles (the switcher is a first-class affordance), so blocking one
    /// handle can leave the same person reaching the viewer from an alias.
    /// Two destructive options read as a scope choice; an alert's OK/Cancel
    /// shape would have to hide one of them behind a second step.
    func confirmBlock() {
        let handle = host.viewModel.handle ?? "this user"
        let sheet = UIAlertController(
            title: "Block \(handle)?",
            message: "They won't be able to find your profile or message you, and you'll stop seeing their posts. They aren't notified.\n\nBlocking the account also blocks any other profiles it owns.",
            preferredStyle: .actionSheet
        )
        // The narrow, predictable action leads: it is what "Block" meant
        // before this choice existed, and it is the one that can't overreach.
        sheet.addAction(UIAlertAction(title: "Block \(handle)", style: .destructive) { [weak self] _ in
            self?.host.viewModel.block(.profile)
        })
        sheet.addAction(UIAlertAction(title: "Block Account & All Profiles", style: .destructive) { [weak self] _ in
            self?.host.viewModel.block(.account)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = host.actionAnchor
        host.present(sheet, animated: true)
    }

    /// `moderation.v1.OpenCase` carries a policy category, so the report asks
    /// for one rather than filing everything as "other" — a category-less
    /// report is near-useless to the moderation queue.
    ///
    /// The picker itself now lives in `PostGrid`, beside the post card's "..."
    /// that raises the same question: two screens asking a viewer to classify
    /// a report must ask it in the same words, and the second copy would have
    /// been written the day the card grew a Report row.
    /// Report only — or, on the viewer's own post, Edit and Delete
    /// (`ProfileMenuBuilder.galleryMenuActions`).
    func galleryMenuActions(
        for context: PostGridAuthorMenuContext
    ) -> [PostCardMenuAction] {
        ProfileMenuBuilder.galleryMenuActions(
            isViewerPost: host.viewModel.isViewerPost(by: context.authorID),
            canReport: host.viewModel.canReportPost(by: context.authorID),
            // At once, with Undo in the toast (#957) — no confirmation sheet.
            onDelete: { [weak self] in self?.host.viewModel.deletePost(context.post.id) },
            onReport: { [weak self] in self?.presentPostReportReasons(for: context) }
        )
    }

    /// The same question, asked of a post instead of the profile — and asked by
    /// the same picker, anchored on the row's own "..." rather than on the
    /// header's.
    private func presentPostReportReasons(
        for context: PostGridAuthorMenuContext
    ) {
        ReportReasonSheet.present(
            from: host, subject: "this post", sourceView: context.anchor
        ) { [weak self] reason in
            self?.host.viewModel.reportPost(context.post.id, reason: reason)
        }
    }

    func presentReportReasons() {
        ReportReasonSheet.present(
            from: host,
            subject: host.viewModel.handle ?? "this profile",
            sourceView: host.actionAnchor
        ) { [weak self] reason in
            self?.host.viewModel.report(reason)
        }
    }

    /// Reports the outcome of a menu command. Confirmations are toasts (the
    /// action is already done — an alert would only demand a second tap);
    /// failures are alerts, because a failed block or report is something the
    /// user must know to retry.
    func render(_ result: ProfileViewModel.ActionResult) {
        switch result {
        case .blocked(let handle, let profileCount):
            // Says what was actually blocked, not what was asked for: an
            // account-scoped block can only reach the aliases the fleet let us
            // see, so claiming "and all their profiles" would be a promise the
            // client can't keep (see `ProfileBlockScope`).
            let message = profileCount > 1
                ? "Blocked \(handle) and \(profileCount - 1) more"
                : "Blocked \(handle)"
            // Sourced from the navigation controller, not this screen: the
            // block pops this view controller in the same turn, and a toast
            // parented here would leave with it.
            Feedback.success(message, symbol: "hand.raised.fill", from: host.blockToastSource)
        case .unblocked(let handle):
            Feedback.success("Unblocked \(handle)", symbol: "hand.raised.slash.fill", from: host)
            // Unblocked, the "+" is back (#2014): the button never moved.
            applyRelationMark()
        case .muteChanged(let handle, let scopes):
            #if DEBUG
            debugMuteToastsShown += 1
            #endif
            Feedback.success(
                ProfileViewModel.muteMessage(handle: handle, scopes: scopes),
                symbol: scopes.isEmpty ? "speaker.wave.2.fill" : "speaker.slash.fill",
                from: host
            )
        case .restrictChanged(let handle, let restricted):
            Feedback.success(
                restricted ? "Restricted \(handle)" : "Unrestricted \(handle)",
                symbol: restricted ? "person.crop.circle.badge.minus" : "person.crop.circle.badge.checkmark",
                from: host
            )
        case .commitFailed(let message):
            // Already put back on screen (#957): say why it came back.
            Feedback.failure(message, from: host)
        case .reported:
            Feedback.success("Report sent", symbol: "flag.fill", from: host)
        case .followFailed(let message):
            // A toast, not the alert below: the button has already flipped
            // back, so there is nothing to decide — only why it moved (#802).
            Feedback.failure(message, from: host)
        case .failed(let message):
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            host.present(alert, animated: true)
        }
    }

    /// Leaves the blocked profile: pop when pushed (the common case — a profile
    /// reached by routing), dismiss when presented. A tab-root profile is left
    /// standing, but it can't get here: own profiles can't be blocked.
    func leaveAfterBlock() {
        // An open menu-spawned alert would otherwise ride out the pop.
        if let alert = host.presentedViewController { host.dismiss(presented: alert, animated: false) }
        // THIS profile, wherever it is now (#1144): the block answered after
        // an `await`, and the viewer may have gone back or pushed on since —
        // a plain pop would have closed that other screen.
        host.closeScreen()
    }
}
