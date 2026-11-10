import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import UIKit

/// A channel's info screen (#2215), pushed from its thread's header — since
/// #2237 the profile's and the place's page drawing a channel
/// (`ConversationInfoPageViewController`):
///
/// - the header: the photo or the initials, the name and its megaphone,
///   "Public channel · by @owner" (the owner opens their profile), the
///   description, the channel's link, the counters (Subscribers, Admins,
///   Requests) and the action row (Edit and Invite for owner and admins;
///   Join, Request to Join or Requested for an outsider);
/// - the counters open the lists, paged — the subscribers and the requests
///   for owner and admins, the admins for anyone in;
/// - the bell in the bar, the rest in its "⋯" — Share as a Post (#2216),
///   Visibility, Transfer Ownership, then Leave, last, in red;
/// - Posts under the header: the posts that showcase the channel, until
///   then its empty state, which offers owner and admins to make the first.
///
/// Every rule is the view model's; this draws what it is told.
final class ChannelInfoViewController: ConversationInfoPageViewController {
    private let viewModel: ChannelInfoViewModel
    private var state = ChannelInfoViewModel.State()

    /// A person's row, or the owner's name: their profile.
    var onOpenProfile: ((ProfileID, String) -> Void)?
    /// The viewer left: the host takes them back.
    var onLeft: (() -> Void)?
    /// "Share as a Post" (#2216): the host opens the Text Post screen with
    /// the channel's card (`AppRoute.composeShowcase`).
    var onShareAsPost: ((PostEmbed) -> Void)?

    /// - Parameter postsPage: the page under the header, from the page
    ///   factory the profile and the place use; nil draws its status alone.
    init(viewModel: ChannelInfoViewModel, imagePipeline: ImagePipeline?, postsPage: (any PostGridPage)? = nil) {
        self.viewModel = viewModel
        super.init(channel: true, postsPage: postsPage ?? ConversationStatusPage(), imagePipeline: imagePipeline)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.onStateChange = { [weak self] state in self?.render(state) }
        viewModel.onNotice = { [weak self] title, message in self?.presentNotice(title, message) }
        viewModel.onFailure = { [weak self] message in
            guard let self else { return }
            Feedback.failure(message, from: presenter)
        }
        viewModel.onLeft = { [weak self] in self?.onLeft?() }
        viewModel.onPeopleChange = { [weak self] in self?.reloadLists() }
        if viewModel.state.phase == .loading { heroHeader.setRedacted(true) }
        render(viewModel.state)
        viewModel.load()
    }

    // MARK: - Render

    private func render(_ next: ChannelInfoViewModel.State) {
        guard isViewLoaded else { return }
        let wasLoaded = state.phase == .loaded
        state = next
        switch next.phase {
        case .loading:
            hideFailure()
            return
        case .failed(let message):
            if !wasLoaded { showFailure(message) }
            return
        case .loaded:
            hideFailure()
        }
        apply(viewModel.header)
        if !wasLoaded { heroHeader.setRedacted(false, animated: view.window != nil) }
        // Anyone in hears the channel: the bell.
        applyBar(muted: next.isIn ? next.isMuted : nil)
        showPosts(ConversationInfoPosts.status(channel: true, manages: next.canEdit, canShareAsPost: next.canShareAsPost))
    }

    // MARK: - What the page asks

    override func listTabs() -> [PersonListTab] { ChannelInfoViewModel.listTabs(for: state) }

    override func moreMenuElements() -> [UIMenuElement] {
        var plain: [UIMenuElement] = []
        var ways: [UIMenuElement] = []
        for entry in ChannelInfoViewModel.menu(for: state) {
            switch entry {
            case .shareAsPost:
                plain.append(UIAction(title: ChannelShowcase.shareTitle, image: UIImage(systemName: ChannelShowcase.shareSymbol)) {
                    [weak self] _ in self?.shareAsPost()
                })
            case .visibility:
                plain.append(UIMenu(
                    title: "Who Can Join", subtitle: ChannelCopy.visibilityTitle(state.visibility),
                    image: UIImage(systemName: state.visibility == .public ? "globe" : "hand.raised"),
                    children: ChannelCopy.choosableVisibilities.map { choice in
                        UIAction(
                            title: ChannelCopy.visibilityTitle(choice), subtitle: ChannelCopy.visibilityExplanation(choice),
                            state: choice == state.visibility ? .on : .off
                        ) { [weak self] _ in self?.viewModel.setVisibility(choice) }
                    }
                ))
            case .transferOwnership:
                // The owner hands the channel to an admin, from the admin's
                // own menu ("Make Owner"): the admins, where it is.
                plain.append(UIAction(title: "Transfer Ownership", image: UIImage(systemName: "person.crop.circle.badge.checkmark")) {
                    [weak self] _ in self?.openLists(.admins)
                })
            case .leave:
                ways.append(UIAction(
                    title: "Leave Channel", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive
                ) { [weak self] _ in self?.confirmLeave() })
            case .unfollow:
                break
            }
        }
        var sections: [UIMenuElement] = []
        if !plain.isEmpty { sections.append(UIMenu(options: .displayInline, children: plain)) }
        if !ways.isEmpty { sections.append(UIMenu(options: .displayInline, children: ways)) }
        return sections
    }

    override func didTap(_ action: ConversationInfoAction, from view: UIView) {
        switch action {
        case .edit:
            presentEditor(
                title: "Edit Channel", fields: .init(name: state.name, description: state.description),
                photoURL: state.photoURL, requiresName: true, namePlaceholder: "Channel name"
            ) { [weak self] fields in self?.viewModel.editIdentity(name: fields.name, description: fields.description) }
        case .invite, .share:
            if let url = shownHeader?.linkURL { share(url, from: view) }
        case .join, .requestToJoin:
            viewModel.join()
        case .requested:
            confirmCancelRequest()
        case .addMembers, .follow:
            break
        }
    }

    override func openProfile(_ id: ProfileID, name: String) {
        let shown = name.isEmpty && id == state.owner?.id ? state.owner?.name ?? "" : name
        onOpenProfile?(id, shown)
    }

    override func setMute(_ muted: Bool, until: Date?) { viewModel.setMute(muted, until: until) }
    override func reloadAll() { viewModel.load() }
    override func postsActionTapped() { shareAsPost() }

    /// The Text Post screen, the channel's card attached (#2216).
    private func shareAsPost() {
        guard let embed = viewModel.showcaseEmbed else { return }
        onShareAsPost?(embed)
    }

    // MARK: - The lists

    override func listPage(of list: ConversationInfoList, after token: String?) async throws -> PersonListPage {
        try await viewModel.page(of: list, after: token)
    }

    override func listRowAction(_ action: PersonListRowAction, on row: PersonListRow, in list: ConversationInfoList) {
        guard let memberAction = ChannelInfoViewModel.MemberAction(rawValue: action.id) else { return }
        confirm(memberAction, on: ProfileID(row.id), name: row.name)
    }

    override func listAnswer(_ row: PersonListRow, approve: Bool) {
        viewModel.answer(ProfileID(row.id), approve: approve)
    }

    override func listLeadingAction(in list: ConversationInfoList, from screen: PersonListsViewController) {
        switch list {
        case .subscribers:
            if let url = AppRoute.conversationLink(viewModel.conversationID) { share(url, from: screen.view) }
        case .admins:
            presentAdminPicker(from: screen)
        default:
            break
        }
    }

    /// "Add Admin": the owner picks among the subscribers (#2215).
    private func presentAdminPicker(from screen: UIViewController) {
        Task { [weak self] in
            guard let self else { return }
            let candidates = await viewModel.adminCandidates()
            guard !candidates.isEmpty else {
                return presentNotice("No one to add yet", "Admins are chosen among the channel's subscribers.")
            }
            let sheet = UIAlertController(title: "Add Admin", message: "Admins post and answer join requests.", preferredStyle: .actionSheet)
            for row in candidates {
                sheet.addAction(UIAlertAction(title: row.name, style: .default) { [weak self] _ in
                    self?.viewModel.perform(.makeAdmin, on: row.id)
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = screen.view
            screen.present(sheet, animated: true)
        }
    }

    // MARK: - Asked first

    /// Handing the channel over, removing and banning are asked twice.
    private func confirm(_ action: ChannelInfoViewModel.MemberAction, on id: ProfileID, name: String) {
        let question: (title: String, message: String, button: String)? = switch action {
        case .transferOwnership:
            ("Make \(name) the owner?", "You'll become an admin. Only the owner can hand the channel over.", "Make Owner")
        case .remove:
            ("Remove \(name)?", "They can join again later.", "Remove")
        case .ban:
            ("Remove and ban \(name)?", "They won't be able to join again.", "Remove and Ban")
        case .makeAdmin, .removeAdmin:
            nil
        }
        guard let question else { return viewModel.perform(action, on: id) }
        let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: question.button, style: action == .transferOwnership ? .default : .destructive) {
            [weak self] _ in self?.viewModel.perform(action, on: id)
        })
        presenter.present(alert, animated: true)
    }

    private func confirmLeave() {
        if ChannelCopy.leaveBlockedReason(for: state.viewerRole) != nil { return viewModel.leave() }
        let alert = UIAlertController(
            title: ChannelCopy.leaveTitle(state.name), message: ChannelCopy.leaveMessage, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.viewModel.leave() })
        presenter.present(alert, animated: true)
    }

    private func confirmCancelRequest() {
        let alert = UIAlertController(title: "Cancel your request?", message: "You can ask again later.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        alert.addAction(UIAlertAction(title: "Cancel Request", style: .destructive) { [weak self] _ in
            self?.viewModel.cancelJoinRequest()
        })
        presenter.present(alert, animated: true)
    }
}

#if DEBUG
extension ChannelInfoViewController {
    /// Whether the "⋯" offers "Share as a Post" now (#2216).
    var debugOffersShareAsPost: Bool { ChannelInfoViewModel.menu(for: state).contains(.shareAsPost) }
    /// A pick of "Share as a Post", as the menu's entry does.
    func debugShareAsPost() { shareAsPost() }
}
#endif
