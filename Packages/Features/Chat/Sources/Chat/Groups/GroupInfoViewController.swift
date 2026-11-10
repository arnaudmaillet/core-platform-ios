import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import HeroPage
import MediaCore
import UIKit

/// A group's info screen (#2214), pushed from its thread's header — since
/// #2237 the profile's and the place's page drawing a group
/// (`ConversationInfoPageViewController`):
///
/// - the header: the photo or the initials, the name, "Private group" or
///   "Public group", the description, a public group's link, the counters
///   (Members, Admins, Requests, Followers) and the action row (Edit and
///   Add Members for owner and admins; Join and Follow for an outsider of a
///   public group);
/// - the counters open the lists, paged, each row's "⋯" what the viewer may
///   do to them;
/// - the bell in the bar, the rest in its "⋯" — Visibility, Transfer
///   Ownership, then Unfollow or Leave, last, in red;
/// - Posts under the header: the posts that showcase the group, until then
///   its empty state.
///
/// Every rule — who edits, who manages whom, whether the owner may leave —
/// is the view model's; this draws what it is told.
final class GroupInfoViewController: ConversationInfoPageViewController {
    private let viewModel: GroupInfoViewModel
    private var state = GroupInfoViewModel.State()

    /// A person's row, or a name, was tapped: their profile.
    var onOpenProfile: ((ProfileID, String) -> Void)?
    /// "Add Members": the host presents the picker over `presenter`, and
    /// hands back who was picked.
    var onAddMembers: ((_ presenter: UIViewController, _ excluded: Set<ProfileID>, _ memberCount: Int,
                        _ completion: @escaping ([ProfileID]) -> Void) -> Void)?
    /// The viewer left: the host takes them back to the inbox.
    var onLeft: (() -> Void)?

    /// - Parameter postsPage: the page under the header, from the page
    ///   factory the profile and the place use; nil draws its status alone.
    init(viewModel: GroupInfoViewModel, imagePipeline: ImagePipeline?, postsPage: (any PostGridPage)? = nil) {
        self.viewModel = viewModel
        super.init(channel: false, postsPage: postsPage ?? ConversationStatusPage(), imagePipeline: imagePipeline)
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

    private func render(_ next: GroupInfoViewModel.State) {
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
        // A member and a follower hear the group: the bell; an outsider
        // has nothing to mute.
        applyBar(muted: next.isMember || next.isFollower ? next.isMuted : nil)
        showPosts(ConversationInfoPosts.status(channel: false, manages: next.canEdit, canShareAsPost: false))
    }

    // MARK: - What the page asks

    override func listTabs() -> [PersonListTab] { GroupInfoViewModel.listTabs(for: state) }

    override func moreMenuElements() -> [UIMenuElement] {
        var plain: [UIMenuElement] = []
        var ways: [UIMenuElement] = []
        for entry in GroupInfoViewModel.menu(for: state) {
            switch entry {
            case .visibility:
                plain.append(UIMenu(
                    title: "Visibility", subtitle: GroupCopy.visibilityTitle(state.visibility),
                    image: UIImage(systemName: state.visibility == .public ? "globe" : "lock"),
                    children: GroupCopy.choosableVisibilities.map { choice in
                        UIAction(
                            title: GroupCopy.visibilityTitle(choice), subtitle: GroupCopy.visibilityExplanation(choice),
                            state: choice == state.visibility ? .on : .off
                        ) { [weak self] _ in self?.confirmVisibility(choice) }
                    }
                ))
            case .transferOwnership:
                // Handing over is a member's own menu ("Make Owner"): the
                // members, where it is.
                plain.append(UIAction(title: "Transfer Ownership", image: UIImage(systemName: "person.crop.circle.badge.checkmark")) {
                    [weak self] _ in self?.openLists(.members)
                })
            case .unfollow:
                ways.append(UIAction(title: "Unfollow", image: UIImage(systemName: "minus.circle"), attributes: .destructive) {
                    [weak self] _ in self?.confirmUnfollow()
                })
            case .leave:
                ways.append(UIAction(
                    title: "Leave Group", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive
                ) { [weak self] _ in self?.confirmLeave() })
            case .shareAsPost:
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
                title: "Edit Group", fields: .init(name: state.ownName, description: state.description),
                photoURL: state.photoURL, requiresName: false, namePlaceholder: "Group name"
            ) { [weak self] fields in self?.viewModel.editIdentity(name: fields.name, description: fields.description) }
        case .addMembers:
            addMembers(from: presenter)
        case .join:
            viewModel.join()
        case .follow:
            viewModel.follow()
        case .share:
            if let url = shownHeader?.linkURL { share(url, from: view) }
        case .invite, .requestToJoin, .requested:
            break
        }
    }

    override func openProfile(_ id: ProfileID, name: String) { onOpenProfile?(id, name) }
    override func setMute(_ muted: Bool, until: Date?) { viewModel.setMute(muted, until: until) }
    override func reloadAll() { viewModel.load() }

    // MARK: - The lists

    override func listPage(of list: ConversationInfoList, after token: String?) async throws -> PersonListPage {
        try await viewModel.page(of: list, after: token)
    }

    override func listRowAction(_ action: PersonListRowAction, on row: PersonListRow, in list: ConversationInfoList) {
        guard let memberAction = GroupInfoViewModel.MemberAction(rawValue: action.id) else { return }
        confirm(memberAction, on: ProfileID(row.id), name: row.name)
    }

    override func listAnswer(_ row: PersonListRow, approve: Bool) {
        viewModel.answer(ProfileID(row.id), approve: approve)
    }

    override func listLeadingAction(in list: ConversationInfoList, from screen: PersonListsViewController) {
        guard list == .members else { return }
        addMembers(from: screen)
    }

    private func addMembers(from presenter: UIViewController) {
        onAddMembers?(presenter, viewModel.memberIDs, state.memberCount) { [weak self] ids in self?.viewModel.add(ids) }
    }

    // MARK: - Asked first

    /// A switch is asked first (#2217): going public warns that what is said
    /// from now on becomes readable by anyone; going private, that its
    /// followers lose it.
    private func confirmVisibility(_ choice: ConversationVisibility) {
        guard choice != state.visibility else { return }
        let question = GroupCopy.visibilityConfirmation(choice)
        let alert = UIAlertController(title: question.title, message: question.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: question.button, style: choice == .private ? .destructive : .default) {
            [weak self] _ in self?.viewModel.setVisibility(choice)
        })
        presenter.present(alert, animated: true)
    }

    /// Handing the group over, removing and banning are asked twice.
    private func confirm(_ action: GroupInfoViewModel.MemberAction, on id: ProfileID, name: String) {
        let question: (title: String, message: String, button: String)? = switch action {
        case .transferOwnership:
            ("Make \(name) the owner?", "You'll become an admin. Only the owner can hand the group over.", "Make Owner")
        case .remove:
            ("Remove \(name)?", "They can be invited again later.", "Remove")
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
        if GroupInfoViewModel.leaveBlockedReason(for: state.viewerRole) != nil { return viewModel.leave() }
        let alert = UIAlertController(
            title: "Leave \(state.name)?", message: "You won't get its messages any more.", preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.viewModel.leave() })
        presenter.present(alert, animated: true)
    }

    private func confirmUnfollow() {
        let alert = UIAlertController(
            title: "Unfollow \(state.name)?", message: "You won't see what's said here any more.", preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unfollow", style: .destructive) { [weak self] _ in self?.viewModel.unfollow() })
        presenter.present(alert, animated: true)
    }
}
