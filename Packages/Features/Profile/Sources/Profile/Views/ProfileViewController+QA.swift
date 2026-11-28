#if DEBUG
import CoreModels
import CoreNavigation
import DebugDashboard
import DesignSystem
import FeedInterface
import LaunchArguments
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import ProfileData
import ProfileInterface
import ShareSheet
import UIKit

// MARK: - QA hooks
//
// The frame steppers and drives the launch-argument hooks call
// (`ProfileDebugHooks`), the probes,
// and the `debug*` accessors that read nothing private beyond the stored
// members widened for them. Private methods stay private: this file reaches
// them through thin `debug*` wrappers in the main file
// (`debugMapFavoriteMenuActions`, `debugGalleryMenuActions`). Left in `ProfileViewController.swift` because they read
// more of this screen's private state: the bar and menu accessors, the refresh and
// header-height accessors, `traceReadiness` and the
// `DebugInteractivelyDismissible` conformance. Stored DEBUG properties stay
// with the type.

// MARK: - Drives

extension ProfileViewController {
    /// One frame of `-profile-scroll-sweep`: 0 → 240pt → 0, eased, 3s a leg.
    func debugSweepStep(began: CFTimeInterval, probe: HeroScrollFrameProbe) {
        let t = CACurrentMediaTime() - began
        guard t < 6 else { return probe.finish() }
        let leg = t < 3 ? t / 3 : (6 - t) / 3
        probe.frame {
            _ = galleryPager.debugSetVerticalOffset(CGFloat(240 * leg * leg * (3 - 2 * leg)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugSweepStep(began: began, probe: probe)
        }
    }

    /// One frame of `-profile-stretch-sweep` (`HeroStretchSweep`). The
    /// release goes through the pager's own release callback, past the
    /// refresh threshold — the indicator spins and the profile reloads.
    func debugStretchStep(
        began: CFTimeInterval, probe: HeroScrollFrameProbe, phase: HeroStretchSweep.Phase?
    ) {
        guard let (now, offset) = HeroStretchSweep.at(CACurrentMediaTime() - began) else { return probe.finish() }
        if now != phase {
            probe.beginPhase(now.rawValue)
            if now == .release { debugFingerPull(by: HeroStretchSweep.depth) }
        }
        probe.frame { _ = galleryPager.debugSetVerticalOffset(offset) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.debugStretchStep(began: began, probe: probe, phase: now)
        }
    }

    /// Waits for the map-pin bubble to be OFFERED, then taps it — through the
    /// same callback a finger fires, so what QA exercises is the real path.
    ///
    /// Polled rather than delayed for the reason the relationships push
    /// documents: two reads have to land first (the relationship, then the pin
    /// state), and under `-mock-latency` a fixed delay fires into a button
    /// that is not there yet — reporting a working feature by pressing
    /// nothing.
    func pollForMapPinButton(attempt: Int = 0) {
        guard attempt < 40 else {
            print("[profile] map-pin demo: the button never appeared")
            return
        }
        guard viewModel.mapPinButton != .hidden else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pollForMapPinButton(attempt: attempt + 1)
            }
            return
        }
        print("[profile] map-pin demo: state was \(viewModel.mapPinButton)")
        printMapFavoriteMenu(stage: "before")
        // A value after the flag drives the MUTUAL's path — the menu rows,
        // which a simulator cannot open (no taps, and `UIMenu` needs one).
        // Bare, it is the plain follower's tap.
        let choice = LaunchArgument.profileMapPinDemo.value()
            .flatMap { value -> Set<MapFavoriteCategory>? in
                switch value {
                case "dock": [.dock]
                case "following": [.following]
                case "friends": [.friends]
                case "all": [.dock, .following, .friends]
                case "none": []
                default: nil // the next launch flag, not a value
                }
            }
        if let choice {
            viewModel.setMapCategories(choice)
        } else {
            // Bare: the dock is the rail every followed profile has and the
            // one visible without selecting a primary.
            viewModel.toggleMapCategory(.dock)
        }
        print("[profile] map-pin demo: state now \(viewModel.mapPinButton)")
        printMapFavoriteMenu(stage: "after")
    }

    /// Prints the checklist the CURRENT state resolves to — the rows and their
    /// checkmarks. The menu opens on a tap and the simulator has none, so this
    /// is the only way a scripted run can tell a ticked row from an unticked
    /// one; the alternative is asserting the rows exist and hoping the marks
    /// followed. Same instrument as `-profile-menu-audit` for the "..." menu.
    private func printMapFavoriteMenu(stage: String) {
        guard viewModel.mapPinButton != .hidden else {
            print("[profile] map-pin menu (\(stage)): none — no Map submenu on this profile")
            return
        }
        let rows = debugMapFavoriteMenuActions()
            .map { "\($0.title)=\($0.state == .on ? "on" : "off")" }
        print("[profile] map-pin menu (\(stage)): \(rows.joined(separator: " "))")
    }

    /// Opens the editor's Privacy row from QA. Reaches through the pushed
    /// editor rather than building the screen here, so what is verified is the
    /// real wiring and not a second path to the same class.
    func qaOpenPrivacy() {
        // Says so when it cannot: an optional-chained call here was the silent
        // no-op that let a run with no Privacy screen read as a pass.
        guard let editor = navigationController?.topViewController as? EditProfileViewController else {
            QAWait.fail("profile-edit-privacy", "the editor is not on top")
            return
        }
        guard editor.onOpenPrivacy != nil else {
            QAWait.fail("profile-edit-privacy", "the editor has no Privacy route wired")
            return
        }
        editor.qaOpenPrivacy()
    }

    /// `-profile-share-demo <step>`: what runs inside the QR sheet once it has
    /// finished presenting. Lifted out of `viewDidAppear` only to keep the
    /// gated chain there readable; the steps and their pacing are unchanged.
    func qaRunShareChain(_ chained: String?) {
        let sheet = presentedViewController as? ProfileShareViewController
        if sheet == nil {
            // The gate waited for this sheet; a nil here means it went away
            // between the check and the step, and every call below would
            // optional-chain into nothing.
            QAWait.fail("profile-share-demo \(chained ?? "")", "the share sheet is not presented")
            return
        }
        switch chained {
        case "activity": sheet?.qaHandOffToSystemShare()
        case "send": sheet?.qaSendToFirstTarget()
        case "search-scroll":
            sheet?.qaBeginSearch("a")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                sheet?.qaScrollResults(by: 90)
            }
        case "search-lower":
            // Lower the keyboard, then report whether Cancel is
            // still usable and fire it — the exact sequence that
            // used to strand the user in search.
            sheet?.qaBeginSearch("a")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                sheet?.qaLowerKeyboard()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    // Reported separately: a missing sheet and an
                    // unusable button are different failures, and
                    // `?? false` conflated them.
                    print("CANCEL-USABLE sheet=\(sheet != nil) "
                        + "usable=\(sheet.map(\.qaCancelIsUsable).map(String.init) ?? "n/a")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        sheet?.qaTapCancel()
                    }
                }
            }
        default:
            // `search-empty` opens search WITHOUT typing, which is
            // the suggestions-on-entry state.
            sheet?.qaBeginSearch(chained == "search-empty" ? "" : "a")
            // `search-cancel` also backs out again, so the
            // restored state is screenshottable.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                switch chained {
                case "search-cancel": sheet?.qaCancelSearch()
                case "search-send": sheet?.qaSelectFirstResult()
                default: break
                }
            }
        }
    }

    /// `-profile-bar-demo` (#2475): scrolls past the threshold over a second
    /// and a half, taps the last page, the first and a middle one, then
    /// scrolls back to the top — what the hand-off recording films.
    func qaRunBarDemo() {
        let past = headerTravel + 60
        func glide(from start: CGFloat, to end: CGFloat, began: CFTimeInterval, then: @escaping () -> Void) {
            let t = min(1, (CACurrentMediaTime() - began) / 1.5)
            let eased = t * t * (3 - 2 * t)
            _ = galleryPager.debugSetVerticalOffset(start + (end - start) * eased)
            guard t < 1 else { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { glide(from: start, to: end, began: began, then: then) }
        }
        print("[bar-demo] travel=\(headerTravel) tabs=\(tabs.map(\.title))")
        glide(from: 0, to: past, began: CACurrentMediaTime()) { [weak self] in
            guard let self else { return }
            let last = tabs.count - 1
            let steps = [last, 0, last / 2]
            for (index, tab) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(index + 1)) { [weak self] in
                    guard let self, tabs.indices.contains(tab) else { return }
                    selectTab(at: tab)
                    // The new page keeps the threshold: the header's travel.
                    _ = galleryPager.debugSetVerticalOffset(past)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(steps.count + 1)) {
                glide(from: past, to: 0, began: CACurrentMediaTime()) { print("[bar-demo] done") }
            }
        }
    }

    /// `-profile-history-select` (#2475): History, past the threshold, in
    /// its select mode.
    func qaSelectHistory() {
        guard let history = tabs.firstIndex(of: .history) else {
            print("[history-select] no History page: \(tabs.map(\.title))")
            return
        }
        selectTab(at: history)
        _ = galleryPager.debugSetVerticalOffset(headerTravel + 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.setSelectingPile(true)
            print("[history-select] selecting=\(self?.isSelectingPile ?? false)")
        }
    }

    /// Fires the relationship item through its own primary action — the same
    /// closure UIKit invokes on a tap, reached from the item rather than from
    /// a copy of the call. The Follow capsule is a bar item, which the
    /// simulator cannot tap, so this is the only way to prove the wiring
    /// survived the conversion off target/action.
    func qaTapFollowItem() {
        print("PROFILE-FOLLOW-TAP before=\(followButtonState)")
        guard let follow = relationToolbarItem(.follow)?.customView as? StretchedBarLabel else {
            print("PROFILE-FOLLOW-TAP the toolbar shows no Follow")
            return
        }
        follow.debugTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            print("PROFILE-FOLLOW-TAP after=\(self.followButtonState)")
        }
    }
}

// MARK: - Probes

extension ProfileViewController {
    /// `-post-menu-audit`: prints the rows a gallery card's "..." offers here.
    ///
    /// The interesting assertion is a NEGATIVE one — that Unfollow is absent —
    /// and a screenshot of a closed menu cannot make it. Runs the REAL
    /// composition rather than restating it, so an audit that agrees with the
    /// screen is evidence rather than a second opinion. See the For You side,
    /// which prints the same line for the surface that does offer Unfollow.
    func auditPostMenu(_ snapshot: ProfileViewModel.GallerySnapshot) {
        guard LaunchArgument.postMenuAudit.isPassed(),
              case .content(let posts) = snapshot.activity,
              let post = posts.first(where: { $0.authorID != nil }),
              let authorID = post.authorID
        else { return }
        // Prints the author too, because the answer now depends on WHOSE post
        // it is — an empty row list on your own profile is the rule working,
        // not the wiring missing.
        let rows = debugGalleryMenuActions(
            for: PostGridAuthorMenuContext(
                post: post, authorID: authorID, anchor: UIView()
            )
        )
        print("[post-menu-audit] profile author=\(authorID.rawValue) rows=\(rows.map(\.title))")
    }

    /// `-profile-verify-reveal`: does the revealed tile clear the selector, in
    /// the settled state, measured against the selector's own frame?
    ///
    /// Independent of `chromeOcclusion` on purpose. The reveal log derived its
    /// "gap" from the very inset the reveal had just applied, so it read clean
    /// whatever the tile did — including while the tile sat under the selector.
    func verifyRevealClearsSelector() {
        guard LaunchArgument.profileVerifyReveal.isPassed() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let window = view.window else { return }
            guard let tile = galleryPager.debugRevealedTileInWindow() else {
                print("[verify-reveal] no revealed tile"); return
            }
            let bar = selectorBar
            let selector = bar.window == nil ? .zero : bar.convert(bar.bounds, to: window)
            let navBar = navigationController?.navigationBar
            let nav = navBar?.window == nil ? CGRect.zero
                : navBar!.convert(navBar!.bounds, to: window)
            let chromeBottom = max(selector.maxY, nav.maxY)
            print(String(format:
                "[verify-reveal] tileTop=%.0f selector=%.0f…%.0f navBottom=%.0f "
                + "chromeBottom=%.0f clearance=%.0f %@",
                tile.minY, selector.minY, selector.maxY, nav.maxY,
                chromeBottom, tile.minY - chromeBottom,
                tile.minY >= chromeBottom ? "CLEAR" : "COVERED"))
        }
    }
}

// MARK: - Accessors

extension ProfileViewController {
    /// What the toolbar's Follow says — Follow or Requested — nil while it
    /// shows none (#2475) — for tests and QA probes.
    var debugFollowTitle: String? { (relationToolbarItem(.follow)?.customView as? StretchedBarLabel)?.title }
    /// The toolbar reads "followed" (#2302): the bell beside Message, or
    /// Message alone where there is no bell — never Following, never Follow.
    var debugShowsFollowed: Bool {
        followButtonState == .following && relationActions.toolbar.shownItems.map {
            !$0.contains(.follow) && !$0.contains(.requested) && $0.contains(.message)
        } == true
    }
    /// Whether the toolbar's Follow is the prominent call to action.
    var debugFollowIsProminent: Bool { relationToolbarItem(.follow)?.style == .prominent && debugFollowTitle == "Follow" }
    /// The toolbar's items, leading to trailing (#2475) — nil before the
    /// first composition.
    var debugToolbarKinds: [ProfileRelationToolbar.Item]? { relationActions.toolbar.shownItems }
    /// The bell's glyph, while the toolbar shows it (#2302).
    var debugMuteBellSymbol: String? { relationActions.toolbar.debugBellSymbol }
    /// The bar's groups by identifier, the spaces left out: the leading
    /// group after the chevron, the trailing one from the bar's edge in.
    var debugLeadingIDs: [String] { Self.identifiers(navigationItem.leftBarButtonItems) }
    /// Saved's page, once built (its select mode, the owner 2026-11-28). Tests.
    var debugSavedPage: (any PostGridPage)? { galleryPager.builtPage(for: .saved) }
    var debugTrailingIDs: [String] { Self.identifiers(navigationItem.rightBarButtonItems) }
    private static func identifiers(_ items: [UIBarButtonItem]?) -> [String] {
        (items ?? []).compactMap { item in
            let isSpace = item.customView == nil && item.image == nil && item.title == nil && item.menu == nil
                && item.primaryAction == nil
            return isSpace ? nil : (item.identifier ?? "?")
        }
    }
    /// The bar's item for `identifier`, if it shows one.
    func debugBarItem(_ identifier: String) -> UIBarButtonItem? {
        ((navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? []))
            .first { $0.identifier == identifier }
    }
    var debugIsHeaderRedacted: Bool { headerView.debugIsRedacted }
    var debugHasAvatarPicture: Bool { headerView.debugHasAvatarPicture }

    /// A finger pulls past the threshold and lets go, through the screen's
    /// own pull path and the app's rule (#2235).
    func debugReleasePull() {
        debugFingerPull(by: HeroPullToRefreshView.threshold + 40)
    }

    /// Puts the active page at `offset` (negative: pulled past its top) and
    /// lays the screen out — one frame of a scroll.
    func debugScrollFrame(to offset: CGFloat) {
        _ = galleryPager.debugSetVerticalOffset(offset)
        view.window?.layoutIfNeeded()
    }
}

extension ProfileViewController: DebugItemSelectable {
    /// Taps the active gallery page's first tile through its own delegate
    /// method — the path that builds a hero origin and flies.
    func debugSelectFirstItem() -> Bool {
        galleryPager.debugSelectItem(at: 0)
    }
}
#endif
