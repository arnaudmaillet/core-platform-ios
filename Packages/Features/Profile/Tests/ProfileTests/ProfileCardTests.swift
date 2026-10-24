import CoreModels
import Foundation
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Profile

private actor CardProfileProvider: ProfileProviding {
    private let profile: UserProfile
    private let following: Bool
    init(_ profile: UserProfile, following: Bool) {
        self.profile = profile
        self.following = following
    }

    func currentUserProfile() async throws -> UserProfile { profile }
    func profile(id: ProfileID) async throws -> UserProfile { profile }
    func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
        .other(isFollowing: following, isBlocked: false)
    }
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
    func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
    func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
    func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile {
        profile
    }
    func changeHandle(_ newHandle: String) async throws -> UserProfile { profile }
}

/// The profile card sheet (#1524): what a bottom toolbar's author pill opens.
@MainActor
@Suite(.serialized)
struct ProfileCardTests {
    private static let ada = UserProfile(
        id: ProfileID("prof-1"), handle: "ada", displayName: "Ada Lovelace", bio: "Countess of computing",
        avatarURL: nil, websiteURL: nil, isVerified: true,
        followerCount: .exact(1_234), followingCount: .exact(56), reactionCount: .exact(9_800)
    )

    private final class Host { var window: UIWindow? }

    private func makeCard(following: Bool, host: Host) async throws -> ProfileCardViewController {
        let card = ProfileCardViewController(
            viewModel: ProfileViewModel(
                repository: CardProfileProvider(Self.ada, following: following), source: .profile(ProfileID("prof-1"))
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            shareTargeting: nil,
            makeRelationshipsViewController: nil,
            identityStub: nil,
            actions: .init(openProfile: {}, push: { _ in })
        )
        let navigation = card.wrappedInSheet()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        host.window = window
        navigation.view.layoutIfNeeded()
        try #require(await settle { card.followButtonState == (following ? .following : .follow) },
                     "guard: the relationship landed")
        return card
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    // MARK: - The toolbar

    /// Follow (prominent) / Following / Requested, Message and •••, by
    /// relationship; Message and ••• alone while it is unknown or not
    /// followable; the viewer's own profile only opens it.
    @Test func theToolbarFollowsTheRelationship() {
        typealias Item = ProfileCardViewController.ToolbarItem
        // ⚠️ THE OWNER'S BARS (#1562): Follow / the bell, Message, the QR.
        #expect(ProfileCardViewController.toolbarItems(for: .follow) == [Item.follow, .message, .qr])
        #expect(ProfileCardViewController.toolbarItems(for: .following) == [Item.bell, .message, .qr])
        #expect(ProfileCardViewController.toolbarItems(for: .following, showsBell: false) == [Item.message, .qr],
                "a viewer who cannot mute got a bell")
        #expect(ProfileCardViewController.toolbarItems(for: .requested) == [Item.requested, .message, .qr])
        #expect(ProfileCardViewController.toolbarItems(for: .unavailable) == [Item.message, .qr])
        #expect(ProfileCardViewController.toolbarItems(for: .hidden, showsQR: false) == [Item.message])
        #expect(ProfileCardViewController.toolbarItems(for: .edit) == [Item.openProfile])
        #expect(ProfileCardViewController.showsMoreMenu(for: .following))
        #expect(!ProfileCardViewController.showsMoreMenu(for: .edit))
    }

    /// The free width (#1542): Follow while not following, Requested in the
    /// same slot once asked (#1668), Message once following (or not
    /// followable); nothing on the viewer's own.
    @Test func thePrimaryActionTakesTheFreeWidth() {
        typealias Card = ProfileCardViewController
        #expect(Card.wideItem(in: Card.toolbarItems(for: .follow)) == .follow)
        #expect(Card.wideItem(in: Card.toolbarItems(for: .following)) == .message)
        #expect(Card.wideItem(in: Card.toolbarItems(for: .requested)) == .requested)
        #expect(Card.barShape(Card.toolbarItems(for: .follow)) == Card.barShape(Card.toolbarItems(for: .requested)),
                "Follow and Requested are not one bar")
        #expect(Card.wideItem(in: Card.toolbarItems(for: .unavailable)) == .message)
        #expect(Card.wideItem(in: Card.toolbarItems(for: .edit)) == nil)
    }

    // MARK: - The moving pictures (#1541)

    /// The card's header plays its video banner on the app's pool, by the
    /// header's one rule — never while its host is not on show; and the
    /// rule is the same object the profile asks.
    @Test func theCardsBannerPlaysByTheHeadersRule() {
        let pool = VideoPlaybackController(source: CardVideoSource(), poolSize: 1)
        let card = ProfileCardViewController(
            viewModel: ProfileViewModel(
                repository: CardProfileProvider(Self.ada, following: false), source: .profile(ProfileID("prof-1"))
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            shareTargeting: nil,
            makeRelationshipsViewController: nil,
            identityStub: nil,
            actions: .init(openProfile: {}, push: { _ in }),
            videoPlayback: pool
        )
        #expect(card.headerView.bannerVideoPool === pool, "the card's banner has no pool to play on")
        #expect(!card.headerView.bannerShouldPlay(hostShowing: false), "a banner plays for a host not on show")
        #expect(!card.headerView.bannerShouldPlay(hostShowing: true), "a banner off any window plays")
    }

    // MARK: - The top bar

    /// The bell while the viewer follows — a member, a profile that can be
    /// muted — and never otherwise.
    @Test func theBellStandsOnlyWhileFollowing() {
        #expect(ProfileCardViewController.showsMuteBell(followButton: .following, canMute: true, isGuest: false))
        #expect(!ProfileCardViewController.showsMuteBell(followButton: .follow, canMute: true, isGuest: false))
        #expect(!ProfileCardViewController.showsMuteBell(followButton: .requested, canMute: true, isGuest: false))
        #expect(!ProfileCardViewController.showsMuteBell(followButton: .following, canMute: true, isGuest: true),
                "a guest has nothing to mute from")
        #expect(!ProfileCardViewController.showsMuteBell(followButton: .following, canMute: false, isGuest: false))
    }

    /// Not followed: the ••• alone on the left (#1562), ✕ on the right; the
    /// header keeps no tray (its actions are the bars').
    @Test func notFollowedTheTopBarIsTheMenuAndClose() async throws {
        let host = Host()
        let card = try await makeCard(following: false, host: host)
        #expect(card.navigationItem.leftBarButtonItems?.map(\.accessibilityLabel) == ["More"], "not the ••• alone")
        #expect(card.toolbarItems?.contains { $0.accessibilityLabel == "QR Code" } == true, "the QR is not in the toolbar")
        #expect(card.navigationItem.rightBarButtonItem != nil, "no ✕")
        #expect(!card.headerView.showsActionTray, "the header kept its tray")
        #expect(card.wideButton?.configuration?.title == "Follow", "Follow is not the stretched item")
    }

    /// Follow → Requested changes the stretched button in place: the same
    /// bar items, the same button, its words changed (#1668).
    @Test func followToRequestedKeepsTheBar() async throws {
        let host = Host()
        let card = try await makeCard(following: false, host: host)
        let items = try #require(card.toolbarItems)
        let button = try #require(card.wideButton)
        card.debugApplyFollowButton(.requested)
        #expect(card.toolbarItems?.count == items.count)
        #expect(zip(card.toolbarItems ?? [], items).allSatisfy { $0 === $1 }, "the bar was rebuilt")
        #expect(card.wideButton === button, "the stretched button was replaced")
        #expect(button.configuration?.title == "Requested")
        card.debugApplyFollowButton(.follow)
        #expect(button.configuration?.title == "Follow")
    }

    /// Followed: Message takes the free width (#1542), Following is gone
    /// from the toolbar (#1562) and its Unfollow leads the ••• menu.
    @Test func followedMessageIsTheStretchedItem() async throws {
        let host = Host()
        let card = try await makeCard(following: true, host: host)
        #expect(card.wideButton?.configuration?.title == "Message")
        #expect(card.toolbarItems?.contains { $0.title == "Following" } != true, "Following stayed in the toolbar")
        #expect(card.debugMoreMenuTitles.first == "Unfollow", "no Unfollow at the head of the ••• menu")
    }

    // MARK: - The detent

    /// One detent, the content's height: the header climbed to the profile's
    /// second notch, and the toolbar.
    @Test func theDetentIsTheContent() async throws {
        let host = Host()
        let card = try await makeCard(following: true, host: host)
        card.remeasure()
        #expect(card.sheetHeight == card.visibleHeaderHeight + card.toolbarBand)
        let header = card.headerView.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        #expect(abs(card.visibleHeaderHeight - ProfileCardViewController.visibleHeight(headerHeight: header, climb: card.climb)) <= 1)
        #expect(card.navigationController?.sheetPresentationController?.detents.count == 1, "more than one detent")
    }

    /// The profile info opens the full profile; a control under it (a
    /// counter) keeps its own tap.
    @Test func theInfoOpensTheProfileAndAControlKeepsItsTap() {
        var opened = 0
        let card = ProfileCardViewController(
            viewModel: ProfileViewModel(
                repository: CardProfileProvider(Self.ada, following: false), source: .profile(ProfileID("prof-1"))
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            shareTargeting: nil, makeRelationshipsViewController: nil, identityStub: nil,
            actions: .init(openProfile: { opened += 1 }, push: { _ in })
        )
        card.debugTapInfo()
        #expect(opened == 1, "the info did not open the profile")

        let root = UIView()
        let control = UIControl()
        let label = UILabel()
        root.addSubview(control)
        control.addSubview(label)
        let plain = UIView()
        root.addSubview(plain)
        #expect(ProfileCardViewController.touchLandsOnControl(label, below: root))
        #expect(!ProfileCardViewController.touchLandsOnControl(plain, below: root))
    }

    /// The climb is the profile's notch on a band, nothing off one.
    @Test func theClimbIsTheProfilesNotch() {
        #expect(ProfileCardViewController.climb(bandAvatarDetent: 214) == 214)
        #expect(ProfileCardViewController.climb(bandAvatarDetent: nil) == 0)
        #expect(ProfileCardViewController.visibleHeight(headerHeight: 600.2, climb: 214) == 387)
    }
}

/// A video source that resolves nothing: the pool is all a test reads.
private struct CardVideoSource: VideoSource {
    func playableURL(for url: URL) async throws -> URL { url }
}
