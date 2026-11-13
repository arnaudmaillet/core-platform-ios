import CoreModels
import DesignSystem
import FeedInterface
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Profile
@testable import ProfileSettings

/// A profile's Channels tab (#2232, behind `-channels`): shown only with a
/// channel the viewer may see, after Posts; someone else's private channels
/// never listed, the viewer's own locked; "Create a Channel" leading the own
/// tab; each row's action per the viewer's standing, and what a tap does;
/// no tab at all with the channels off.
///
/// Which channels a profile OWNS — not the ones it admins, and one handed
/// over moving to its new owner — is the server's answer, pinned on the
/// mock in Chat's `ProfileChannelsTests`.
/// Serialized: a channel's standing is remembered and announced app-wide
/// (`ChannelEmbedLocalState`, the card's notification), so two tests
/// running side by side on one channel turned each other's rows (seen
/// running the suite).
@MainActor
@Suite(.serialized)
struct ProfileChannelsTests {
    // MARK: - Fakes

    /// Answers each owner's channels from a table, and counts the reads.
    @MainActor
    private final class Provider: ProfileChannelsProviding {
        var table: [ProfileID: [ProfileChannel]]
        var fails = false
        private(set) var asked: [ProfileID] = []

        init(_ table: [ProfileID: [ProfileChannel]] = [:]) {
            self.table = table
        }

        func channels(ownedBy owner: ProfileID) async throws -> [ProfileChannel] {
            asked.append(owner)
            if fails { throw URLError(.notConnectedToInternet) }
            return table[owner] ?? []
        }
    }

    /// The card's actions: each write answers the standing it is told to.
    @MainActor
    private final class Actions: ChannelEmbedActing {
        var joinAnswer: ChannelEmbed.ViewerState = .subscriber
        var requestAnswer: ChannelEmbed.ViewerState = .requested
        var refuses = false
        private(set) var calls: [String] = []
        private(set) var opened: [ConversationID] = []

        func join(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("join \(id.rawValue)")
            if refuses { throw URLError(.badServerResponse) }
            return joinAnswer
        }

        func requestToJoin(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("request \(id.rawValue)")
            if refuses { throw URLError(.badServerResponse) }
            return requestAnswer
        }

        func cancelJoinRequest(_ id: ConversationID) async throws -> ChannelEmbed.ViewerState {
            calls.append("cancel \(id.rawValue)")
            if refuses { throw URLError(.badServerResponse) }
            return .none
        }

        func open(_ id: ConversationID) {
            opened.append(id)
        }
    }

    @MainActor
    private final class Announcements {
        var changes: [(ConversationID, ChannelEmbed.ViewerState, ChannelEmbed.ViewerState)] = []
    }

    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    /// Someone every read finds: `prof-demo`.
    private actor Profiles: ProfileProviding {
        private func someone() -> UserProfile {
            UserProfile(
                id: ProfileID("prof-demo"), handle: "you", displayName: "Demo Viewer",
                bio: "", avatarURL: nil, websiteURL: nil, isVerified: false,
                followerCount: .exact(0), followingCount: .exact(0), reactionCount: .exact(0)
            )
        }
        func currentUserProfile() async throws -> UserProfile { someone() }
        func profile(id: ProfileID) async throws -> UserProfile { someone() }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship { .me }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(
            displayName: String, bio: String, website: String, links: [ProfileLink]
        ) async throws -> UserProfile { someone() }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { someone() }
    }

    // MARK: - Fixtures

    private let owner = ProfileID("prof-11")
    private let viewer = ProfileID("prof-demo")

    private func channel(
        _ id: String, visibility: ChannelEmbed.Visibility = .public, state: ChannelEmbed.ViewerState = .none,
        isPrivate: Bool = false, count: Int = 10, availability: ChannelEmbed.Availability = .available
    ) -> ProfileChannel {
        ProfileChannel(
            channel: ChannelEmbed(
                conversationID: ConversationID(id), name: id.capitalized, description: "About \(id).",
                subscriberCount: count, visibility: visibility, viewerState: state, availability: availability
            ),
            isPrivate: isPrivate
        )
    }

    private func model(
        _ provider: Provider, own: Bool = false, creation: Bool = true,
        actions: Actions? = nil, announcements: Announcements? = nil
    ) -> ProfileChannelsViewModel {
        ProfileChannelsViewModel(
            provider: provider, isOwnProfile: own, offersCreation: creation,
            actions: { actions },
            announce: { id, from, to in announcements?.changes.append((id, from, to)) }
        )
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loaded(_ model: ProfileChannelsViewModel, owner: ProfileID) async -> ProfileChannelsViewModel {
        model.load(owner: owner)
        await settle { model.phase == .loaded || model.phase == .failed }
        return model
    }

    private func snapshot() -> ProfileViewModel.GallerySnapshot {
        let post = GalleryPost(id: PostID("p"), kind: .photo, isRepost: false, thumbnailURL: nil, caption: "p", publishedAtMS: 0)
        var snapshot = ProfileViewModel.GallerySnapshot(activity: .content([post]), media: .content([post]))
        snapshot.tagged = .content([post])
        return snapshot
    }

    // MARK: - The tab

    /// Channels follows Posts (the owner, 2026-11-10): Posts · Channels ·
    /// Reposts · Tagged, then Saved · History · Liked on the own profile.
    @Test func theTabFollowsPosts() {
        #expect(ProfileTab.channels.title == "Channels")
        #expect(ProfileTab.publicTabs == [.format(.activity), .channels, .reposts, .tagged])
        #expect(ProfileTab.ownTabs.map(\.title) == ["Posts", "Channels", "Reposts", "Tagged", "Saved", "History", "Liked"])
        #expect(!ProfileTab.channels.pages, "a list of channels doesn't page")
        #expect(ProfileTab.channels.format == nil)
    }

    /// Shown only with a channel the viewer may see (#742's rule).
    @Test func theTabShowsOnlyWithAVisibleChannel() {
        let all = ProfileTab.ownTabs
        let without = ProfileViewController.shownTabs(all, in: snapshot(), isOwnProfile: false)
        #expect(!without.contains(.channels))
        let with = ProfileViewController.shownTabs(all, in: snapshot(), isOwnProfile: false, hasChannels: true)
        #expect(with == [.format(.activity), .channels, .tagged])
    }

    /// A profile with channels and no post keeps Posts first — its "No
    /// Posts Yet" or its lock — and Channels second.
    @Test func channelsNeverStandsAlone() {
        #expect(ProfileViewController.withPostsBesideChannels([.channels]) == [.format(.activity), .channels])
        #expect(ProfileViewController.withPostsBesideChannels([.channels, .tagged]) == [.channels, .tagged])
        #expect(ProfileViewController.withPostsBesideChannels([]) == [])
    }

    /// No channel, no tab: the model says so once its read lands empty.
    @Test func noChannelNoTab() async {
        let model = await loaded(model(Provider([owner: []])), owner: owner)
        #expect(model.phase == .loaded)
        #expect(!model.hasChannels)
        #expect(model.rows.isEmpty)
    }

    /// A failed read is no tab either, and the next one asks again.
    @Test func aFailedReadShowsNoTab() async {
        let provider = Provider([owner: [channel("a")]])
        provider.fails = true
        let model = await loaded(model(provider), owner: owner)
        #expect(model.phase == .failed)
        #expect(!model.hasChannels)
        provider.fails = false
        model.reload()
        await settle { model.hasChannels }
        #expect(provider.asked == [owner, owner])
    }

    // MARK: - What is listed

    /// Someone else's private channel never shows — whatever a read says,
    /// a private conversation can't be probed. All private: no tab.
    @Test func privateChannelsAreHiddenFromOthers() async {
        let provider = Provider([owner: [channel("open"), channel("secret", isPrivate: true)]])
        let model = await loaded(model(provider), owner: owner)
        #expect(model.channels.map(\.id.rawValue) == ["open"])

        let onlyPrivate = await loaded(self.model(Provider([owner: [channel("secret", isPrivate: true)]])), owner: owner)
        #expect(!onlyPrivate.hasChannels, "a private channel alone made a tab")
    }

    /// The viewer's own lists every one, the private ones with a lock.
    @Test func ownPrivateChannelsShowWithALock() async throws {
        let provider = Provider([viewer: [channel("daily", state: .member), channel("sketchbook", state: .member, isPrivate: true)]])
        let model = await loaded(model(provider, own: true), owner: viewer)
        #expect(model.channels.map(\.id.rawValue) == ["daily", "sketchbook"])
        #expect(model.channel(ConversationID("sketchbook"))?.isPrivate == true)

        let page = ProfileChannelsPage(model: model, pipeline: nil)
        page.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        page.layoutIfNeeded()
        let locked = try #require(page.debugCell(for: ConversationID("sketchbook")))
        #expect(locked.debugShowsLock)
        let open = try #require(page.debugCell(for: ConversationID("daily")))
        #expect(!open.debugShowsLock)
    }

    /// A channel that can't be shown (deleted, blocked) is no row.
    @Test func unavailableChannelsAreNoRow() {
        let rows = [channel("a"), channel("gone", availability: .deleted), channel("b", availability: .blocked)]
        #expect(ProfileChannelsViewModel.visible(rows, isOwnProfile: true).map(\.id.rawValue) == ["a"])
    }

    /// The server's order is kept: the most subscribed first is its call.
    @Test func theServersOrderIsKept() async {
        let provider = Provider([owner: [channel("big", count: 900), channel("small", count: 3)]])
        let model = await loaded(model(provider), owner: owner)
        #expect(model.channels.map(\.id.rawValue) == ["big", "small"])
    }

    /// Another owner (an account switch) forgets the last one's at once.
    @Test func anotherOwnerForgetsTheLastOnesChannels() async {
        let provider = Provider([owner: [channel("a")], viewer: []])
        let model = await loaded(model(provider), owner: owner)
        #expect(model.hasChannels)
        model.load(owner: viewer)
        #expect(!model.hasChannels, "the last profile's channels stayed up")
        await settle { model.phase == .loaded }
        #expect(!model.hasChannels)
    }

    // MARK: - "Create a Channel"

    /// The own tab leads with "Create a Channel"; nobody else's does, and
    /// with no channel there is no tab to lead.
    @Test func theOwnTabLeadsWithCreate() async {
        let provider = Provider([viewer: [channel("daily", state: .member)], owner: [channel("a")]])
        let own = await loaded(model(provider, own: true), owner: viewer)
        #expect(own.rows.map(\.id) == [.create, .channel(ConversationID("daily"))])

        let someone = await loaded(model(provider, own: false), owner: owner)
        #expect(someone.rows.map(\.id) == [.channel(ConversationID("a"))])

        let empty = await loaded(model(Provider([viewer: []]), own: true), owner: viewer)
        #expect(empty.rows.isEmpty)

        let noSheet = await loaded(model(provider, own: true, creation: false), owner: viewer)
        #expect(!noSheet.rows.contains(.create), "offered with nothing to create it")
    }

    /// Its tap asks the screen for the sheet.
    @Test func createAsksForTheSheet() async {
        let model = await loaded(model(Provider([viewer: [channel("daily", state: .member)]]), own: true), owner: viewer)
        var asked = 0
        model.onCreate = { asked += 1 }
        let page = ProfileChannelsPage(model: model, pipeline: nil)
        page.onCreate = { model.requestCreation() }
        page.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        page.layoutIfNeeded()
        page.debugSelect(.create)
        #expect(asked == 1)
    }

    // MARK: - The row's action

    /// Join (public) / Request (on request) / Requested / Open (in) — the
    /// card's table — and none for a banned viewer.
    @Test func theRowsActionFollowsTheViewersState() async throws {
        let rows = [
            channel("join", visibility: .public),
            channel("request", visibility: .onRequest),
            channel("requested", visibility: .onRequest, state: .requested),
            channel("subscribed", state: .subscriber),
            channel("member", state: .member),
            channel("banned", state: .banned),
        ]
        let model = await loaded(model(Provider([owner: rows])), owner: owner)
        func action(_ id: String) -> ChannelEmbed.Action? { model.action(for: ConversationID(id)) }
        #expect(action("join") == .join)
        #expect(action("request") == .requestToJoin)
        #expect(action("requested") == .requested)
        #expect(action("subscribed") == .open)
        #expect(action("member") == .open)
        #expect(action("banned") == nil)

        let page = ProfileChannelsPage(model: model, pipeline: nil)
        page.frame = CGRect(x: 0, y: 0, width: 390, height: 1_000)
        page.layoutIfNeeded()
        func cell(_ id: String) throws -> ProfileChannelCell { try #require(page.debugCell(for: ConversationID(id))) }
        #expect(try cell("join").debugActionTitle == "Join")
        #expect(try !cell("join").debugActionIsQuiet, "Join lost the tinted ground")
        #expect(try cell("request").debugActionTitle == "Request")
        #expect(try cell("requested").debugActionTitle == "Requested")
        #expect(try cell("requested").debugActionIsQuiet)
        #expect(try cell("requested").debugActionOpensMenu, "Requested's tap doesn't offer the cancel")
        #expect(try cell("subscribed").debugActionTitle == "Open")
        #expect(try cell("subscribed").debugActionIsQuiet)
        #expect(try cell("banned").debugActionTitle == nil)
        #expect(try cell("join").debugNameText == "Join")
        #expect(try cell("join").debugCountText == "10 subscribers")
        #expect(try cell("join").debugDescriptionText == "About join.")
    }

    /// Join turns the button to Open at once, counts the viewer in, and
    /// tells every card of the channel.
    @Test func joinTurnsToOpen() async {
        let actions = Actions()
        let announcements = Announcements()
        let model = await loaded(
            model(Provider([owner: [channel("harbour-join")]]), actions: actions, announcements: announcements), owner: owner
        )
        let id = ConversationID("harbour-join")
        model.performAction(on: id)
        #expect(model.pending.contains(id), "the button doesn't load")
        await settle { !model.pending.contains(id) }
        #expect(actions.calls == ["join harbour-join"])
        #expect(model.action(for: id) == .open)
        #expect(model.channel(id)?.channel.subscriberCount == 11)
        #expect(announcements.changes.count == 1)
        #expect(announcements.changes.first?.0 == id)
        #expect(announcements.changes.first?.2 == .subscriber)
    }

    /// Request turns to Requested; its confirmed cancel back to Request.
    @Test func requestThenCancel() async {
        let actions = Actions()
        let model = await loaded(
            model(Provider([owner: [channel("printroom", visibility: .onRequest)]]), actions: actions), owner: owner
        )
        let id = ConversationID("printroom")
        model.performAction(on: id)
        await settle { model.action(for: id) == .requested }
        #expect(model.action(for: id) == .requested)
        // A tap on Requested writes nothing: its menu does.
        model.performAction(on: id)
        #expect(actions.calls == ["request printroom"])
        model.cancelRequest(on: id)
        await settle { model.action(for: id) == .requestToJoin }
        #expect(actions.calls == ["request printroom", "cancel printroom"])
    }

    /// A refused write leaves the row as it was, and its button says so.
    @Test func aRefusedWriteLeavesTheRow() async {
        let actions = Actions()
        actions.refuses = true
        // A channel of its own: standings are announced app-wide, and a join
        // of "harbour" in a test running beside this one turned this row to
        // Open (seen running the suite).
        let model = await loaded(model(Provider([owner: [channel("harbour-refused")]]), actions: actions), owner: owner)
        var failed: [ConversationID] = []
        model.onActionFailed = { failed.append($0) }
        let id = ConversationID("harbour-refused")
        model.performAction(on: id)
        await settle { !failed.isEmpty }
        #expect(failed == [id])
        #expect(model.action(for: id) == .join)
        #expect(model.pending.isEmpty)
    }

    /// Open, and a tap on the row, open the channel's thread.
    @Test func openAndARowTapOpenTheThread() async {
        let actions = Actions()
        let rows = [channel("tides", state: .subscriber), channel("harbour")]
        let model = await loaded(model(Provider([owner: rows]), actions: actions), owner: owner)
        model.performAction(on: ConversationID("tides"))
        #expect(actions.opened == [ConversationID("tides")])
        #expect(actions.calls.isEmpty, "Open wrote")

        let page = ProfileChannelsPage(model: model, pipeline: nil)
        page.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        page.layoutIfNeeded()
        page.debugSelect(.channel(ConversationID("harbour")))
        #expect(actions.opened == [ConversationID("tides"), ConversationID("harbour")], "a non-member's tap didn't open it")
    }

    /// A card's tap on one of these channels (a showcase on the profile's
    /// Posts) shows on its row.
    @Test func aCardsTapShowsOnTheRow() async {
        let model = await loaded(model(Provider([owner: [channel("harbour")]])), owner: owner)
        let id = ConversationID("harbour")
        PostEmbedView.announceChannelStanding(id, from: .none, to: .subscriber)
        #expect(model.action(for: id) == .open)
        ChannelEmbedLocalState.reset()
    }

    // MARK: - On the screen

    private func screen(channels: ProfileChannelsViewModel?) -> ProfileViewController {
        ProfileViewController(
            viewModel: ProfileViewModel(repository: Profiles()),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: {},
            trayPlacement: .aboveBottomSafeArea,
            channels: channels
        )
    }

    /// The flag off: no model, so no Channels page in the pager and no tab,
    /// ever.
    @Test func withTheChannelsOffThereIsNoTab() {
        let screen = screen(channels: nil)
        screen.loadViewIfNeeded()
        #expect(!screen.galleryPager.allTabs.contains(.channels))
        #expect(!screen.debugTabTitles.contains("Channels"))
    }

    /// The own profile's channels land: the tab comes, after Posts, and its
    /// page draws "Create a Channel" then the channels.
    @Test func theTabComesWithTheChannels() async throws {
        let provider = Provider([viewer: [channel("daily", state: .member)]])
        let channels = model(provider, own: true)
        let screen = screen(channels: channels)
        screen.loadViewIfNeeded()
        #expect(screen.galleryPager.allTabs.contains(.channels))
        // The read, then the tab: on a starved runner the tab's wait ran out
        // before the read had landed (seen running the suite).
        await settle { provider.asked.first != nil }
        await settle { screen.debugTabTitles.contains("Channels") }
        await settle {
            (screen.galleryPager.builtPage(for: .channels) as? ProfileChannelsPage)?.debugRowIDs.isEmpty == false
        }
        #expect(provider.asked.first == viewer, "the channels of someone else were asked")
        #expect(Array(screen.debugTabTitles.prefix(2)) == ["Posts", "Channels"])
        let page = try #require(screen.galleryPager.builtPage(for: .channels) as? ProfileChannelsPage)
        #expect(page.debugRowIDs == [.create, .channel(ConversationID("daily"))])
    }
}
