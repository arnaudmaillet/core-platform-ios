import CoreModels
import CoreNavigation
import CoreNetworking
import DesignSystem
import Foundation
import TestSupport
import Testing
import UIKit
@testable import Chat

// MARK: - Fixtures

private func direct(_ id: String, peer: String, title: String, at time: TimeInterval) -> Conversation {
    Conversation(
        id: ConversationID(id),
        title: title,
        lastMessage: "hi",
        lastActivityAt: Date(timeIntervalSince1970: time),
        otherMemberIDs: [ProfileID(peer)],
        directPeerHandle: title.lowercased(),
        lastMessageIsMine: true,
        lastMessageID: "\(id)-latest",
        isUnread: false
    )
}

private func person(_ id: String, _ name: String) -> DirectoryPerson {
    DirectoryPerson(id: ProfileID(id), handle: name.lowercased(), displayName: name)
}

private func account(_ id: String, _ name: String) -> SuggestedAccount {
    SuggestedAccount(id: ProfileID(id), handle: name.lowercased(), displayName: name, avatarURL: nil, reason: .suggestedForYou)
}

// MARK: - Stubs

private actor SheetChat: ChatProviding {
    let conversations: [Conversation]
    init(_ conversations: [Conversation]) { self.conversations = conversations }
    func viewerProfileID() async throws -> ProfileID { ProfileID("me") }
    func loadConversations() async throws -> [Conversation] { conversations }
    func loadInbox(_ folder: InboxFolder, after pageToken: String?) async throws -> InboxPage {
        InboxPage(conversations: folder == .requests ? [] : conversations, nextPageToken: nil)
    }
    func loadMessages(in conversationID: ConversationID) async throws -> [ChatMessage] { [] }
    func markRead(_ conversationID: ConversationID, upTo messageID: String) async throws {}
    func send(_ body: String, to conversationID: ConversationID, replyingTo replyToID: String?) async throws -> ChatMessage {
        ChatMessage(id: "m", senderID: ProfileID("me"), body: body, createdAt: Date(), isMine: true)
    }
    func directConversation(with profileID: ProfileID) async throws -> ConversationID {
        ConversationID("created-\(profileID.rawValue)")
    }
}

private actor SheetFriends: FriendsProviding {
    let people: [DirectoryPerson]
    let hangs: Bool
    init(_ people: [DirectoryPerson], hangs: Bool = false) {
        self.people = people
        self.hangs = hangs
    }
    func friends(limit: Int) async throws -> [DirectoryPerson] {
        if hangs { try await Task.sleep(for: .seconds(600)) }
        return people
    }
}

private actor SheetSuggestions: SuggestionsProviding {
    let pages: [[SuggestedAccount]]
    private(set) var asked: [String?] = []
    init(_ pages: [[SuggestedAccount]]) { self.pages = pages }
    func suggestions(limit: Int) async throws -> [SuggestedAccount] { pages.first ?? [] }
    func suggestions(limit: Int, after pageToken: String?) async throws -> SuggestionsPage {
        asked.append(pageToken)
        let index = pageToken.flatMap(Int.init) ?? 0
        let next = index + 1 < pages.count ? String(index + 1) : nil
        return SuggestionsPage(accounts: pages.indices.contains(index) ? pages[index] : [], nextPageToken: next)
    }
    func follow(_ profileID: ProfileID) async throws -> FollowOutcome { .following }
    func unfollow(_ profileID: ProfileID) async throws {}
}

private actor SheetDirectory: PeopleDirectoryProviding {
    let people: [DirectoryPerson]
    init(_ people: [DirectoryPerson]) { self.people = people }
    func searchPeople(matching query: String, limit: Int32) async throws -> [DirectoryPerson] { people }
}

// MARK: - The sheet's model

/// **The "New message" sheet (#2411, the owner 2026-11-13).** The actions,
/// then Friends, Recent and Suggested: a person once, in the first section
/// that has them; an empty section left out; a query narrows what is in
/// memory and the directory extends it; a pick is a thread or a draft.
@MainActor
struct NewMessageViewModelTests {
    private func loadedCatalog(_ conversations: [Conversation]) async -> (InboxCatalog, SheetChat) {
        let chat = SheetChat(conversations)
        let catalog = InboxCatalog(repository: chat)
        catalog.reload()
        _ = await settle { catalog.snapshot.phase == .loaded }
        return (catalog, chat)
    }

    private func sheet(
        _ conversations: [Conversation] = [],
        friends: (any FriendsProviding)? = nil,
        suggestions: [[SuggestedAccount]] = [],
        directory: [DirectoryPerson] = [],
        groups: Bool = false,
        channels: Bool = false
    ) async -> NewMessageViewModel {
        let (catalog, chat) = await loadedCatalog(conversations)
        let model = NewMessageViewModel(
            catalog: catalog, viewer: chat, friends: friends, suggestions: SheetSuggestions(suggestions),
            directory: SheetDirectory(directory), showsNewGroup: groups, showsNewChannel: channels,
            debounce: .zero, suggestionPageSize: 2
        )
        model.start()
        return model
    }

    private func rows(_ model: NewMessageViewModel, _ kind: NewMessageViewModel.SectionKind) -> [String] {
        (model.state.sections.first { $0.kind == kind }?.rows ?? []).compactMap { row in
            guard case .person(let id) = row else { return nil }
            return id.rawValue
        }
    }

    /// The order — actions, Friends, Recent, Suggested — with a person once,
    /// in the first section that has them, and never the viewer.
    @Test func theSectionsComeInOrderAndAPersonAppearsOnce() async {
        let model = await sheet(
            [direct("c-ana", peer: "ana", title: "Ana", at: 20), direct("c-bo", peer: "bo", title: "Bo", at: 10)],
            friends: SheetFriends([person("ana", "Ana"), person("cy", "Cy")]),
            suggestions: [[account("cy", "Cy"), account("me", "Me"), account("di", "Di")]],
            groups: true, channels: true
        )
        // The viewer is resolved beside the lists: waited on too.
        _ = await settle { !model.state.isLoading && rows(model, .suggested) == ["di"] }

        #expect(model.state.sections.map(\.kind) == [.actions, .friends, .recent, .suggested])
        #expect(model.state.sections.first?.rows == [.newGroup, .newChannel])
        #expect(rows(model, .friends) == ["ana", "cy"])
        #expect(rows(model, .recent) == ["bo"], "Ana is a friend: listed there, not again")
        #expect(rows(model, .suggested) == ["di"], "Cy listed once, the viewer never")
    }

    /// Recent: the people last written to, most recent first, at most 15.
    @Test func recentIsTheLastFifteenCorrespondentsNewestFirst() async {
        let threads = (0..<20).map { direct("c-\($0)", peer: "p\($0)", title: "P\($0)", at: TimeInterval($0)) }
        let model = await sheet(threads)
        _ = await settle { !model.state.isLoading }

        let recent = rows(model, .recent)
        #expect(recent.count == NewMessageViewModel.recentLimit)
        #expect(recent.first == "p19" && recent.last == "p5")
    }

    /// An empty section is left out; with nothing at all, "Search for
    /// someone" (the field focused).
    @Test func emptySectionsAreLeftOut() async {
        let model = await sheet(friends: SheetFriends([]), suggestions: [[account("di", "Di")]])
        _ = await settle { !model.state.isLoading }
        #expect(model.state.sections.map(\.kind) == [.suggested])

        let empty = await sheet(friends: SheetFriends([]))
        _ = await settle { !empty.state.isLoading }
        #expect(empty.state.sections.isEmpty)
        #expect(empty.state.status == .searchForSomeone)
    }

    /// The sections arrive in order: while the friends are out, the skeleton
    /// stands after the actions and nothing lands below it to be pushed down
    /// when they come; a query still narrows what is in memory.
    @Test func theSkeletonStandsWhereTheLoadedSectionsStop() async {
        let model = await sheet(
            [direct("c-bo", peer: "bo", title: "Bo", at: 10)],
            friends: SheetFriends([person("ana", "Ana")], hangs: true),
            groups: true
        )
        // Recent is in memory from the start (the loaded inbox); the
        // friends never answer here.
        #expect(model.state.isLoading)
        #expect(model.state.sections.map(\.kind) == [.actions], "Recent shown above friends still on their way")
        #expect(model.state.status == .none)

        model.queryChanged("bo")
        #expect(rows(model, .recent) == ["bo"], "a query narrows what is in memory")
    }

    /// A query narrows the people in memory on the keystroke (name or
    /// handle, diacritics aside); the actions leave; the directory then
    /// extends the list with "More people", deduped against what is shown.
    @Test func aQueryNarrowsLocallyAndTheDirectoryExtends() async {
        let model = await sheet(
            [direct("c-bo", peer: "bo", title: "Bo", at: 10)],
            friends: SheetFriends([person("so", "Sofía"), person("cy", "Cy")]),
            directory: [person("so", "Sofía"), person("sv", "Sofia Vega")],
            groups: true
        )
        _ = await settle { !model.state.isLoading }

        model.queryChanged("sofia")
        #expect(!model.state.sections.contains { $0.kind == .actions }, "the actions show while there is a query")
        #expect(rows(model, .friends) == ["so"], "narrowed on the keystroke")
        _ = await settle { model.state.sections.contains { $0.kind == .morePeople } }
        #expect(model.state.sections.map(\.kind) == [.friends, .morePeople])
        #expect(rows(model, .morePeople) == ["sv"], "Sofía is a friend: not listed again")
    }

    /// Nobody anywhere: "No people found".
    @Test func aQueryThatFindsNobodySaysSo() async {
        let model = await sheet(friends: SheetFriends([person("cy", "Cy")]))
        _ = await settle { !model.state.isLoading }
        model.queryChanged("zz")
        _ = await settle { model.state.status == .noPeople }
        #expect(model.state.status == .noPeople)
        #expect(model.state.sections.isEmpty)
    }

    /// A pick: the thread the inbox has with them — from its raw load —
    /// else a draft on the person's identity.
    @Test func aPickResolvesAnExistingThreadOrADraft() async {
        let model = await sheet(
            [direct("c-bo", peer: "bo", title: "Bo", at: 10)],
            friends: SheetFriends([person("bo", "Bo"), person("cy", "Cy")])
        )
        _ = await settle { !model.state.isLoading }
        var picked: [ConversationTarget] = []
        model.onPick = { picked.append($0) }

        model.didSelect(.person(ProfileID("bo")))
        model.didSelect(.person(ProfileID("cy")))

        #expect(picked == [
            .existing(ConversationID("c-bo")),
            .draft(peer: ProfileID("cy"), displayName: "Cy", handle: "cy")
        ])
    }

    /// Suggested pages as the list scrolls, appended, never reordered.
    @Test func suggestedPagesOnScroll() async {
        let model = await sheet(
            friends: SheetFriends([]),
            suggestions: [[account("a", "A"), account("b", "B")], [account("c", "C")]]
        )
        _ = await settle { !model.state.isLoading }
        #expect(rows(model, .suggested) == ["a", "b"])
        #expect(model.hasMoreSuggestions)

        model.loadMoreSuggestions()
        _ = await settle { rows(model, .suggested).count == 3 }
        #expect(rows(model, .suggested) == ["a", "b", "c"])
        #expect(!model.hasMoreSuggestions)
    }
}

// MARK: - The compose item

/// **The compose item (#2411):** `[bell][selector] ——— [✎]`, a stock item,
/// prominent, in the brand primary, opening the "New message" sheet. The
/// selector's container narrows for it and scrolls; no title shrinks for
/// it, and the selected tab stays whole.
@MainActor
struct InboxComposeItemTests {
    private final class Surface: UIViewController, InboxSurface {
        let category: MessagesCategory
        var chrome = InboxSurfaceChrome()
        var onChromeChange: ((InboxSurfaceChrome) -> Void)?
        func surfaceDidBecomeActive() {}
        init(_ category: MessagesCategory) {
            self.category = category
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        func publish(_ badge: Int) {
            chrome.badgeCount = badge
            onChromeChange?(chrome)
        }
    }

    private func inbox(composes: Bool, onCompose: @escaping () -> Void = {}) -> (MessagesInboxViewController, [Surface]) {
        let surfaces = [Surface(.all), Surface(.requests), Surface(.suggestions)]
        let screen = MessagesInboxViewController(surfaces: surfaces)
        if composes { screen.onCompose = onCompose }
        return (screen, surfaces)
    }

    /// The trailing item is the compose item: a stock image item, prominent,
    /// in the primary, "New message" to VoiceOver — and a tap opens the sheet.
    @Test func theTrailingItemIsTheProminentComposeItem() throws {
        var composed = 0
        let (screen, _) = inbox(composes: true) { composed += 1 }
        screen.loadViewIfNeeded()

        let trailing = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(trailing.count == 1)
        let item = try #require(trailing.first)
        #expect(item.identifier == MessagesInboxViewController.composeItemID)
        #expect(item.customView == nil, "a stock item, not a custom view (R1)")
        #expect(item.style == .prominent)
        #expect(item.tintColor == Palette.prominentGlassTint)
        #expect(item.image != nil)
        #expect(item.accessibilityLabel == "New message")

        screen.debugTapCompose()
        #expect(composed == 1)
        #expect(screen.navigationItem.rightBarButtonItems?.first === item, "one instance for the screen's life")
    }

    /// Without a sheet to open, no compose item.
    @Test func withoutTheSheetThereIsNoComposeItem() {
        let (screen, _) = inbox(composes: false)
        screen.loadViewIfNeeded()
        #expect(screen.navigationItem.rightBarButtonItems?.isEmpty ?? true)
    }

    /// An iPhone SE's bar, the bell leading, counts 43 and 99+: the compose
    /// item takes its platter first, the selector's container takes what is
    /// left — narrower than its content, so it scrolls — at the titles' own
    /// size. Selecting the last tab keeps it whole in view.
    @Test func theSelectorNarrowsScrollsAndKeepsTheSelectedTabInView() throws {
        func hosted(composes: Bool) -> (MessagesInboxViewController, UIWindow) {
            let (screen, surfaces) = inbox(composes: composes)
            screen.setLeadingAccessoryItem(UIBarButtonItem(customView: UIView()))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
            window.rootViewController = UINavigationController(rootViewController: screen)
            window.isHidden = false
            window.layoutIfNeeded()
            surfaces[0].publish(43)
            surfaces[1].publish(150)
            window.layoutIfNeeded()
            return (screen, window)
        }
        let (composing, composingWindow) = hosted(composes: true)
        defer { composingWindow.isHidden = true }
        let (bare, bareWindow) = hosted(composes: false)
        defer { bareWindow.isHidden = true }

        let strip = composing.debugSelector
        let ceiling = try #require(strip.widthCeiling)
        let bareCeiling = try #require(bare.debugSelector.widthCeiling)
        #expect(ceiling <= bareCeiling - BarSelectorBudget.platter + 0.5,
                "the compose item's platter was not taken first: \(ceiling) vs \(bareCeiling)")
        #expect(strip.titleSize == bare.debugSelector.titleSize, "a title shrank for the compose item")
        #expect(strip.debugContentWidth > strip.debugViewportWidth + 0.5,
                "the container is not narrower than its content: \(strip.debugContentWidth) in \(strip.debugViewportWidth)")
        #expect(strip.debugStripAcceptsScrolling)

        strip.select(2)
        composingWindow.layoutIfNeeded()
        strip.layoutIfNeeded()
        let pill = strip.debugPillInViewport
        #expect(pill.minX >= -0.5 && pill.maxX <= strip.debugViewportWidth + 0.5,
                "the selected tab is cut: \(pill) in \(strip.debugViewportWidth)")
    }
}
