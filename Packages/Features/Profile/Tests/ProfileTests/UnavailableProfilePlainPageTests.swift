import CoreModels
import DesignSystem
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Profile

/// An unavailable profile is a PLAIN PAGE (#1406, the owner 2026-10-18): no
/// banner card — with no picture it drew its placeholder ramp, a banner that
/// looked like it failed to load — no wallet chip, only the back button; the
/// centred symbol, "This account isn't available" and a quieter line that
/// says nothing about which of hidden, suspended or deleted it is.
@MainActor
struct UnavailableProfilePlainPageTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private actor Profiles: ProfileProviding {
        let shown: UserProfile
        private var isGone: Bool

        init(_ shown: UserProfile, gone: Bool) {
            self.shown = shown
            isGone = gone
        }

        func currentUserProfile() async throws -> UserProfile {
            if isGone { throw ProfileError.notFound }
            return shown
        }
        func profile(id: ProfileID) async throws -> UserProfile {
            if isGone { throw ProfileError.notFound }
            return shown
        }
        func relationship(for profileID: ProfileID) async throws -> ProfileRelationship {
            .other(isFollowing: false, isBlocked: false)
        }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}
        func setBlocked(_ blocked: Bool, for profileID: ProfileID) async throws {}
        func blockAccount(behind profileID: ProfileID) async throws -> [ProfileID] { [profileID] }
        func updateCurrentUserProfile(displayName: String, bio: String, website: String, links: [ProfileLink]) async throws -> UserProfile { shown }
        func changeHandle(_ newHandle: String) async throws -> UserProfile { shown }
    }

    private let id = ProfileID("prof-20")

    /// Someone with a banner: the card stands on their page while it shows.
    private func person() -> UserProfile {
        UserProfile(
            id: id, handle: "nadia", displayName: "Nadia", bio: "", avatarURL: nil,
            bannerURL: URL(string: "https://example.com/banner.jpg"), websiteURL: nil,
            isVerified: false, visibility: .public,
            followerCount: .exact(3), followingCount: .exact(3), reactionCount: .unavailable
        )
    }

    /// Waits for STATE, in looks (6,000 × 10 ms), never wall-clock time.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The shell's balance, as it hands it over.
    private func walletChip() -> UIBarButtonItem {
        let item = UIBarButtonItem(customView: UIView())
        item.accessibilityLabel = "Balance"
        return item
    }

    /// A pushed profile — someone else's, with a back button — wearing the
    /// shell's balance, over `profiles` (and `cache`, for a revisit).
    private func pushedProfile(
        _ profiles: Profiles, cache: ProfileCache? = nil, chip: UIBarButtonItem
    ) -> (UINavigationController, ProfileViewController) {
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: profiles, source: .profile(id), cache: cache),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: nil,
            trayPlacement: .aboveBottomSafeArea
        )
        screen.setTrailingAccessoryItem(chip)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(screen, animated: false)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.loadViewIfNeeded()
        return (navigation, screen)
    }

    private func shown(in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01 else { return [] }
        return [view] + view.subviews.flatMap(shown(in:))
    }

    private func label(_ text: String, in view: UIView) -> UILabel? {
        shown(in: view).compactMap { $0 as? UILabel }.first { $0.text == text }
    }

    private func readsUnavailable(_ screen: ProfileViewController) -> Bool {
        screen.view.layoutIfNeeded()
        return label(ProfileViewModel.unavailableTitle, in: screen.view) != nil
    }

    // MARK: - Acceptance

    /// AC1: no banner card and no wallet chip; the back button stays.
    @Test func anUnavailableProfileShowsNoBannerCardAndNoWalletChip() async {
        let chip = walletChip()
        let (navigation, screen) = pushedProfile(Profiles(person(), gone: true), chip: chip)
        #expect(await settle { readsUnavailable(screen) })
        #expect(await settle { (screen.navigationItem.rightBarButtonItems ?? []).isEmpty },
                "the bar still carries \(screen.navigationItem.rightBarButtonItems ?? [])")
        #expect(screen.headerView.debugBannerIsHidden, "the banner card is still up")
        // The way back: pushed, not hiding its back button, nothing replacing it.
        #expect(navigation.viewControllers.count == 2)
        #expect(!screen.navigationItem.hidesBackButton)
        #expect(screen.navigationItem.leftItemsSupplementBackButton || (screen.navigationItem.leftBarButtonItems ?? []).isEmpty)
        // A shell handing its balance over again does not bring it back.
        screen.setTrailingAccessoryItem(walletChip())
        #expect((screen.navigationItem.rightBarButtonItems ?? []).isEmpty)
        withExtendedLifetime(navigation) {}
    }

    /// The viewer's own tab root whose active profile is gone keeps its gear
    /// and its switcher — its only way to settings, log out or another
    /// profile — and loses only the balance.
    @Test func theOwnProfileTabRootKeepsItsWayToSettings() async throws {
        let chip = walletChip()
        let screen = ProfileViewController(
            viewModel: ProfileViewModel(repository: Profiles(person(), gone: true)),
            imagePipeline: ImagePipeline(fetcher: SilentFetcher()),
            makeGridPage: TestGridPages.factory(),
            onLogout: {},
            trayPlacement: .aboveBottomSafeArea
        )
        screen.setTrailingAccessoryItem(chip)
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.loadViewIfNeeded()
        #expect(await settle { readsUnavailable(screen) })
        #expect(await settle { screen.navigationItem.rightBarButtonItems?.contains { $0 === chip } == false })
        let items = try #require(screen.navigationItem.rightBarButtonItems)
        #expect(items.contains { $0.accessibilityLabel == "Settings" }, "the gear went with the balance")
        #expect(screen.headerView.debugBannerIsHidden)
    }

    /// AC2: the title and the quieter secondary line, centred, in the app's
    /// type (`.appFont(forTextStyle:)`) — and saying nothing about which.
    @Test func theUnavailableCopyIsCentredInTheAppsType() async throws {
        #expect(ProfileViewModel.unavailableTitle == "This account isn\u{2019}t available")
        #expect(ProfileViewModel.unavailableDetail == "It may have been removed or hidden.")
        #expect(ProfileViewModel.unavailable == .notFound(
            message: ProfileViewModel.unavailableTitle, detail: ProfileViewModel.unavailableDetail
        ))

        let (navigation, screen) = pushedProfile(Profiles(person(), gone: true), chip: walletChip())
        #expect(await settle { readsUnavailable(screen) })
        let title = try #require(label(ProfileViewModel.unavailableTitle, in: screen.view))
        let detail = try #require(label(ProfileViewModel.unavailableDetail, in: screen.view))
        #expect(title.font == UIFont.appFont(forTextStyle: .headline))
        #expect(detail.font == UIFont.appFont(forTextStyle: .subheadline))
        #expect(title.adjustsFontForContentSizeCategory && detail.adjustsFontForContentSizeCategory)
        // Quieter: the secondary ink under the primary.
        #expect(title.textColor == .label)
        #expect(detail.textColor == .secondaryLabel)
        for line in [title, detail] {
            #expect(line.textAlignment == .center)
            let frame = line.convert(line.bounds, to: screen.view)
            #expect(abs(frame.midX - screen.view.bounds.midX) < 1, "\(line.text ?? "") is off centre: \(frame)")
        }
        withExtendedLifetime(navigation) {}
    }

    /// AC3: a revisit opens on the cached profile — banner card and balance
    /// up — and its revalidation answers not-found (#1403's eviction). The
    /// very render that says so takes the card away: no frame shows the
    /// card over the unavailable block. And a banner picture landing late
    /// cannot bring it back.
    @Test func aCachedRevisitThatTurnsUnavailableSwitchesWithoutABannerFlash() async throws {
        let cache = ProfileCache(center: NotificationCenter())
        cache.store(person())
        let chip = walletChip()
        let (navigation, screen) = pushedProfile(Profiles(person(), gone: true), cache: cache, chip: chip)

        // Frame 0: the cached profile, its card and the balance.
        #expect(!screen.headerView.debugBannerIsHidden, "the cached revisit opened without its card")
        #expect(screen.navigationItem.rightBarButtonItems?.contains { $0 === chip } == true)

        // Every render from here, as it lands: what it said, and whether the
        // card was up once it had said it.
        let render = try #require(screen.viewModel.onPhaseChange)
        var renders: [(phase: ProfileViewModel.Phase, bannerShown: Bool)] = []
        screen.viewModel.onPhaseChange = { phase in
            render(phase)
            renders.append((phase, !screen.headerView.debugBannerIsHidden))
        }
        #expect(await settle { renders.contains { $0.phase == ProfileViewModel.unavailable } })
        let unavailable = try #require(renders.first { $0.phase == ProfileViewModel.unavailable })
        #expect(!unavailable.bannerShown, "the card outlived the render that said unavailable")
        #expect(cache.profile(for: id) == nil, "evicted")
        #expect(await settle { (screen.navigationItem.rightBarButtonItems ?? []).isEmpty })

        // The banner's picture was on its way: landing now, it stays down.
        screen.headerView.setBannerFormat(.resolved(forImageSize: CGSize(width: 1600, height: 900)))
        #expect(screen.headerView.debugBannerIsHidden)
        #expect(!screen.headerView.isBannerOnScreen)
        withExtendedLifetime(navigation) {}
    }
}
