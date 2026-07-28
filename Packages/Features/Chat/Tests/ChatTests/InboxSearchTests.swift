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

private func person(_ id: String, handle: String) -> DirectoryPerson {
    DirectoryPerson(id: ProfileID(id), handle: handle, displayName: handle.capitalized)
}

// MARK: - Stubs

private actor StubChatProvider: ChatProviding {
    private let conversations: [Conversation]
    private let viewer: ProfileID

    init(conversations: [Conversation] = [], viewer: String = "me") {
        self.conversations = conversations
        self.viewer = ProfileID(viewer)
    }

    func viewerProfileID() async throws -> ProfileID { viewer }
    func loadConversations() async throws -> [Conversation] { conversations }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}

    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: viewer, body: body, createdAt: Date(), isMine: true)
    }

    func directConversation(with profileID: ProfileID) async throws -> ConversationID {
        ConversationID("created-\(profileID.rawValue)")
    }
}

/// The viewer follows nobody, so every unanswered inbound conversation
/// partitions into Requests.
private actor StubFollowsNobody: PeerRelationProviding {
    func followedPeers(among peers: [ProfileID]) async throws -> Set<ProfileID> { [] }
}

private actor StubPeopleDirectory: PeopleDirectoryProviding {
    private let people: [DirectoryPerson]
    init(_ people: [DirectoryPerson]) { self.people = people }

    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        people
    }
}

/// Never answers, so a test can observe the window where the local halves have
/// rendered and the directory is still out.
private actor NeverReturningDirectory: PeopleDirectoryProviding {
    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        try await Task.sleep(for: .seconds(600))
        return []
    }
}

private actor FailingDirectory: PeopleDirectoryProviding {
    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] {
        throw ChatError.transport(message: "no")
    }
}

@MainActor
private final class PhaseBox {
    private(set) var phases: [InboxSearchViewModel.Phase] = []
    private(set) var opened: [ConversationTarget] = []
    func append(_ phase: InboxSearchViewModel.Phase) { phases.append(phase) }
    func recordOpen(_ target: ConversationTarget) { opened.append(target) }
}

// MARK: - Tests

@MainActor
struct InboxSearchViewModelTests {
    private func makeCatalog(
        _ repository: StubChatProvider,
        relations: (any PeerRelationProviding)? = nil
    ) async -> InboxCatalog {
        let catalog = InboxCatalog(repository: repository, relations: relations)
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
        people: (any PeopleDirectoryProviding)? = nil
    ) -> (InboxSearchViewModel, PhaseBox) {
        let viewModel = InboxSearchViewModel(
            catalog: catalog,
            viewer: repository,
            people: people ?? StubPeopleDirectory([]),
            debounce: .zero
        )
        let box = PhaseBox()
        viewModel.onPhaseChange = { [box] in box.append($0) }
        viewModel.onOpenConversation = { [box] in box.recordOpen($0) }
        return (viewModel, box)
    }

    /// Waits (bounded) for the phase stream to satisfy `predicate`. The local
    /// halves and the directory land independently, so asserting on a fixed
    /// sleep flakes the moment a runner is loaded.
    private func settle(
        _ box: PhaseBox,
        until predicate: (InboxSearchViewModel.Phase) -> Bool
    ) async -> InboxSearchViewModel.Phase? {
        for _ in 0..<500 {
            if let last = box.phases.last, predicate(last) { return last }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return box.phases.last
    }

    private func sections(_ phase: InboxSearchViewModel.Phase?) -> [InboxSearchViewModel.Section] {
        guard case .content(let sections) = phase else { return [] }
        return sections
    }

    /// The point of the whole feature: one query, every category, regardless of
    /// which tab happened to be showing.
    @Test func aQueryReachesMessagesAndRequestsAtOnce() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofía Reyes", answered: true),
            conversation("c-2", peer: "p-2", title: "Marc Dubois", answered: true),
            conversation("c-3", peer: "p-3", title: "Sofia Klein")
        ])
        let catalog = await makeCatalog(repository, relations: StubFollowsNobody())
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .content = $0 { true } else { false } }
        let found = sections(phase)

        #expect(found.map(\.kind) == [.messages, .requests])
        #expect(found[0].rows == [.conversation(ConversationID("c-1"))])
        #expect(found[1].rows == [.conversation(ConversationID("c-3"))])
        // Diacritic-insensitive, so "sofia" finds "Sofía" — the same rule the
        // compose picker applies, via the same matcher.
        #expect(viewModel.conversationModels[ConversationID("c-1")]?.title == "Sofía Reyes")
    }

    /// A handle is the other half of what people search by.
    @Test func aQueryMatchesTheCorrespondentsHandle() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Marc Dubois", peerHandle: "sofiafan", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .content = $0 { true } else { false } }

        #expect(sections(phase).first?.rows == [.conversation(ConversationID("c-1"))])
    }

    /// Handles are stored bare, but people type the sigil — and the compose
    /// picker's empty state invites them to. Stripping it is what makes the
    /// invitation true.
    @Test func aLeadingAtSigilIsStrippedBeforeMatching() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Marc Dubois", peerHandle: "sofia", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("@sofia")
        let phase = await settle(box) { if case .content = $0 { true } else { false } }

        #expect(sections(phase).first?.rows == [.conversation(ConversationID("c-1"))])
    }

    /// ...but only at the FRONT. An "@" inside the query is ordinary text, and
    /// stripping it there would match rows that lack what was typed.
    @Test func anAtSigilInsideTheQueryIsOrdinaryText() {
        #expect(TextMatch.matchesAny(["ada@lovelace.dev"], query: "ada@love"))
        #expect(!TextMatch.matchesAny(["adalovelace"], query: "ada@love"))
    }

    /// The sigil is stripped before the whitespace question is settled — a
    /// pasted or smart-spaced " @sofia" must not keep its "@".
    @Test func aSigilBehindLeadingWhitespaceIsStillStripped() {
        #expect(TextMatch.matchesAny(["sofia"], query: "  @sofia "))
    }

    /// A lone "@" normalises to nothing, which is the empty query — and an empty
    /// query matches everything, exactly as a cleared field does. Pinned because
    /// the alternative (a term that matches nobody) would make the first
    /// keystroke of "@sofia" blank the list before refilling it.
    @Test func aLoneSigilBehavesAsAnEmptyQuery() {
        #expect(TextMatch.normalize("@").isEmpty)
        #expect(TextMatch.matchesAny(["Marc Dubois"], query: "@"))
    }

    /// Search reads the catalog's PROJECTION, so a request the viewer declined
    /// stays gone. Resurrecting it would undo a decision they just made.
    @Test func aDeclinedRequestDoesNotComeBackThroughSearch() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein")
        ])
        let catalog = await makeCatalog(repository, relations: StubFollowsNobody())
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("sofia")
        #expect(!sections(await settle(box) { if case .content = $0 { true } else { false } }).isEmpty)

        catalog.decline(ConversationID("c-1"))
        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .noResults = $0 { true } else { false } }

        #expect(phase == .noResults(query: "sofia"))
    }

    /// ...but the thread still EXISTS, so the directory row for that same person
    /// opens it rather than starting a blank draft. This is the one place raw
    /// catalog truth is consulted, and the reason it must be.
    @Test func pickingSomeoneWhoseThreadIsHiddenOpensThatThread() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein")
        ])
        let catalog = await makeCatalog(repository, relations: StubFollowsNobody())
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: StubPeopleDirectory([person("p-1", handle: "sofia")])
        )
        catalog.decline(ConversationID("c-1"))

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .content = $0 { true } else { false } }
        #expect(sections(phase).map(\.kind) == [.people])

        viewModel.didSelect(.person(ProfileID("p-1")))
        #expect(box.opened == [.existing(ConversationID("c-1"))])
    }

    /// Someone can be a correspondent AND a directory hit. Showing both would
    /// put one person on the screen twice — and duplicate identifiers across
    /// sections would trap the diffable data source besides.
    @Test func aDirectoryHitAlreadyShownAsAConversationIsNotRepeated() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: StubPeopleDirectory([
                person("p-1", handle: "sofia"),
                person("p-9", handle: "sofiane")
            ])
        )

        viewModel.queryChanged("sofia")
        let phase = await settle(box) {
            if case .content(let sections) = $0 { sections.count == 2 } else { false }
        }
        let found = sections(phase)

        #expect(found.map(\.kind) == [.messages, .people])
        #expect(found[1].rows == [.person(ProfileID("p-9"))])
    }

    /// The viewer cannot message themselves, and searching your own handle
    /// otherwise lists you.
    @Test func theViewerIsNeverAResult() async {
        let repository = StubChatProvider(conversations: [], viewer: "me")
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: StubPeopleDirectory([person("me", handle: "sofia")])
        )

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .noResults = $0 { true } else { false } }

        #expect(phase == .noResults(query: "sofia"))
    }

    /// Nothing local and the directory still out is NOT a verdict. Calling it
    /// "no results" mid-flight flashes an answer the search hasn't reached.
    @Test func anUnansweredDirectoryIsLoadingRatherThanNoResults() async {
        let repository = StubChatProvider(conversations: [])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: NeverReturningDirectory()
        )

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { $0 == .loading }

        #expect(phase == .loading)
    }

    /// A directory failure is not a search failure: the local matches are
    /// already on screen and are most of what the viewer came for.
    @Test func aDirectoryFailureKeepsTheLocalMatches() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: FailingDirectory()
        )

        viewModel.queryChanged("sofia")
        // Settle past the failure landing, then assert the content survived it.
        try? await Task.sleep(for: .milliseconds(100))
        let phase = box.phases.last

        #expect(sections(phase).map(\.kind) == [.messages])
    }

    /// Only a query with nothing local behind it surfaces the error.
    @Test func aDirectoryFailureWithNothingLocalSurfaces() async {
        let repository = StubChatProvider(conversations: [])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: FailingDirectory()
        )

        viewModel.queryChanged("sofia")
        let phase = await settle(box) { if case .failed = $0 { true } else { false } }

        #expect(phase == .failed(message: "Couldn't search for people. Please try again."))
    }

    /// Clearing the field lands back on the prompt, not on "no results" — the
    /// path the system's clear glyph and the cancel button both take.
    @Test func clearingTheQueryReturnsToThePrompt() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("sofia")
        _ = await settle(box) { if case .content = $0 { true } else { false } }
        viewModel.queryChanged("")

        #expect(box.phases.last == .prompt)
        #expect(viewModel.conversationModels.isEmpty)
    }

    /// A conversation row is already a destination; no round trip resolves it.
    @Test func pickingAConversationOpensItDirectly() async {
        let repository = StubChatProvider(conversations: [
            conversation("c-1", peer: "p-1", title: "Sofia Klein", answered: true)
        ])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(repository: repository, catalog: catalog)

        viewModel.queryChanged("sofia")
        _ = await settle(box) { if case .content = $0 { true } else { false } }
        viewModel.didSelect(.conversation(ConversationID("c-1")))

        #expect(box.opened == [.existing(ConversationID("c-1"))])
    }

    /// Someone the directory knows and the inbox does not yields a draft, which
    /// the thread screen finds-or-creates underneath itself.
    @Test func pickingAStrangerYieldsADraft() async {
        let repository = StubChatProvider(conversations: [])
        let catalog = await makeCatalog(repository)
        let (viewModel, box) = makeViewModel(
            repository: repository,
            catalog: catalog,
            people: StubPeopleDirectory([person("p-9", handle: "sofia")])
        )

        viewModel.queryChanged("sofia")
        _ = await settle(box) { if case .content = $0 { true } else { false } }
        viewModel.didSelect(.person(ProfileID("p-9")))

        #expect(box.opened == [.draft(peer: ProfileID("p-9"), displayName: "Sofia")])
    }
}
