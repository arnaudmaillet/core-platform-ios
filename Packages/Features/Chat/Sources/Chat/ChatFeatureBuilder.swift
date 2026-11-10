import ChatInterface
import CoreModels
import CoreStorage
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MediaCore
import UIKit

/// The chat feature's entry point, resolved by the composition root and
/// consumed through `ChatFeatureBuilding` by the app shell.
@MainActor
public struct ChatFeatureBuilder: ChatFeatureBuilding {
    private let repository: any ChatProviding
    private let connections: (any SuggestionsProviding)?
    /// The compose picker's search backing. Optional like `connections`: a
    /// composition without it still opens the picker, which then browses
    /// recents and suggestions and simply finds nothing when typed into.
    private let people: (any PeopleDirectoryProviding)?
    private let imagePipeline: ImagePipeline?
    private let router: (any Router)?
    /// The SAME history the global search screen writes to.
    private let recentSearches: RecentSearchStore?
    /// Shared list→thread warm-start context (the builder is a long-lived
    /// singleton in the container, so this is one directory app-wide).
    private let directory: ConversationDirectory
    /// The inbox's store, owned here rather than per-inbox so that a thread
    /// pushed later — built by an entirely separate call — can report back
    /// into the same one. Without that, reading a thread has no way to reach
    /// the list it should disappear from.
    private let catalog: InboxCatalog
    /// Who draws a conversation: Feed's text-post screen, driven from here. A
    /// closure rather than the value because the Feed builder reaches the
    /// router, and the router reaches this — the same lazy edge Maps takes to
    /// the feed.
    private let threadScreens: () -> any ConversationThreadScreenBuilding
    /// The thread's camera and library (#681); nil sends text only.
    private let mediaPicker: ChatMediaPickerFactory?
    /// The inbox and the last conversations on the device (#897).
    private let deviceCache: ChatLocalCache?
    /// The peers' relations, for the rows' mark and its "+" (#2049): the
    /// inbox's and its search's, over the app's `EntityStore`.
    private let relations: InboxRelations?
    /// Groups (#2214, `-group-chats`): creating one, its thread's senders,
    /// its info screen. Nil — the flag off, or a repository with no groups —
    /// and Messages is DMs only, as it was.
    private let groups: (any GroupChatServicing)?
    /// Channels (#2215, `-channels`): their rows in Chats (#2230), creating
    /// one from the "+" menu and the inbox search, its thread's reader bar,
    /// its info screen, and the join requests in Requests. Nil — the flag
    /// off, or a repository with no channels — and Messages has none of it,
    /// as it was.
    private let channels: (any GroupChatServicing)?
    /// "Share as a Post" on a channel's creation and info screens (#2216):
    /// with the channels (`-channels`), which draw showcases.
    private let sharesShowcases: Bool
    /// What this session did to groups that the server doesn't say yet.
    private let groupNotes = GroupSessionNotes()
    /// The Posts page under a group's or a channel's info header (#2237):
    /// Feed's own grid page, the factory the profile and the place use,
    /// handed by the app. Nil (a test) draws the page's status alone.
    private let postsPage: (() -> any PostGridPage)?

    /// `localStore`: the inbox opens on its last rows and a conversation on
    /// its last 200 messages, offline and at a cold start (#897). Nil keeps
    /// them in memory.
    public init(
        repository: any ChatProviding,
        connections: (any SuggestionsProviding)? = nil,
        people: (any PeopleDirectoryProviding)? = nil,
        imagePipeline: ImagePipeline? = nil,
        router: (any Router)? = nil,
        recentSearches: RecentSearchStore? = nil,
        mediaPicker: ChatMediaPickerFactory? = nil,
        localStore: LocalStore? = nil,
        relations: InboxRelations? = nil,
        showsGroups: Bool = DebugFlags.isOn("-group-chats"),
        showsChannels: Bool = DebugFlags.isOn("-channels"),
        postsPage: (() -> any PostGridPage)? = nil,
        threadScreens: @escaping () -> any ConversationThreadScreenBuilding
    ) {
        self.postsPage = postsPage
        groups = showsGroups ? repository as? any GroupChatServicing : nil
        channels = showsChannels ? repository as? any GroupChatServicing : nil
        sharesShowcases = showsChannels
        self.threadScreens = threadScreens
        self.relations = relations
        self.mediaPicker = mediaPicker
        let directory = ConversationDirectory()
        self.directory = directory
        let deviceCache = localStore.map(ChatLocalCache.init(store:))
        self.deviceCache = deviceCache
        catalog = InboxCatalog(repository: repository, directory: directory, deviceCache: deviceCache)
        self.repository = repository
        self.connections = connections
        self.people = people
        self.imagePipeline = imagePipeline
        self.router = router
        self.recentSearches = recentSearches
    }

    /// Assembles the inbox: one catalog shared by the two conversation-backed
    /// surfaces (so the inbox loads once, not once per tab), an independent
    /// suggestions surface, and the container that pages between them.
    /// Loads the inbox in the background so the tab bar's badge is right on a
    /// cold launch. See `ChatFeatureBuilding.primeInbox`.
    public func primeInbox() {
        catalog.reload()
    }

    public func forgetViewer() {
        catalog.reset()
        directory.forgetAll()
    }

    /// The showcase card's actions (#2216), with the channels on: over the
    /// same repository Chats reads, reloading its catalog when the viewer's
    /// standing changes. A channel joined from its card joins muted (#2230).
    public func makeChannelEmbedActions() -> (any ChannelEmbedActing)? {
        guard let channels else { return nil }
        return ChannelEmbedActions(
            service: channels, router: router,
            membershipDidChange: { [catalog] in catalog.reload() },
            didSubscribe: { [catalog] id in catalog.setMute(id, muted: true, until: nil) }
        )
    }

    /// A profile's channels (#2232), with the channels on: the read behind
    /// its Channels tab, over the same repository. Nil with them off — no
    /// profile then has the tab.
    public func makeProfileChannels() -> (any ProfileChannelsProviding)? {
        guard channels != nil, let reader = repository as? any ProfileChannelsReading else { return nil }
        return ProfileChannels(service: reader)
    }

    public func makeInboxViewController(
        initialCategory: MessagesCategory,
        onUnreadCountChange: ((Int) -> Void)? = nil
    ) -> UIViewController {
        let conversations = ConversationListViewController(
            viewModel: ConversationListViewModel(catalog: catalog, router: router),
            imagePipeline: imagePipeline,
            // The suggestions repository doubles as the avatar source: it
            // already caches the profiles these rows need, and the two
            // surfaces are one tab apart.
            avatars: connections as? any PeerAvatarProviding,
            relations: relations
        )
        // Context-menu previews show the real thread screen in `.preview`
        // mode: same transcript construction as the router's `.conversation`
        // push, minus the compose bar (typing is impossible in a peek).
        // One provider, both surfaces: the peek is the real thread screen in
        // `.preview` mode, and Requests earns the same long-press as All.
        // The peek's view model is built WITHOUT the inbox callbacks: a peek
        // is not a read.
        let makeThreadPreview: (ConversationID) -> UIViewController = { [self] id in
            let viewModel = ConversationViewModel(
                conversationID: id,
                repository: repository,
                directory: directory,
                router: router
            )
            viewModel.deviceCache = deviceCache
            return makeThreadScreen(viewModel, mode: .preview, prefill: "")
        }
        conversations.threadPreviewProvider = makeThreadPreview

        // The channels' join requests, Requests' first section (#2230).
        let joinRequests = channels.map { ChannelJoinRequestsDigest(catalog: catalog, service: $0) }
        let requestsModel = MessageRequestsViewModel(catalog: catalog, router: router, joinRequests: joinRequests)
        let requests = MessageRequestsViewController(
            viewModel: requestsModel,
            imagePipeline: imagePipeline,
            avatars: connections as? any PeerAvatarProviding,
            // The faces wear the relation mark, as All's (#2088).
            relations: relations
        )
        requests.threadPreviewProvider = makeThreadPreview
        // A channel's join requests, pushed: answered there, its row in
        // Requests counts again (#2230).
        requests.onOpenJoinRequests = { [self, weak requestsModel] presenter, channel in
            let list = makeJoinRequests([channel]) { requestsModel?.refreshJoinRequests() }
            presenter.navigationController?.pushViewController(list, animated: true)
        }
        // The owner who asked to leave a channel from its row: its info
        // screen, where they hand it over (#2230).
        if channels != nil {
            conversations.onOpenChannelInfo = { [self] presenter, id in
                presenter.navigationController?.pushViewController(makeChannelInfo(id, onChange: {}), animated: true)
            }
        }
        // The Hidden requests list (#552): the same screen over the hidden
        // folder of the same catalog, so accepting one there lands in All.
        requests.hiddenRequestsProvider = { [self] in
            let hidden = MessageRequestsViewController(
                viewModel: MessageRequestsViewModel(catalog: catalog, router: router, folder: .hiddenRequests),
                imagePipeline: imagePipeline,
                avatars: connections as? any PeerAvatarProviding,
                relations: relations
            )
            hidden.threadPreviewProvider = makeThreadPreview
            return hidden
        }
        let suggestions = SuggestionsViewController(
            viewModel: SuggestionsViewModel(
                repository: connections ?? EmptySuggestionsRepository(),
                router: router,
                deviceCache: deviceCache
            ),
            imagePipeline: imagePipeline
        )

        // Global search over the same catalog the surfaces share, so a query
        // costs no fetch for its two conversation sections — the inbox is
        // already in memory and is simply narrowed.
        let searchViewModel = InboxSearchViewModel(
            catalog: catalog,
            viewer: repository,
            people: people,
            recents: recentSearches
        )
        let searchResults = InboxSearchResultsViewController(
            viewModel: searchViewModel,
            imagePipeline: imagePipeline,
            avatars: connections as? any PeerAvatarProviding,
            relations: relations
        )
        // A target, not a conversation — the same seam the compose picker rides,
        // so a result opens by exactly the path a picked contact does and neither
        // waits on a round trip.
        searchViewModel.onOpenConversation = { [router] target in
            switch target {
            case .existing(let conversationID):
                router?.route(to: .conversation(conversationID))
            case .draft(let peer, let displayName, let handle):
                router?.route(to: .messageUser(peer, stub: ProfileIdentityStub(
                    handle: handle, displayName: displayName
                )))
            }
        }

        // Three pages (#2230): the channels are in Chats.
        let inbox = MessagesInboxViewController(
            surfaces: [conversations, requests, suggestions],
            searchResults: searchResults,
            initialCategory: initialCategory
        )
        inbox.onTotalNewCountChange = onUnreadCountChange
        // "New group" in the empty search (#2214): the member picker, over
        // the inbox.
        if groups != nil {
            searchViewModel.onNewGroup = { [weak inbox, self] in
                guard let inbox else { return }
                presentGroupCreation(from: inbox)
            }
        }
        // "New channel" beside it (#2230): the creation sheet, over the
        // inbox; Create pushes the channel's thread there.
        if channels != nil {
            searchViewModel.onNewChannel = { [weak inbox, self] in
                guard let inbox, let sheet = makeChannelCreationSheet(landing: .onTheStack) else { return }
                inbox.present(sheet, animated: true)
            }
        }
        return inbox
    }

    // MARK: - Channels (#2215, #2230)

    /// Where Create leaves the viewer (#2230).
    nonisolated enum ChannelLanding: Equatable, Sendable {
        /// From the "+" menu: Messages, on Chats, the thread pushed over it —
        /// the app's cross-tab routes (`.messages(.all)`, then
        /// `.conversation`). The back chevron returns to Chats: a native
        /// push closes with a native pop.
        case inMessages
        /// From the inbox search: the thread pushed on the stack the inbox
        /// is on, as a new group's is.
        case onTheStack
    }

    /// The new channel's sheet, for the "+" menu (#2230); nil with the
    /// channels off — the menu then has no entry for it. Presented over the
    /// shell like the menu's other destinations.
    public func makeChannelCreationViewController() -> UIViewController? {
        makeChannelCreationSheet(landing: .inMessages)
    }

    /// The new channel's sheet: what a channel is, its name, description and
    /// who may join; Create closes it and lands in the channel's thread,
    /// opened by "You created the channel". A channel the viewer creates is
    /// not muted (#2230): they are the one posting.
    func makeChannelCreationSheet(landing: ChannelLanding) -> UINavigationController? {
        guard let channels else { return nil }
        let creation = ChannelCreationViewModel(service: channels, sharesShowcases: sharesShowcases)
        let screen = ChannelCreationViewController(viewModel: creation)
        let sheet = UINavigationController(rootViewController: screen)
        screen.onCancel = { [weak sheet] in _ = sheet?.closePresentation() }
        // Closes the sheet, then routes: a route fired under a sheet on its
        // way out would land behind it.
        let leave: @MainActor ([AppRoute]) -> Void = { [weak sheet, router] routes in
            guard let sheet else {
                routes.forEach { router?.route(to: $0) }
                return
            }
            _ = sheet.closePresentation { routes.forEach { router?.route(to: $0) } }
        }
        creation.onCreated = { [catalog, groupNotes, sharesShowcases] id in
            groupNotes.created[id] = Date()
            // Chats, behind the thread, lists it.
            catalog.refresh()
            // Without the showcases, straight into the thread, as before;
            // with them, the last step's buttons choose (#2216).
            if !sharesShowcases { leave(Self.landingRoutes(for: id, landing: landing)) }
        }
        screen.onOpen = { id in leave(Self.landingRoutes(for: id, landing: landing)) }
        // "Share as a Post" lands in the thread, then opens the Text Post
        // screen over it with the channel's card (#2216).
        screen.onShareAsPost = { id, embed in
            leave(Self.landingRoutes(for: id, landing: landing) + [.composeShowcase(embed)])
        }
        return sheet
    }

    /// The routes Create takes to the new channel (#2230). Pure, for tests.
    nonisolated static func landingRoutes(for id: ConversationID, landing: ChannelLanding) -> [AppRoute] {
        switch landing {
        case .inMessages: [.messages(.all), .conversation(id)]
        case .onTheStack: [.conversation(id)]
        }
    }

    /// The join requests of `runChannels` (#2215); `onChange` when some were
    /// answered.
    private func makeJoinRequests(
        _ runChannels: [RunChannel], onChange: @escaping @MainActor () -> Void
    ) -> UIViewController {
        guard let channels else { return UIViewController() }
        let model = ChannelJoinRequestsViewModel(channels: runChannels, service: channels)
        model.onChange = { [catalog] in
            onChange()
            catalog.refresh()
        }
        let screen = ChannelJoinRequestsViewController(viewModel: model, imagePipeline: imagePipeline)
        screen.onOpenProfile = { [router] profileID, name in
            router?.route(to: .profile(profileID, stub: ProfileIdentityStub(handle: nil, displayName: name)))
        }
        return screen
    }

    /// A channel's info screen (#2215); `onChange` tells the thread behind
    /// it that the channel changed.
    private func makeChannelInfo(_ id: ConversationID, onChange: @escaping @MainActor () -> Void) -> UIViewController {
        guard let channels else { return UIViewController() }
        let model = ChannelInfoViewModel(
            conversationID: id, service: channels,
            isMuted: { [catalog] in catalog.isMuted(id) },
            setMuted: { [catalog] muted, until, done in catalog.setMute(id, muted: muted, until: until, completion: done) },
            sharesShowcases: sharesShowcases
        )
        model.onChange = { [catalog] in
            onChange()
            catalog.refresh()
        }
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: imagePipeline, postsPage: postsPage?())
        screen.onOpenProfile = { [router] profileID, name in
            router?.route(to: .profile(profileID, stub: ProfileIdentityStub(handle: nil, displayName: name)))
        }
        // "Share as a Post" (#2216): the Text Post screen over the info
        // screen, the channel's card attached.
        screen.onShareAsPost = { [router] embed in router?.route(to: .composeShowcase(embed)) }
        // Left: the row goes, and the viewer is back in the inbox.
        screen.onLeft = { [weak screen, catalog] in
            catalog.delete([id])
            catalog.refresh()
            screen?.navigationController?.popToRootViewController(animated: true)
        }
        return screen
    }

    // MARK: - Groups (#2214)

    /// The new group's sheet: pick the people, then name it, then Create —
    /// which lands in its thread, opened by "You created the group".
    private func presentGroupCreation(from presenter: UIViewController) {
        guard let groups else { return }
        let picker = makeMemberPicker(purpose: .create, excluded: [], title: "New Group", nextTitle: "Next")
        let sheet = UINavigationController(rootViewController: picker)
        picker.onCancel = { [weak sheet] in _ = sheet?.closePresentation() }
        picker.onNext = { [weak sheet, catalog, groupNotes, router, imagePipeline] people in
            let creation = GroupCreationViewModel(members: people, service: groups)
            creation.onCreated = { [weak sheet] id in
                groupNotes.created[id] = Date()
                // The inbox behind the thread lists it.
                catalog.refresh()
                if let sheet {
                    _ = sheet.closePresentation { router?.route(to: .conversation(id)) }
                } else {
                    router?.route(to: .conversation(id))
                }
            }
            sheet?.pushViewController(
                GroupNameViewController(viewModel: creation, imagePipeline: imagePipeline, profiles: groups), animated: true
            )
        }
        presenter.present(sheet, animated: true)
    }

    /// The member picker (#2214): the viewer's recent correspondents, the
    /// directory once typed into — never the viewer, nor `excluded`.
    private func makeMemberPicker(
        purpose: GroupMemberPickerViewModel.Purpose, excluded: Set<ProfileID>, title: String, nextTitle: String
    ) -> GroupMemberPickerViewController {
        let recents = catalog.directConversations().compactMap(PersonDisplayModel.init(recent:))
        let model = GroupMemberPickerViewModel(purpose: purpose, recents: recents, directory: people, excluded: excluded)
        if let groups {
            Task { @MainActor [weak model] in
                guard let viewer = try? await groups.viewerProfileID() else { return }
                model?.exclude([viewer])
            }
        }
        return GroupMemberPickerViewController(
            viewModel: model, title: title, nextTitle: nextTitle, imagePipeline: imagePipeline,
            avatars: connections as? any PeerAvatarProviding
        )
    }

    /// A group's info screen (#2214); `onChange` tells the thread behind it
    /// that the group changed.
    private func makeGroupInfo(_ id: ConversationID, onChange: @escaping @MainActor () -> Void) -> UIViewController {
        guard let groups else { return UIViewController() }
        let model = GroupInfoViewModel(
            conversationID: id, service: groups,
            isMuted: { [catalog] in catalog.isMuted(id) },
            setMuted: { [catalog] muted, until, done in catalog.setMute(id, muted: muted, until: until, completion: done) }
        )
        model.onChange = onChange
        let screen = GroupInfoViewController(viewModel: model, imagePipeline: imagePipeline, postsPage: postsPage?())
        screen.onOpenProfile = { [router] profileID, name in
            router?.route(to: .profile(profileID, stub: ProfileIdentityStub(handle: nil, displayName: name)))
        }
        screen.onAddMembers = { [self] presenter, excluded, memberCount, completion in
            let picker = makeMemberPicker(
                purpose: .add(memberCount: memberCount), excluded: excluded, title: "Add Members", nextTitle: "Add"
            )
            let sheet = UINavigationController(rootViewController: picker)
            picker.onCancel = { [weak sheet] in _ = sheet?.closePresentation() }
            picker.onNext = { [weak sheet] people in
                _ = sheet?.closePresentation()
                completion(people.map(\.id))
            }
            presenter.present(sheet, animated: true)
        }
        // Left: the row goes, and the viewer is back in the inbox.
        screen.onLeft = { [weak screen, catalog] in
            catalog.delete([id])
            catalog.refresh()
            screen?.navigationController?.popToRootViewController(animated: true)
        }
        return screen
    }

    /// What a group's or a channel's thread needs (#2214, #2215); nil with
    /// neither.
    private func groupThreadContext() -> GroupThreadContext? {
        guard let conversationService = groups ?? channels else { return nil }
        var context = GroupThreadContext(
            service: conversationService,
            makeInfo: { [self] id, onChange in makeGroupInfo(id, onChange: onChange) },
            openProfile: { [router] id, name in
                router?.route(to: .profile(id, stub: name.isEmpty ? nil : ProfileIdentityStub(handle: nil, displayName: name)))
            },
            createdAt: { [groupNotes] id in groupNotes.created[id] },
            knownKind: { [directory] id in directory.summary(for: id)?.kind }
        )
        context.kinds = Set((groups == nil ? [] : [.group]) + (channels == nil ? [] : [.channel]))
        // A channel's row (#2215), and a followed public group's (#2217):
        // drawn as such from the push's first frame.
        context.knownIdentity = { [directory] id in directory.summary(for: id)?.identity }
        // A group's row (#2233): the thread's pill wears its picture at once.
        context.knownGroupRow = { [directory] id in
            guard let row = directory.summary(for: id), row.kind == .group else { return nil }
            return (title: row.title, faces: row.memberFaces)
        }
        // Joined, followed or left — a channel (#2215), a public group
        // (#2217): the inbox reads its rows again.
        context.onMembershipChange = { [catalog] id, left in
            if left { catalog.delete([id]) } else { catalog.restore(id) }
            catalog.refresh()
        }
        if channels != nil {
            context.makeChannelInfo = { [self] id, onChange in makeChannelInfo(id, onChange: onChange) }
        }
        return context
    }

    public func makeConversationViewController(for conversationID: ConversationID) -> UIViewController {
        makeConversationViewController(target: .existing(conversationID))
    }

    private func makeConversationViewController(target: ConversationTarget, prefill: String = "") -> UIViewController {
        let viewModel = ConversationViewModel(
            target: target,
            repository: repository,
            directory: directory,
            router: router
        )
        viewModel.deviceCache = deviceCache
        // Reading a thread is an inbox event, not just a thread event: the row
        // has to leave Unread. Applied immediately — before the server write —
        // so the list underneath is already correct during the back swipe,
        // with a rollback if the write turns out to fail.
        viewModel.onDidMarkRead = { [catalog] id in catalog.markRead(id) }
        viewModel.onMarkReadDidFail = { [catalog] id in catalog.markReadDidFail(id) }
        // Sending changes the row's preview, time and position — all of which
        // the list underneath has to show before the viewer swipes back to it.
        viewModel.onDidSendMessage = { [catalog] id, message in
            catalog.recordSentMessage(message, in: id)
        }
        viewModel.onDidUploadMedia = { [imagePipeline] image, url in imagePipeline?.store(image, for: url) }
        // A draft that just became real: the inbox has never heard of it, so
        // the viewer would otherwise swipe back from a thread they started to
        // a list without it.
        viewModel.onDidResolveConversation = { [catalog] _ in catalog.refresh() }
        return makeThreadScreen(viewModel, mode: .full, prefill: prefill)
    }

    /// A conversation: Feed's text-post screen, driving this view model.
    ///
    /// For a pushed thread it is called AFTER the inbox callbacks are wired on
    /// the view model, so mark-read, sends and draft resolution report back to
    /// the inbox — the driver never touches those four.
    private func makeThreadScreen(
        _ viewModel: ConversationViewModel,
        mode: ConversationThreadMode,
        prefill: String
    ) -> UIViewController {
        let driver = ConversationThreadDriver(
            viewModel: viewModel,
            viewer: repository,
            avatars: connections as? any PeerAvatarProviding,
            // The thread's pin is the inbox's: a peek offers no pinning.
            pins: mode == .full ? catalog : nil,
            mediaPicker: mode == .full ? mediaPicker : nil,
            groupContext: groupThreadContext()
        )
        return threadScreens().makeConversationThreadViewController(
            driver: driver,
            mode: mode,
            prefill: prefill
        )
    }

    /// A thread with `profileID`, opened before anyone knows whether one
    /// exists. Synchronous by design — see `ConversationTarget.draft`.
    public func makeDraftConversationViewController(
        with profileID: ProfileID,
        displayName: String,
        prefill: String
    ) -> UIViewController {
        makeConversationViewController(
            target: .draft(peer: profileID, displayName: displayName), prefill: prefill
        )
    }

    /// Suggestions per page. `-new-message-page-size <n>` shrinks it in DEBUG:
    /// the mock social graph yields only a handful of candidates, so at the
    /// shipping page size the first page is also the last and the pagination
    /// path is unreachable in the simulator.
    private static var suggestionPageSize: Int {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-new-message-page-size"),
           index + 1 < arguments.count,
           let size = Int(arguments[index + 1]), size > 0 {
            return size
        }
        #endif
        return 20
    }

}

/// What this session did to groups that chat.v1 doesn't carry yet (#2214):
/// the groups the viewer created, and when — their thread opens with "You
/// created the group". In memory, for the builder's (the app's) life.
@MainActor
final class GroupSessionNotes {
    var created: [ConversationID: Date] = [:]
}

/// Stands in when the app is composed without a social-graph client: the
/// surface renders its empty state rather than the feature failing to build.
private struct EmptySuggestionsRepository: SuggestionsProviding {
    func suggestions(limit: Int) async throws -> [SuggestedAccount] { [] }
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
    func unfollow(_ profileID: ProfileID) async throws {}
}
