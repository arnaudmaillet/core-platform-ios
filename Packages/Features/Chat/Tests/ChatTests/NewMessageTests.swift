import CoreModels
import Foundation
import Testing
@testable import Chat

// MARK: - Fixtures

private func conversation(
    _ id: String,
    peer: String,
    title: String,
    peerHandle: String? = nil,
    activityAt: TimeInterval = 0,
    /// `true` means the viewer has replied, which keeps the conversation OUT of
    /// the request partition regardless of follow state.
    answered: Bool = false
) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: title,
        lastMessage: "hi",
        lastActivityAt: Date(timeIntervalSince1970: activityAt),
        otherMemberIDs: [ProfileID(peer)],
        directPeerHandle: peerHandle,
        lastMessageIsMine: answered,
        lastMessageID: "\(id)-latest",
        isUnread: false
    )
}

private func suggestion(_ id: String, handle: String) -> SuggestedAccount {
    SuggestedAccount(
        id: ProfileID(id),
        handle: handle,
        displayName: handle.capitalized,
        avatarURL: nil,
        reason: .suggestedForYou
    )
}

private func person(_ id: String, handle: String) -> DirectoryPerson {
    DirectoryPerson(id: ProfileID(id), handle: handle, displayName: handle.capitalized)
}

// MARK: - Stubs

private actor StubChatProvider: ChatProviding {
    private let conversations: [Conversation]
    private let messages: [ChatMessage]
    private let viewer: ProfileID
    private(set) var directConversationCalls: [ProfileID] = []
    private(set) var sentBodies: [String] = []
    private var failsDirectConversation = false

    /// Holds `directConversation` open so a test can observe the picker while a
    /// create is still in flight — the window the double-tap guard exists for.
    private var gateIsOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(conversations: [Conversation] = [], messages: [ChatMessage] = [], viewer: String = "me") {
        self.conversations = conversations
        self.messages = messages
        self.viewer = ProfileID(viewer)
    }

    func setFailsDirectConversation(_ fails: Bool) { failsDirectConversation = fails }

    func setGate(open isOpen: Bool) {
        gateIsOpen = isOpen
        guard isOpen else { return }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    private func passGate() async {
        guard !gateIsOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func viewerProfileID() async throws -> ProfileID { viewer }
    func loadConversations() async throws -> [Conversation] { conversations }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { messages }

    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        sentBodies.append(body)
        return ChatMessage(id: "m", senderID: viewer, body: body, createdAt: Date(), isMine: true)
    }

    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}

    func directConversation(with profileID: ProfileID) async throws -> ConversationID {
        directConversationCalls.append(profileID)
        await passGate()
        if failsDirectConversation { throw ChatError.transport(message: "no") }
        return ConversationID("created-\(profileID.rawValue)")
    }
}

/// The viewer follows nobody, so any unanswered inbound conversation
/// partitions into Requests — the state that hid real history from the picker.
private actor StubFollowsNobody: PeerRelationProviding {
    func followedPeers(among peers: [ProfileID]) async throws -> Set<ProfileID> { [] }
}

private actor StubSuggestionsProvider: SuggestionsProviding {
    private let accounts: [SuggestedAccount]
    init(_ accounts: [SuggestedAccount]) { self.accounts = accounts }
    func suggestions(limit: Int) async throws -> [SuggestedAccount] { accounts }
    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

private actor StubPeopleDirectory: PeopleDirectoryProviding {
    private let people: [DirectoryPerson]
    private(set) var queries: [String] = []
    init(_ people: [DirectoryPerson]) { self.people = people }

    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        queries.append(query)
        return people
    }
}

private actor NeverReturningSuggestions: SuggestionsProviding {
    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        try await Task.sleep(for: .seconds(600))
        return []
    }
    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

@MainActor
private final class PhaseBox {
    private(set) var phases: [NewMessageViewModel.Phase] = []
    private(set) var opened: [ConversationTarget] = []
    private(set) var conversationPhases: [ConversationViewModel.Phase] = []
    private(set) var titles: [String] = []
    private(set) var resolved: [ConversationID] = []
    func append(_ phase: NewMessageViewModel.Phase) { phases.append(phase) }
    func recordOpen(_ target: ConversationTarget) { opened.append(target) }
    func appendConversation(_ phase: ConversationViewModel.Phase) { conversationPhases.append(phase) }
    func recordTitle(_ title: String) { titles.append(title) }
    func recordResolved(_ id: ConversationID) { resolved.append(id) }
}

// MARK: - Tests

@MainActor
struct NewMessageViewModelTests {
    private func makeCatalog(repository: StubChatProvider) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository)
        catalog.reload()
        for _ in 0..<500 {
            if catalog.snapshot.phase == .loaded { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return catalog
    }

    private func makeViewModel(
        repository: StubChatProvider,
        catalog: InboxCatalog,
        suggestions: [SuggestedAccount] = [],
        people: [DirectoryPerson] = []
    ) -> (NewMessageViewModel, PhaseBox) {
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: StubSuggestionsProvider(suggestions),
            people: StubPeopleDirectory(people),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }
        viewModel.onOpenConversation = { [box] in box.recordOpen($0) }
        return (viewModel, box)
    }

    /// Waits (bounded) for the phase stream to satisfy `predicate`. The picker
    /// fans out to three sources that land independently, so asserting on a
    /// fixed sleep flakes the moment a runner is loaded.
    private func settle(
        _ box: PhaseBox,
        until predicate: (NewMessageViewModel.Phase) -> Bool
    ) async -> NewMessageViewModel.Phase? {
        for _ in 0..<500 {
            if let last = box.phases.last, predicate(last) { return last }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return box.phases.last
    }

    private func sections(_ phase: NewMessageViewModel.Phase?) -> [NewMessageViewModel.Section] {
        guard case .content(let sections, _) = phase else { return [] }
        return sections
    }

    @Test func browsingSplitsRecentsFromSuggestions() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava Moreau")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("peer-2", handle: "noor")]
        )

        viewModel.load()
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.count == 2 }
            return false
        }

        let sections = sections(phase)
        #expect(sections.map(\.kind) == [.recent, .suggested])
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-1")])
        #expect(sections[0].people[0].displayName == "Ava Moreau")
        #expect(sections[1].people.map(\.id) == [ProfileID("peer-2")])
        #expect(sections[1].people[0].handle == "noor")
    }

    /// A person in both lists appears once, under Recent — which is also the
    /// copy that carries a conversation id, so the row opens instantly.
    @Test func aRecentCorrespondentIsNotAlsoSuggested() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("peer-1", handle: "ava"), suggestion("peer-2", handle: "noor")]
        )

        viewModel.load()
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.count == 2 }
            return false
        }

        let sections = sections(phase)
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-1")])
        #expect(sections[0].people[0].existingConversationID == ConversationID("conv-1"))
        #expect(sections[1].people.map(\.id) == [ProfileID("peer-2")])
    }

    @Test func theViewerIsNeverListed() async {
        let repository = StubChatProvider(viewer: "me")
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("me", handle: "myself"), suggestion("peer-2", handle: "noor")]
        )

        viewModel.load()
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase {
                return sections.flatMap(\.people).allSatisfy { $0.id != ProfileID("me") }
            }
            return false
        }

        #expect(sections(phase).flatMap(\.people).map(\.id) == [ProfileID("peer-2")])
    }

    /// "Recent" means recent. `snapshot.active` is pin-hoisted, and inheriting
    /// that order would open the list with whatever thread the viewer pinned
    /// months ago.
    @Test func recentsAreOrderedByActivityNotPinning() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-old", peer: "peer-old", title: "Old", activityAt: 10),
            conversation("conv-new", peer: "peer-new", title: "New", activityAt: 900)
        ])
        let catalog = await makeCatalog(repository: repository)
        catalog.togglePin(ConversationID("conv-old"))

        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)
        viewModel.load()
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        #expect(sections(phase)[0].people.map(\.id) == [ProfileID("peer-new"), ProfileID("peer-old")])
    }

    /// A query nothing in memory matches leaves the directory hits alone on
    /// screen, and unlabelled — the search field above them is already the label.
    @Test func searchReplacesBrowsingWithResults() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("peer-2", handle: "noor")],
            people: [person("peer-9", handle: "zoe")]
        )

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.count == 2 }
            return false
        }

        viewModel.queryChanged("zoe")
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .results }
            return false
        }

        let sections = sections(phase)
        #expect(sections.map(\.kind) == [.results])
        #expect(sections[0].title == nil)
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-9")])
    }

    /// Clearing the field puts the browsing sections back, rather than leaving
    /// the viewer on an empty results list.
    @Test func clearingTheQueryRestoresBrowsing() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: [person("peer-9", handle: "zoe")]
        )

        viewModel.load()
        viewModel.queryChanged("zoe")
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .results }
            return false
        }

        viewModel.queryChanged("")
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .recent }
            return false
        }

        #expect(sections(phase).map(\.kind) == [.recent])
    }

    // MARK: - Local filtering

    /// The point of filtering in memory: the rows that are already loaded narrow
    /// on the KEYSTROKE, with no debounce and no round trip. Asserted with a
    /// ten-second debounce and not a single `await` after the query — if the
    /// local pass ever moves behind the network, this sees nothing.
    @Test func localMatchesAppearWithoutWaitingForTheDirectory() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava Moreau"),
            conversation("conv-2", peer: "peer-2", title: "Noor Haddad")
        ])
        let catalog = await makeCatalog(repository: repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            people: StubPeopleDirectory([person("peer-9", handle: "zoe")]),
            debounce: .seconds(10)
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        viewModel.queryChanged("ava")

        let sections = sections(box.phases.last)
        #expect(sections.map(\.kind) == [.recent])
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-1")])
    }

    /// "sofia" finds "Sofía Reyes" and "MOREAU" finds "Ava Moreau" — an exact
    /// match would find neither, and a viewer typing a name they remember is not
    /// going to reproduce its accents.
    @Test func localMatchingIsCaseAndDiacriticInsensitive() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Sofía Reyes"),
            conversation("conv-2", peer: "peer-2", title: "Ava Moreau")
        ])
        let catalog = await makeCatalog(repository: repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog, viewer: repository, debounce: .seconds(10)
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        viewModel.queryChanged("sofia")
        #expect(sections(box.phases.last)[0].people.map(\.id) == [ProfileID("peer-1")])

        // And case-folded, on a substring rather than a prefix: the part of a
        // name people remember is often the surname.
        viewModel.queryChanged("MOREAU")
        #expect(sections(box.phases.last)[0].people.map(\.id) == [ProfileID("peer-2")])
    }

    /// Suggestions narrow too, not just recents.
    @Test func localFilteringNarrowsSuggestionsAsWell() async {
        let repository = StubChatProvider()
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("peer-1", handle: "noor"), suggestion("peer-2", handle: "zed")]
        )

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        viewModel.queryChanged("noo")
        let sections = sections(box.phases.last)
        #expect(sections.map(\.kind) == [.suggested])
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-1")])
    }

    /// The directory EXTENDS the local matches rather than replacing them — so
    /// the rows that appeared instantly don't jump out from under the finger
    /// when the request lands. Once it has company, the results section is
    /// labelled.
    @Test func directoryResultsExtendLocalMatches() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava Moreau")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: [person("peer-9", handle: "avalon")]
        )

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        viewModel.queryChanged("ava")
        let phase = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.count == 2 }
            return false
        }

        let sections = sections(phase)
        #expect(sections.map(\.kind) == [.recent, .results])
        #expect(sections[0].people.map(\.id) == [ProfileID("peer-1")])
        #expect(sections[1].people.map(\.id) == [ProfileID("peer-9")])
        #expect(sections[1].title == "More People")
    }

    /// A person who is both a local match and a directory hit appears once,
    /// under the local section — that copy carries the conversation id, and a
    /// duplicate identifier across sections would trap the diffable data source.
    @Test func aDirectoryHitAlreadyShownLocallyIsNotRepeated() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-9", title: "Zoe Aldrin")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: [person("peer-9", handle: "zoe")]
        )

        viewModel.load()
        viewModel.queryChanged("zoe")
        // Give the (zero-debounce) directory round trip room to land and be
        // folded in; the assertion is that it added nothing.
        try? await Task.sleep(for: .milliseconds(120))

        let sections = sections(box.phases.last)
        #expect(sections.map(\.kind) == [.recent])
        let everyID = sections.flatMap { $0.people.map(\.id) }
        #expect(everyID == [ProfileID("peer-9")])

        // And the row that survived is the one that opens instantly.
        viewModel.didSelect(ProfileID("peer-9"))
        #expect(box.opened == [.existing(ConversationID("conv-1"))])
    }

    @Test func matchlessQueryReportsNoResults() async {
        let repository = StubChatProvider()
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog, people: [])

        viewModel.load()
        viewModel.queryChanged("nobody")
        let phase = await settle(box) { phase in
            if case .noResults = phase { return true }
            return false
        }

        #expect(phase == .noResults(query: "nobody"))
    }

    // MARK: - Selection

    /// The point of sourcing Recent from the catalog: a correspondent the inbox
    /// already knows resolves to a real conversation with no lookup at all.
    @Test func pickingARecentCorrespondentYieldsItsConversation() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return !sections.isEmpty }
            return false
        }

        viewModel.didSelect(ProfileID("peer-1"))

        #expect(box.opened == [.existing(ConversationID("conv-1"))])
        #expect(await repository.directConversationCalls.isEmpty)
    }

    /// The regression this whole seam exists for: picking someone the inbox has
    /// never heard of must resolve *synchronously*, with no network call, so
    /// the push starts in the same runloop turn as the tap. Asserted without a
    /// single `await` between the pick and the expectation — if a round trip
    /// ever creeps back in, `opened` is empty here.
    @Test func pickingANewPersonYieldsADraftWithNoRoundTrip() async {
        let repository = StubChatProvider()
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: [person("peer-9", handle: "zoe")]
        )

        viewModel.load()
        viewModel.queryChanged("zoe")
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .results }
            return false
        }

        viewModel.didSelect(ProfileID("peer-9"))

        #expect(box.opened == [.draft(peer: ProfileID("peer-9"), displayName: "Zoe")])
        #expect(await repository.directConversationCalls.isEmpty)
    }

    /// Suggested rows carry no conversation id, so they take the draft path —
    /// and must be exactly as immediate as Recent's.
    @Test func pickingASuggestionYieldsADraft() async {
        let repository = StubChatProvider()
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            suggestions: [suggestion("peer-2", handle: "noor")]
        )

        viewModel.load()
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .suggested }
            return false
        }

        viewModel.didSelect(ProfileID("peer-2"))

        #expect(box.opened == [.draft(peer: ProfileID("peer-2"), displayName: "Noor")])
        #expect(await repository.directConversationCalls.isEmpty)
    }

    /// Search hits are matched against the inbox, so someone found by typing
    /// who is also a correspondent still takes the instant existing path.
    ///
    /// The conversation is titled so it does NOT match the query — otherwise the
    /// local filter would surface this peer under Recent and the directory row
    /// would be deduped away, which is a different (also correct) path. This
    /// test is about the directory row itself carrying the conversation id.
    @Test func aSearchHitCarriesAnExistingConversation() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-9", title: "Old Thread")
        ])
        let catalog = await makeCatalog(repository: repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: [person("peer-9", handle: "zoe")]
        )

        viewModel.load()
        viewModel.queryChanged("zoe")
        _ = await settle(box) { phase in
            if case .content(let sections, _) = phase { return sections.first?.kind == .results }
            return false
        }

        viewModel.didSelect(ProfileID("peer-9"))

        #expect(box.opened == [.existing(ConversationID("conv-1"))])
        #expect(await repository.directConversationCalls.isEmpty)
    }
}

// MARK: - Draft threads

@MainActor
struct DraftConversationTests {
    private func makeViewModel(
        repository: StubChatProvider,
        displayName: String = "Zoe",
        directory: ConversationDirectory? = nil
    ) -> (ConversationViewModel, PhaseBox) {
        let viewModel = ConversationViewModel(
            target: .draft(peer: ProfileID("peer-9"), displayName: displayName),
            repository: repository,
            directory: directory
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.appendConversation($0) }
        viewModel.onTitleChange = { [box] in box.recordTitle($0) }
        viewModel.onDidResolveConversation = { [box] in box.recordResolved($0) }
        return (viewModel, box)
    }

    /// A draft's header is bound before the network has been asked anything —
    /// that is what lets the push start immediately. The transcript stays on
    /// its skeleton until the resolution answers: whether this peer has history
    /// is not yet known, and guessing "empty" is what produced the flash.
    @Test func aDraftBindsItsIdentityBeforeItsConversationExists() async {
        let repository = StubChatProvider()
        await repository.setGate(open: false)
        let (viewModel, box) = makeViewModel(repository: repository)

        viewModel.viewDidLoad()

        #expect(box.titles == ["Zoe"])
        #expect(box.conversationPhases.allSatisfy { $0 == .loading })
    }

    /// The reported bug, as a test: picking someone who turns out to have
    /// history must never flash an empty transcript on the way to showing it.
    @Test func aDraftWithHistoryNeverPublishesAnEmptyTranscript() async {
        let history = ChatMessage(
            id: "m1",
            senderID: ProfileID("peer-9"),
            body: "hello",
            createdAt: Date(timeIntervalSince1970: 10),
            isMine: false
        )
        let repository = StubChatProvider(messages: [history])
        let (viewModel, box) = makeViewModel(repository: repository)

        viewModel.viewDidLoad()
        for _ in 0..<500 {
            if box.conversationPhases.contains(.content([MessageDisplayModel(message: history)])) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(box.conversationPhases.last == .content([MessageDisplayModel(message: history)]))
        // The whole point: no empty-transcript frame anywhere before it.
        #expect(!box.conversationPhases.contains(.content([])))
    }

    /// A genuinely new contact still lands on the clean empty transcript — just
    /// once that is actually known to be true.
    @Test func aDraftWithNoHistoryLandsOnTheEmptyState() async {
        let repository = StubChatProvider()
        let (viewModel, box) = makeViewModel(repository: repository)

        viewModel.viewDidLoad()
        for _ in 0..<500 {
            if box.conversationPhases.last == .content([]) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(box.conversationPhases.last == .content([]))
    }

    /// Once the conversation resolves the thread adopts it, announces it (so
    /// the inbox can pick the new row up) and loads whatever history the peer
    /// turned out to already have.
    @Test func aDraftAdoptsItsConversationAndLoadsHistory() async {
        let repository = StubChatProvider(messages: [
            ChatMessage(
                id: "m1",
                senderID: ProfileID("peer-9"),
                body: "hello",
                createdAt: Date(timeIntervalSince1970: 10),
                isMine: false
            )
        ])
        let directory = ConversationDirectory()
        let (viewModel, box) = makeViewModel(repository: repository, directory: directory)

        viewModel.viewDidLoad()
        for _ in 0..<500 {
            if !box.resolved.isEmpty, case .content(let models)? = box.conversationPhases.last, !models.isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(box.resolved == [ConversationID("created-peer-9")])
        #expect(box.conversationPhases.last == .content([
            MessageDisplayModel(message: ChatMessage(
                id: "m1",
                senderID: ProfileID("peer-9"),
                body: "hello",
                createdAt: Date(timeIntervalSince1970: 10),
                isMine: false
            ))
        ]))
        // Warmed so a later push of the same thread has its header at frame zero.
        #expect(directory.title(for: ConversationID("created-peer-9")) == "Zoe")
    }

    /// Typing faster than the network: the send waits on the resolution the
    /// screen already started rather than starting a second one. Two
    /// find-or-creates would leave a duplicate conversation `chat.v1` can't merge.
    @Test func sendingBeforeResolutionCreatesExactlyOneConversation() async {
        let repository = StubChatProvider()
        await repository.setGate(open: false)
        let (viewModel, _) = makeViewModel(repository: repository)

        viewModel.viewDidLoad()
        viewModel.send("hi")
        // Both the screen's resolution and the send are now queued behind the gate.
        await repository.setGate(open: true)

        for _ in 0..<500 {
            if !(await repository.sentBodies.isEmpty) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(await repository.directConversationCalls == [ProfileID("peer-9")])
        #expect(await repository.sentBodies == ["hi"])
    }

    /// An empty display name (a deep link, a map pin) still opens instantly —
    /// the header just fills in from the conversation summary once there is one.
    @Test func aDraftWithNoKnownNameResolvesItsTitleLater() async {
        let repository = StubChatProvider(conversations: [
            conversation("created-peer-9", peer: "peer-9", title: "Zoe")
        ])
        let (viewModel, box) = makeViewModel(repository: repository, displayName: "")

        viewModel.viewDidLoad()
        #expect(box.titles.isEmpty)

        for _ in 0..<500 {
            if !box.titles.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(box.titles == ["Zoe"])
    }
}

// MARK: - Known conversations and loading state

@MainActor
struct NewMessagePartitionTests {
    private func loadedCatalog(_ repository: StubChatProvider) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository, relations: StubFollowsNobody())
        catalog.reload()
        for _ in 0..<500 {
            if catalog.snapshot.phase == .loaded { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return catalog
    }

    /// The blank-draft-then-jump bug. An unfollowed peer whose message the
    /// viewer hasn't answered sits in Requests, so it is absent from
    /// `snapshot.active` — but the conversation and its history are real, and
    /// picking that person must open the thread they already have rather than
    /// a draft that fills itself in a moment later.
    @Test func aPeerWhoseThreadSitsInRequestsIsStillAKnownConversation() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-req", peer: "peer-1", title: "Ava")
        ])
        let catalog = await loadedCatalog(repository)

        // Precondition: this really is the hidden case, not just any row.
        #expect(catalog.snapshot.active.isEmpty)
        #expect(catalog.snapshot.requests.map(\.id) == [ConversationID("conv-req")])
        // And so it is not offered as a "Recent" correspondent either.
        #expect(catalog.directConversations().isEmpty)

        #expect(catalog.directConversationID(with: ProfileID("peer-1")) == ConversationID("conv-req"))
    }

    /// Picking that person yields `.existing`, so the thread opens on its real
    /// transcript instead of the empty-draft state.
    @Test func pickingSuchAPeerOpensTheExistingThread() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-req", peer: "peer-1", title: "Ava")
        ])
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: StubSuggestionsProvider([suggestion("peer-1", handle: "ava")]),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }
        viewModel.onOpenConversation = { [box] in box.recordOpen($0) }

        viewModel.load()
        for _ in 0..<500 {
            if case .content(let sections, _) = box.phases.last ?? .loading, !sections.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        // The row is a *suggestion* — the picker has no Recent entry for them —
        // yet it must still resolve to the conversation that exists.
        viewModel.didSelect(ProfileID("peer-1"))
        #expect(box.opened == [.existing(ConversationID("conv-req"))])
    }

    /// Recents land instantly and suggestions do not, so the picker spends most
    /// of its first moment holding rows plus a promise of more. That promise is
    /// what fills the rest of the screen with skeleton rows instead of white.
    @Test func partiallyLoadedContentReportsThatMoreIsComing() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava", answered: true)
        ])
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: NeverReturningSuggestions(),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        for _ in 0..<500 {
            if case .content = box.phases.last ?? .loading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard case .content(let sections, let loading) = box.phases.last else {
            Issue.record("expected content, got \(String(describing: box.phases.last))")
            return
        }
        #expect(sections.map(\.kind) == [.recent])
        #expect(loading == .fillingScreen)
    }

    /// Once every source has answered, the promise is withdrawn and the
    /// skeleton comes off — otherwise it would shimmer forever under a short list.
    @Test func fullyLoadedContentStopsPromisingMore() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava", answered: true)
        ])
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: StubSuggestionsProvider([suggestion("peer-2", handle: "noor")]),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        for _ in 0..<500 {
            if case .content(_, let loading) = box.phases.last ?? .loading, loading == .none { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        guard case .content(let sections, let loading) = box.phases.last else {
            Issue.record("expected content, got \(String(describing: box.phases.last))")
            return
        }
        #expect(sections.map(\.kind) == [.recent, .suggested])
        #expect(loading == .none)
    }
}

// MARK: - Caps and pagination

/// Hands out an effectively endless ranked list, so paging can be driven past
/// several boundaries. Mirrors the real contract: `suggestions(limit:)` returns
/// a stable prefix of one ranking, and the paged default drops into it.
private actor EndlessSuggestions: SuggestionsProviding {
    private let total: Int
    private(set) var requestedLimits: [Int] = []

    init(total: Int = 1_000) { self.total = total }

    func suggestions(limit: Int) async throws -> [SuggestedAccount] {
        requestedLimits.append(limit)
        return (0..<min(limit, total)).map { suggestion("sugg-\($0)", handle: "s\($0)") }
    }
    func follow(_ profileID: ProfileID) async throws {}
    func unfollow(_ profileID: ProfileID) async throws {}
}

@MainActor
struct NewMessagePagingTests {
    private func loadedCatalog(_ repository: StubChatProvider) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository, relations: StubFollowsNobody())
        catalog.reload()
        for _ in 0..<500 {
            if catalog.snapshot.phase == .loaded { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return catalog
    }

    private func answeredConversations(_ count: Int) -> [Conversation] {
        (0..<count).map { index in
            conversation(
                "conv-\(index)",
                peer: "peer-\(index)",
                title: "Person \(index)",
                activityAt: TimeInterval(1_000 - index),
                answered: true
            )
        }
    }

    private func settle(
        _ box: PhaseBox,
        until predicate: ([NewMessageViewModel.Section], NewMessageViewModel.Loading) -> Bool
    ) async -> [NewMessageViewModel.Section] {
        for _ in 0..<500 {
            if case .content(let sections, let loading)? = box.phases.last, predicate(sections, loading) {
                return sections
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .content(let sections, _)? = box.phases.last { return sections }
        return []
    }

    // MARK: Recent cap

    /// Recents are a shortcut, not a corpus: they come from a catalog already
    /// in memory, so the cap is a hard stop with nothing behind it.
    @Test func recentsAreCappedAtFifteen() async {
        let repository = StubChatProvider(conversations: answeredConversations(40))
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog, viewer: repository, debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        let sections = await settle(box) { sections, _ in !sections.isEmpty }

        #expect(sections[0].kind == .recent)
        #expect(sections[0].people.count == 15)
        // The cap keeps the TOP of the list — the most recent correspondents.
        #expect(sections[0].people.first?.displayName == "Person 0")
        #expect(sections[0].people.last?.displayName == "Person 14")
    }

    @Test func fewerRecentsThanTheCapAreAllShown() async {
        let repository = StubChatProvider(conversations: answeredConversations(4))
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog, viewer: repository, debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        let sections = await settle(box) { sections, _ in !sections.isEmpty }

        #expect(sections[0].people.count == 4)
    }

    // MARK: Suggested pagination

    @Test func theFirstPageIsOnePageLong() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: EndlessSuggestions(),
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        let sections = await settle(box) { sections, loading in
            !sections.isEmpty && loading == .none
        }

        #expect(sections[0].kind == .suggested)
        #expect(sections[0].people.count == 20)
    }

    @Test func scrollingNearTheEndAppendsTheNextPage() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: EndlessSuggestions(),
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { sections, loading in !sections.isEmpty && loading == .none }

        // Nothing is published SYNCHRONOUSLY. This is called from
        // `willDisplay`, i.e. from inside the collection view's own snapshot
        // apply, and emitting there nests a second apply inside the first —
        // which the diffable data source traps on as a deadlock.
        let phasesBefore = box.phases.count
        viewModel.loadMoreSuggestionsIfNeeded()
        #expect(box.phases.count == phasesBefore)

        // The spinner arrives on the next turn, under the rows already there.
        //
        // Asserted against the whole phase HISTORY rather than `phases.last`:
        // a stubbed page can land and clear the flag before the test next gets
        // to look, and "the last phase isn't .appendingSuggestions" says
        // nothing about whether the spinner was ever published. Checking
        // `last` made this test fail about half the time.
        var sawSpinner = false
        for _ in 0..<500 {
            sawSpinner = box.phases.contains {
                if case .content(_, .appendingSuggestions) = $0 { return true }
                return false
            }
            if sawSpinner { break }
            await Task.yield()
        }
        #expect(sawSpinner)

        let sections = await settle(box) { sections, loading in
            loading == .none && (sections.first { $0.kind == .suggested }?.people.count ?? 0) > 20
        }
        #expect(sections.first { $0.kind == .suggested }?.people.count == 40)
        // Appended, not replaced: the rows already on screen keep their order.
        #expect(sections.first { $0.kind == .suggested }?.people.first?.id == ProfileID("sugg-0"))
    }

    /// `willDisplay` fires on every bounce and every row scrolled back into
    /// view, so the trigger is asked far more often than there are pages.
    @Test func repeatedTriggersLoadOnlyOnePage() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let suggestions = EndlessSuggestions()
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: suggestions,
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { sections, loading in !sections.isEmpty && loading == .none }

        for _ in 0..<10 { viewModel.loadMoreSuggestionsIfNeeded() }
        let sections = await settle(box) { sections, loading in
            loading == .none && (sections.first { $0.kind == .suggested }?.people.count ?? 0) > 20
        }

        #expect(sections.first { $0.kind == .suggested }?.people.count == 40)
        // One first page + exactly one paged re-rank.
        #expect(await suggestions.requestedLimits == [20, 40])
    }

    /// A short page means the graph is spent; asking again would loop forever
    /// against a list that cannot grow.
    @Test func aShortPageEndsPagination() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let suggestions = EndlessSuggestions(total: 25)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: suggestions,
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { sections, loading in !sections.isEmpty && loading == .none }

        viewModel.loadMoreSuggestionsIfNeeded()
        let sections = await settle(box) { sections, loading in
            loading == .none && (sections.first { $0.kind == .suggested }?.people.count ?? 0) > 20
        }
        #expect(sections.first { $0.kind == .suggested }?.people.count == 25)

        // Exhausted: further triggers must not spend another request.
        let spent = await suggestions.requestedLimits.count
        for _ in 0..<5 { viewModel.loadMoreSuggestionsIfNeeded() }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await suggestions.requestedLimits.count == spent)
    }

    /// A first page that doesn't fill means there was never a second one.
    @Test func aShortFirstPageNeverPages() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let suggestions = EndlessSuggestions(total: 3)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: suggestions,
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { sections, loading in !sections.isEmpty && loading == .none }

        for _ in 0..<5 { viewModel.loadMoreSuggestionsIfNeeded() }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await suggestions.requestedLimits == [20])
    }

    /// Dedupe survives paging: a recent correspondent revealed by a later page
    /// must not appear twice, which a diffable snapshot would trap on.
    @Test func pagedSuggestionsStayDedupedAgainstRecents() async {
        // sugg-1 is also a recent correspondent.
        let repository = StubChatProvider(conversations: [
            conversation("conv-x", peer: "sugg-1", title: "Overlap", answered: true)
        ])
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: EndlessSuggestions(),
            debounce: .zero,
            suggestionPageSize: 20
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        _ = await settle(box) { sections, loading in sections.count == 2 && loading == .none }
        viewModel.loadMoreSuggestionsIfNeeded()
        let sections = await settle(box) { sections, loading in
            loading == .none && (sections.first { $0.kind == .suggested }?.people.count ?? 0) > 19
        }

        let everyID = sections.flatMap { $0.people.map(\.id) }
        #expect(Set(everyID).count == everyID.count)
        #expect(!(sections.first { $0.kind == .suggested }?.people.map(\.id).contains(ProfileID("sugg-1")) ?? true))
    }

    /// Search still bypasses every cap.
    @Test func searchResultsAreNotCapped() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            people: StubPeopleDirectory((0..<24).map { person("hit-\($0)", handle: "h\($0)") }),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        viewModel.queryChanged("h")
        let sections = await settle(box) { sections, _ in sections.first?.kind == .results }

        #expect(sections[0].people.count == 24)
    }
}

// MARK: - Row uniformity

@MainActor
struct PersonRowUniformityTests {
    /// Every source produces the same two-line row: name over a bare handle.
    /// The sections sit directly above one another, so a recent correspondent
    /// rendering name-only read as a poorer kind of row than its neighbours.
    @Test func allThreeSourcesProduceTheSameShape() {
        let recent = PersonDisplayModel(recent: Conversation(
            id: ConversationID("c1"),
            title: "Ava Moreau",
            lastMessage: "hi",
            lastActivityAt: Date(timeIntervalSince1970: 0),
            otherMemberIDs: [ProfileID("peer-1")],
            directPeerHandle: "ava.moreau"
        ))
        let suggested = PersonDisplayModel(account: SuggestedAccount(
            id: ProfileID("peer-2"),
            handle: "noor.h",
            displayName: "Noor Haddad",
            avatarURL: nil,
            reason: .followsYou
        ))
        let found = PersonDisplayModel(person: DirectoryPerson(
            id: ProfileID("peer-3"), handle: "zed.aldrin", displayName: "Zed Aldrin"
        ))

        for row in [recent, suggested, found].compactMap(\.self) {
            #expect(!row.displayName.isEmpty)
            #expect(!row.handle.isEmpty)
            #expect(!row.monogram.isEmpty)
            // Bare: the sigil is redundant on a screen where every row is a person.
            #expect(!row.handle.hasPrefix("@"))
        }
        #expect(recent?.handle == "ava.moreau")
        #expect(suggested.handle == "noor.h")
        #expect(found.handle == "zed.aldrin")
    }

    /// A conversation whose hydration never resolved a handle still renders —
    /// the row just collapses to one line rather than showing a stray sigil.
    @Test func aRecentWithNoResolvedHandleDegradesCleanly() {
        let recent = PersonDisplayModel(recent: Conversation(
            id: ConversationID("c1"),
            title: "Ava Moreau",
            lastMessage: "hi",
            lastActivityAt: Date(timeIntervalSince1970: 0),
            otherMemberIDs: [ProfileID("peer-1")]
        ))
        #expect(recent?.handle == "")
        #expect(recent?.displayName == "Ava Moreau")
    }
}

// MARK: - Empty Recent

@MainActor
struct NewMessageEmptySectionTests {
    private func loadedCatalog(_ repository: StubChatProvider) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository, relations: StubFollowsNobody())
        catalog.reload()
        for _ in 0..<500 {
            if catalog.snapshot.phase == .loaded { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return catalog
    }

    private func settled(_ box: PhaseBox) async -> [NewMessageViewModel.Section] {
        for _ in 0..<500 {
            if case .content(let sections, .none)? = box.phases.last, !sections.isEmpty { return sections }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if case .content(let sections, _)? = box.phases.last { return sections }
        return []
    }

    /// A viewer with no conversations gets no Recent section AT ALL — not an
    /// empty one. The section carries a header capsule, so an empty section
    /// would leave "Recent" floating over the first suggestion.
    @Test func noRecentsMeansNoRecentSection() async {
        let repository = StubChatProvider()
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog,
            viewer: repository,
            suggestions: StubSuggestionsProvider([
                suggestion("peer-1", handle: "noor"),
                suggestion("peer-2", handle: "zed")
            ]),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        let sections = await settled(box)

        #expect(sections.map(\.kind) == [.suggested])
        #expect(!sections.contains { $0.kind == .recent })
        // Suggested is therefore section 0, which is what puts it flush to the
        // top (the layout zeroes header padding for the first section only).
        #expect(sections.first?.title == "Suggested")
    }

    /// The mirror case: conversations but no suggestions leaves Recent alone.
    @Test func noSuggestionsMeansNoSuggestedSection() async {
        let repository = StubChatProvider(conversations: [
            conversation("conv-1", peer: "peer-1", title: "Ava", peerHandle: "ava", answered: true)
        ])
        let catalog = await loadedCatalog(repository)
        let viewModel = NewMessageViewModel(
            catalog: catalog, viewer: repository, suggestions: StubSuggestionsProvider([]), debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }

        viewModel.load()
        let sections = await settled(box)

        #expect(sections.map(\.kind) == [.recent])
    }
}
