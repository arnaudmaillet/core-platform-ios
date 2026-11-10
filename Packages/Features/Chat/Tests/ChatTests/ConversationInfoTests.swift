import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import DesignSystem
import FeedInterface
import Foundation
import HeroPage
import Testing
import UIKit
@testable import Chat

/// A group's and a channel's info screens as the profile's and the place's
/// page (#2237), on the mock's groups and channels: the header per kind and
/// viewer, the lists behind the counters — paged, each counter its list's
/// total — the rows' menus, the bell and the "⋯", the Posts page's status,
/// and no switch left.
///
/// The mock's viewer: owner of grp-hike (5 members, 2 admins), member of
/// grp-printfair (40), follower of grp-riverside, outside grp-coastal
/// (public, 40 members, 2 300 followers) and grp-darkroom (full); owner of
/// ch-daily (12 400) and ch-studio-requests (64, three requests),
/// subscriber of ch-tides, outside ch-harbour (public) and ch-printroom (on
/// request), a request pending on ch-film.
@MainActor
@Suite(.serialized)
struct ConversationInfoTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func make() -> ChatRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockChatService(dataset: dataset, seedsGroups: true, seedsChannels: true).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ChatRepository(
            chatClient: Chat_V1_ChatServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            authSession: Session(),
            inboxPageSize: 100,
            proposals: ProposedChatClient(client: client),
            showsGroups: true,
            showsChannels: true
        )
    }

    /// What the bell asked of the inbox's mute.
    @MainActor
    private final class BellRecorder {
        var muted = false
        var asked: [(Bool, Date?)] = []
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func group(_ id: String, _ repository: ChatRepository? = nil) async -> GroupInfoViewModel {
        let info = GroupInfoViewModel(conversationID: ConversationID(id), service: repository ?? make())
        info.load()
        await settle { info.state.phase == .loaded }
        return info
    }

    private func channel(_ id: String, shares: Bool = true, _ repository: ChatRepository? = nil) async -> ChannelInfoViewModel {
        let info = ChannelInfoViewModel(conversationID: ConversationID(id), service: repository ?? make(), sharesShowcases: shares)
        info.load()
        await settle { info.state.phase == .loaded }
        return info
    }

    /// Every row of `list`, read page by page as the list scrolls.
    private func allRows(
        _ read: (String?) async throws -> PersonListPage
    ) async throws -> (rows: [PersonListRow], pages: Int, total: Int) {
        var rows: [PersonListRow] = []
        var token: String?
        var pages = 0
        var total = 0
        repeat {
            let page = try await read(token)
            rows += page.rows
            token = page.nextPageToken
            total = page.total
            pages += 1
        } while token != nil && pages < 100
        return (rows, pages, total)
    }

    /// Hosts `screen` in a stack in a window for the length of `body`.
    private func hosting<Screen: UIViewController>(_ screen: Screen, _ body: (Screen, UINavigationController) async throws -> Void) async rethrows {
        let stack = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = stack
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try await body(screen, stack)
    }

    // MARK: - The header, per kind and viewer

    @Test func aGroupsHeaderForItsOwner() async {
        let header = await group("grp-hike").header
        #expect(header.title == "Weekend hike")
        #expect(header.subtitle == "Private group")
        #expect(header.titleSymbol == nil)
        #expect(header.counters[.members] == 5)
        #expect(header.counters[.admins] == 2)
        #expect(header.counters[.requests] == nil, "no request waiting: no counter")
        #expect(header.counters[.followers] == nil, "a private group counts no followers")
        #expect(header.capsules == [.edit, .addMembers])
        #expect(header.bubbles.isEmpty, "a private group has no link to share")
        #expect(header.linkURL == nil)
        #expect(header.openable == [.members, .admins, .requests])
    }

    @Test func aGroupsHeaderForAMemberAFollowerAndOutsiders() async {
        let repository = make()
        let member = await group("grp-printfair", repository).header
        #expect(member.counters[.members] == 40)
        #expect(member.capsules.isEmpty, "a member edits nothing")
        #expect(member.openable == [.members, .admins])

        let outsider = await group("grp-coastal", repository).header
        #expect(outsider.subtitle == "Public group")
        #expect(outsider.counters[.members] == 40)
        #expect(outsider.counters[.followers] == 2_300)
        #expect(outsider.capsules == [.join, .follow])
        #expect(outsider.bubbles == [.share])
        #expect(outsider.linkText == "core-platform.click/c/grp-coastal")
        #expect(!outsider.openable.contains(.followers), "the followers are the owner's and admins' to read")

        let full = await group("grp-darkroom", repository).header
        #expect(full.capsules == [.follow], "a full group: Follow only")

        let follower = await group("grp-riverside", repository).header
        #expect(follower.capsules == [.join])
    }

    @Test func aChannelsHeaderForItsOwner() async {
        let header = await channel("ch-studio-requests").header
        #expect(header.title == "Studio drops")
        #expect(header.titleSymbol == "megaphone.fill")
        #expect(header.subtitle.hasPrefix("Channel on request"))
        #expect(header.subtitleOwner == nil, "the owner's own name opens nothing")
        #expect(header.counters[.subscribers] == 64)
        #expect(header.counters[.admins] == 1)
        #expect(header.counters[.requests] == 3, "requests waiting: the counter")
        #expect(header.capsules == [.edit, .invite])
        #expect(header.bubbles == [.share])
        #expect(header.openable == [.subscribers, .admins, .requests])
        #expect(header.linkText == "core-platform.click/c/ch-studio-requests")

        let daily = await channel("ch-daily").header
        #expect(daily.counters[.requests] == nil, "none waiting: no counter")
    }

    @Test func aChannelsHeaderForASubscriberAndOutsiders() async {
        let repository = make()
        let subscriber = await channel("ch-tides", repository).header
        #expect(subscriber.subtitle.hasPrefix("Public channel · by @"))
        #expect(subscriber.subtitleOwner == ProfileID("prof-19"), "\"by @owner\" opens the owner")
        #expect(subscriber.counters[.subscribers] == 1_150)
        #expect(subscriber.counters[.requests] == nil)
        #expect(subscriber.capsules.isEmpty)
        #expect(subscriber.openable == [.admins], "a subscriber reads the admins, not the audience")

        let outside = await channel("ch-harbour", repository).header
        #expect(outside.capsules == [.join])
        #expect(outside.counters[.admins] == nil, "an outsider sees the channel, not its people")
        #expect(outside.openable.isEmpty)
        #expect(outside.subtitle.contains("by @"), "the owner names it to anyone")

        let onRequest = await channel("ch-printroom", repository).header
        #expect(onRequest.capsules == [.requestToJoin])
        #expect(onRequest.subtitle.hasPrefix("Channel on request"))

        let asked = await channel("ch-film", repository).header
        #expect(asked.capsules == [.requested])
    }

    // MARK: - The lists behind the counters

    @Test func eachCounterPushesTheListsOnItsTab() async throws {
        // One fresh info screen per counter: resetting one stack between taps
        // left UIKit dropping the next push (a test artifact — the app comes
        // back by the back button).
        let expected: [ConversationInfoList] = ConversationInfoList.counters(channel: true)
        for (index, list) in expected.enumerated() {
            let model = ChannelInfoViewModel(conversationID: ConversationID("ch-studio-requests"), service: make())
            let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil)
            try await hosting(screen) { screen, stack in
                await settle { model.state.phase == .loaded }
                #expect(screen.captions == expected)
                let counter = screen.heroHeader.counters[index]
                #expect(counter.isTappable, "\(list) does not open")
                counter.sendActions(for: .touchUpInside)
                await settle { stack.topViewController is PersonListsViewController }
                let lists = try #require(stack.topViewController as? PersonListsViewController, "\(list) pushed nothing")
                #expect(lists.activeTab == list.rawValue, "opened \(lists.activeTab) for \(list.rawValue)")
                #expect(lists.debugTabIDs == ["subscribers", "admins", "requests"])
            }
        }
    }

    @Test func aCounterTheViewerMayNotReadOpensNothing() async throws {
        let model = ChannelInfoViewModel(conversationID: ConversationID("ch-tides"), service: make())
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil)
        await hosting(screen) { screen, stack in
            await settle { model.state.phase == .loaded }
            #expect(!screen.heroHeader.counters[0].isTappable, "a subscriber's Subscribers counter")
            screen.openLists(.subscribers)
            #expect(stack.topViewController === screen)
            screen.openLists(.admins)
            #expect((stack.topViewController as? PersonListsViewController)?.debugTabIDs == ["admins"])
        }
    }

    @Test func studioDropsSubscribersArrivePageByPage() async throws {
        let info = await channel("ch-studio-requests")
        let first = try await info.page(of: .subscribers, after: nil)
        #expect(first.rows.count == ChannelInfoViewModel.pageSize, "one page, never the audience")
        #expect(first.nextPageToken != nil)
        #expect(first.total == 64)
        let second = try await info.page(of: .subscribers, after: first.nextPageToken)
        #expect(Set(second.rows.map(\.id)).isDisjoint(with: first.rows.map(\.id)), "the second page goes on")
        let all = try await allRows { try await info.page(of: .subscribers, after: $0) }
        #expect(all.rows.count == 64)
        #expect(all.pages == 3)
        #expect(Set(all.rows.map(\.id)).count == 64)
        #expect(all.rows.allSatisfy { !$0.name.isEmpty && $0.name != "Subscriber" }, "every subscriber is someone")
    }

    @Test func everyCounterIsItsListsTotalOnTheMock() async throws {
        let repository = make()
        for id in ["grp-hike", "grp-printfair", "grp-coastal", "grp-riverside", "grp-darkroom"] {
            let info = await group(id, repository)
            let header = info.header
            for tab in GroupInfoViewModel.listTabs(for: info.state) {
                let list = try #require(ConversationInfoList(rawValue: tab.id))
                let page = try await info.page(of: list, after: nil)
                #expect(page.total == (header.counters[list] ?? 0), "\(id) \(list): \(page.total) listed, \(header.counters[list] ?? 0) counted")
            }
        }
        for id in ["ch-daily", "ch-studio-requests", "ch-tides"] {
            let info = await channel(id, repository)
            let header = info.header
            for tab in ChannelInfoViewModel.listTabs(for: info.state) {
                let list = try #require(ConversationInfoList(rawValue: tab.id))
                let page = try await info.page(of: list, after: nil)
                #expect(page.total == (header.counters[list] ?? 0), "\(id) \(list): \(page.total) listed, \(header.counters[list] ?? 0) counted")
            }
        }
        // Walked to the end, a list holds what its counter says.
        let coastal = await group("grp-coastal", repository)
        let members = try await allRows { try await coastal.page(of: .members, after: $0) }
        #expect(members.rows.count == 40)
    }

    @Test func eachTabSaysWhatAnEmptyListIs() async throws {
        for list in ConversationInfoList.allCases {
            #expect(!list.empty(channel: true).title.isEmpty)
            #expect(!list.empty(channel: false).title.isEmpty)
        }
        #expect(ConversationInfoList.subscribers.empty(channel: true).title == "No subscribers yet")
        #expect(ConversationInfoList.requests.empty(channel: true).title == "No requests")
        let daily = await channel("ch-daily")
        let requests = try await daily.page(of: .requests, after: nil)
        #expect(requests.rows.isEmpty && requests.total == 0)
        let tab = try #require(ChannelInfoViewModel.listTabs(for: daily.state).first { $0.id == "requests" })
        #expect(tab.empty.title == "No requests")
        #expect(tab.title == "0 Requests")
    }

    @Test func aRowsMenuFollowsTheViewersRole() async throws {
        let repository = make()
        let owned = await channel("ch-studio-requests", repository)
        let subscribers = try await owned.page(of: .subscribers, after: nil).rows
        #expect(subscribers.allSatisfy { $0.actions.map(\.id) == ["makeAdmin", "remove", "ban"] })
        let admins = try await owned.page(of: .admins, after: nil).rows
        #expect(admins.first?.actions.isEmpty == true, "the owner's own row")
        #expect(admins.first?.opens == false)
        let requests = try await owned.page(of: .requests, after: nil).rows
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.answersRequest }, "a request's row: Approve and Decline")

        let subscribed = await channel("ch-tides", repository)
        #expect(try await subscribed.page(of: .admins, after: nil).rows.allSatisfy { $0.actions.isEmpty })

        let hike = await group("grp-hike", repository)
        for row in try await hike.page(of: .members, after: nil).rows {
            let role = hike.member(ProfileID(row.id))?.role
            switch role {
            case .admin?: #expect(row.actions.first?.id == "removeAdmin")
            case .member?: #expect(row.actions.first?.id == "makeAdmin")
            default: #expect(row.actions.isEmpty)
            }
        }
        // A follower is removed or banned, never made admin.
        let follower = ConversationMember(profileID: ProfileID("f"), role: .subscriber, joinedAt: Date())
        #expect(GroupInfoViewModel.actions(by: .owner, viewer: ProfileID("me"), on: follower) == [.remove, .ban])
        #expect(GroupInfoViewModel.actions(by: .member, viewer: ProfileID("me"), on: follower).isEmpty)
    }

    @Test func makeAdminFromTheMembersList() async throws {
        let repository = make()
        let hike = await group("grp-hike", repository)
        let row = try #require(try await hike.page(of: .members, after: nil).rows.first {
            hike.member(ProfileID($0.id))?.role == .member
        })
        var reloaded = false
        hike.onPeopleChange = { reloaded = true }
        hike.perform(.makeAdmin, on: ProfileID(row.id))
        await settle { hike.state.adminCount == 3 }
        #expect(hike.state.adminCount == 3)
        #expect(reloaded, "the lists weren't read again")
    }

    // MARK: - The bar

    @Test func theMoreMenuPerRoleAndNeverLeaveForTheOwner() async {
        let repository = make()
        #expect(GroupInfoViewModel.menu(for: await group("grp-hike", repository).state) == [.visibility, .transferOwnership])
        #expect(GroupInfoViewModel.menu(for: await group("grp-printfair", repository).state) == [.leave])
        #expect(GroupInfoViewModel.menu(for: await group("grp-riverside", repository).state) == [.unfollow])
        #expect(GroupInfoViewModel.menu(for: await group("grp-coastal", repository).state).isEmpty)
        #expect(ChannelInfoViewModel.menu(for: await channel("ch-daily", repository).state)
            == [.shareAsPost, .visibility, .transferOwnership])
        #expect(ChannelInfoViewModel.menu(for: await channel("ch-daily", shares: false, repository).state)
            == [.visibility, .transferOwnership])
        #expect(ChannelInfoViewModel.menu(for: await channel("ch-tides", repository).state) == [.leave])
        #expect(ChannelInfoViewModel.menu(for: await channel("ch-harbour", repository).state).isEmpty)
    }

    @Test func theMoreMenuEndsOnLeaveInRed() async throws {
        let model = GroupInfoViewModel(conversationID: ConversationID("grp-printfair"), service: make())
        let screen = GroupInfoViewController(viewModel: model, imagePipeline: nil)
        try await hosting(screen) { screen, _ in
            await settle { model.state.phase == .loaded }
            #expect(screen.debugMoreTitles.last == "Leave Group")
            let ways = try #require(screen.moreMenuElements().last as? UIMenu)
            #expect((ways.children.last as? UIAction)?.attributes.contains(.destructive) == true)
        }
        let owned = GroupInfoViewModel(conversationID: ConversationID("grp-hike"), service: make())
        let ownScreen = GroupInfoViewController(viewModel: owned, imagePipeline: nil)
        await hosting(ownScreen) { screen, _ in
            await settle { owned.state.phase == .loaded }
            #expect(!screen.debugMoreTitles.contains("Leave Group"), "the owner hands over first")
            #expect(screen.debugMoreTitles.contains("Transfer Ownership"))
        }
    }

    @Test func theBellIsTheThreadsMenuAndNoSwitchIsLeft() async throws {
        let bell = BellRecorder()
        let model = ChannelInfoViewModel(
            conversationID: ConversationID("ch-tides"), service: make(),
            isMuted: { bell.muted },
            setMuted: { mute, until, done in
                bell.asked.append((mute, until))
                bell.muted = mute
                done(true)
            }
        )
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil)
        try await hosting(screen) { screen, _ in
            await settle { model.state.phase == .loaded }
            #expect(screen.debugTrailingItemIDs == [ChannelInfoViewController.moreID, ChannelInfoViewController.bellID])
            // The thread's menu, from the one builder (`MuteMenu`).
            let menu = try #require(screen.debugBellMenu)
            let mute = try #require(menu.children.first as? UIMenu)
            #expect(mute.title == "Mute Notifications")
            #expect(mute.children.compactMap { ($0 as? UIAction)?.title } == MuteMenu.durations.map(\.title))
            // A duration mutes until its end.
            screen.setMute(true, until: MuteMenu.durations[0].end())
            #expect(bell.asked.last?.0 == true && bell.asked.last?.1 != nil)
            await settle { model.state.isMuted }
            let unmute = try #require(screen.debugBellMenu?.children.first as? UIAction)
            #expect(unmute.title == "Unmute")
            // No switch anywhere on the screen any more.
            @MainActor func switches(in view: UIView) -> Int {
                let own: Int = view is UISwitch ? 1 : 0
                return view.subviews.reduce(own) { $0 + switches(in: $1) }
            }
            #expect(switches(in: screen.view) == 0)
        }
        let outside = ChannelInfoViewModel(conversationID: ConversationID("ch-harbour"), service: make())
        let outsideScreen = ChannelInfoViewController(viewModel: outside, imagePipeline: nil)
        await hosting(outsideScreen) { screen, _ in
            await settle { outside.state.phase == .loaded }
            #expect(screen.debugTrailingItemIDs.isEmpty, "an outsider has nothing to mute, and nothing in a menu")
        }
    }

    // MARK: - The Posts page

    @Test func thePostsPageSaysWhatItWillHoldPerRole() async throws {
        let manager = ConversationInfoPosts.status(channel: true, manages: true, canShareAsPost: true)
        #expect(manager.title == "Share as a Post")
        #expect(manager.actionTitle == "Share as a Post")
        let reader = ConversationInfoPosts.status(channel: true, manages: false, canShareAsPost: false)
        #expect(reader.title == "No posts yet")
        #expect(reader.actionTitle == nil)
        #expect(ConversationInfoPosts.status(channel: false, manages: false, canShareAsPost: false).title == "No posts yet")
        #expect(ConversationInfoPosts.status(channel: false, manages: true, canShareAsPost: false).title == "No posts yet",
                "a group has no showcase to make yet")

        let page = ConversationStatusPage()
        let model = ChannelInfoViewModel(conversationID: ConversationID("ch-daily"), service: make(), sharesShowcases: true)
        let screen = ChannelInfoViewController(viewModel: model, imagePipeline: nil, postsPage: page)
        await hosting(screen) { screen, _ in
            await settle { model.state.phase == .loaded }
            #expect(page.shownStatus?.title == "Share as a Post")
            var shared: PostEmbed?
            screen.onShareAsPost = { shared = $0 }
            page.onRefresh?()
            #expect(shared?.channel?.conversationID == ConversationID("ch-daily"), "the status's action shares the channel")
        }
    }
}
