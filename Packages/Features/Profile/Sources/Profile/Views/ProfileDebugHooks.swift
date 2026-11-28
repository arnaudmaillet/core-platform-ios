#if DEBUG
import CoreModels
import DesignSystem
import LaunchArguments
import ProfileData
import SettingsInterface
import UIKit

/// What the launch-argument hooks ask of the profile page (#2522): its
/// views, its pages, the pushes and menus they drive, and the `+QA` drives.
@MainActor
protocol ProfileDebugHooksHost: UIViewController {
    var viewModel: ProfileViewModel { get }
    var headerView: ProfileHeaderView { get }
    var galleryPager: ProfileGalleryPagerView { get }
    var tabs: [ProfileTab] { get }
    var headerTravel: CGFloat { get }
    var hasEditor: Bool { get }
    var hasSettings: Bool { get }
    func pushEditProfile()
    func pushSettings()
    func pushRelationships(_ direction: RelationshipDirection)
    func selectTab(at index: Int)
    func pushMediaGallery()
    func presentShareSheet()
    func copyProfileLink()
    func moreMenuElements() -> [UIMenuElement]
    func qaOpenPrivacy()
    func qaTapFollowItem()
    func qaRunBarDemo()
    func qaSelectHistory()
    func qaRunShareChain(_ chained: String?)
    func pollForMapPinButton(attempt: Int)
    func debugSweepStep(began: CFTimeInterval, probe: HeroScrollFrameProbe)
    func debugStretchStep(began: CFTimeInterval, probe: HeroScrollFrameProbe, phase: HeroStretchSweep.Phase?)
}

/// The profile page's launch-argument hooks, out of its `viewDidAppear`
/// (#2522): the drives that stand in for taps the simulator cannot make, and
/// (`ProfileDebugHooks+Audits.swift`) the audits and probes that print what
/// the screen resolved to. Armed once, at the end of `viewDidAppear`.
///
/// ⚠️ THE SPOTS THAT HELD THE SCREEN STILL HOLD IT (`let screen = host`): the
/// `-profile-dock` and `-profile-open-post` retries and the probe's print
/// kept the page alive while they ran, and the host is `unowned`.
@MainActor
final class ProfileDebugHooks {
    /// Internal, not private: `+Audits` reads it too.
    unowned let host: any ProfileDebugHooksHost

    init(host: any ProfileDebugHooksHost) {
        self.host = host
    }

    /// Launch-argument hooks are one-shot; see `viewDidAppear`.
    private var hasArmedDebugHooks = false
    /// Latches the `-profile-map-pin-demo` tap to a single firing.
    private var didTapMapPinForQA = false
    /// Latches the `-profile-relationships` QA push to a single firing.
    private var didPushRelationshipsForQA = false

    /// Arms the hooks the launch arguments ask for, once.
    func armOnce() {
        // ARMED ONCE. `viewDidAppear` runs again when a pushed post is dismissed,
        // and re-running these drove a second scroll on top of the background
        // reveal, undoing it moments before any check could look. Every "the
        // reveal was reverted" reading traced back to here, not to the product.
        defer { hasArmedDebugHooks = true }
        if hasArmedDebugHooks { return }
        // Dev convenience: `-profile-overscroll` parks the scroll view in the
        // pulled-down region (no touch injection in the sim), so the banner's
        // stretch-over-overscroll behavior can be screenshotted.
        if LaunchArgument.profileOverscroll.isPassed() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.host.galleryPager.debugOverscroll(by: 140)
            }
        }
        armLayoutInkAndMenuAudits()
        let arguments = ProcessInfo.processInfo.arguments
        // Dev convenience: `-profile-follow-tap` fires the nav-bar Follow /
        // Following item through its own primary action ~2s in, and prints the
        // state either side. A bar item takes no simulated touch, so this is
        // how the item's wiring is verified at all.
        // Dev convenience: `-profile-edit-privacy` pushes the editor and then
        // its Privacy row, which sits behind two taps the simulator can't
        // deliver.
        if LaunchArgument.profileEditPrivacy.isPassed(in: arguments) {
            // Each step waits for the state the next one reads. The push needs
            // a loaded profile (the editor is built from it) and a stack at
            // rest with this screen on top; the Privacy row needs the editor
            // to have LANDED. The fixed 1s between them used to reach for
            // `topViewController as? EditProfileViewController` while the
            // push was still in flight — or had never started — and no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                guard host.hasEditor else {
                    QAWait.fail("profile-edit-privacy", "this profile has no editor (not the viewer's own)")
                    return
                }
                QAWait.until("profile-edit-privacy push", { [weak self] in
                    guard let self, let navigation = host.navigationController else { return false }
                    return host.viewModel.profile != nil
                        && navigation.topViewController === host
                        && navigation.transitionCoordinator == nil
                }) { [weak self] in
                    guard let self else { return }
                    host.pushEditProfile()
                    QAWait.until("profile-edit-privacy open", { [weak self] in
                        guard let navigation = self?.host.navigationController else { return false }
                        return navigation.topViewController is EditProfileViewController
                            && navigation.transitionCoordinator == nil
                    }) { [weak self] in
                        self?.host.qaOpenPrivacy()
                    }
                }
            }
        }
        // `-profile-bar-demo` (#2475): past the threshold and back, the
        // pages tapped between — the selector's hand-off, filmable.
        if LaunchArgument.profileBarDemo.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.host.qaRunBarDemo() }
        }
        // `-profile-history-select` (#2475): History, past the threshold, in
        // its select mode — the bar's Done and Remove.
        if LaunchArgument.profileHistorySelect.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.host.qaSelectHistory() }
        }
        if LaunchArgument.profileFollowTap.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.host.qaTapFollowItem()
            }
        }
        // Dev convenience: `-open-settings [section]` pushes Settings once this
        // screen is at rest on top, then the named section (a
        // `SettingsSection` raw value: account, security, privacy, legal…).
        // The gear is a bar item, which takes no simulated touch.
        if LaunchArgument.openSettings.isPassed(in: arguments) {
            let sectionName = LaunchArgument.openSettings.value(in: arguments).flatMap { $0.hasPrefix("-") ? nil : $0 }
            QAWait.until("open-settings push", { [weak self] in
                guard let self, let navigation = host.navigationController else { return false }
                return navigation.topViewController === host && navigation.transitionCoordinator == nil
            }) { [weak self] in
                guard let self else { return }
                guard host.hasSettings else {
                    QAWait.fail("open-settings", "this profile has no settings (not the viewer's own)")
                    return
                }
                host.pushSettings()
                guard let sectionName else { return }
                QAWait.until("open-settings section", { [weak self] in
                    guard let navigation = self?.host.navigationController else { return false }
                    return navigation.topViewController is any SettingsSectionOpening
                        && navigation.transitionCoordinator == nil
                }) { [weak self] in
                    let settings = self?.host.navigationController?.topViewController as? any SettingsSectionOpening
                    if settings?.openSection(named: sectionName) == false {
                        QAWait.fail("open-settings", "unknown section \(sectionName)")
                    }
                }
            }
        }
        // Dev convenience: `-profile-relationships [following]` opens the
        // followers / following screen once the profile has loaded — it lives
        // behind a tap on the counter row, which the simulator can't deliver.
        // Combine with `-profile-relationships-tab` / `-...-action` (read by
        // the destination) to drive the tab switch and a row's button.
        // Once per screen, not once per appearance: `viewDidAppear` fires again
        // when the relationships screen pops back, and re-pushing there made
        // the QA run loop between the two forever.
        // `-profile-map-pin-demo`: taps the map-pin bubble once the button has
        // actually appeared, which needs BOTH the relationship read and the
        // pin read to land — the simulator delivers no taps, and a fixed delay
        // here would fire into a hidden button on a slow run. Pair with
        // `-open-profile <id>` for a profile the viewer follows.
        if LaunchArgument.profileMapPinDemo.isPassed(in: arguments), !didTapMapPinForQA {
            didTapMapPinForQA = true
            host.pollForMapPinButton(attempt: 0)
        }
        if LaunchArgument.profileRelationships.isPassed(in: arguments), !didPushRelationshipsForQA {
            didPushRelationshipsForQA = true
            let direction: RelationshipDirection =
                LaunchArgument.profileRelationships.value(in: arguments) == "following" ? .following : .followers
            // Polled, not a single fixed delay: the push needs a loaded
            // profile (it hands the subject's privacy state over), and under
            // `-mock-latency` — the very flag you'd combine this with to
            // screenshot the destination's skeleton — the profile isn't loaded
            // a second and a half in, so a one-shot attempt silently no-ops.
            func attempt(_ remaining: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    // Retry rather than bail on a transient miss: this used to
                    // `return` whenever the profile wasn't topmost at that exact
                    // instant, which killed the whole chain if the tick landed
                    // mid-transition — an intermittently empty recording.
                    let isTop = host.navigationController?.topViewController === host
                    if isTop, host.viewModel.relationshipsSubject != nil {
                        host.pushRelationships(direction)
                    } else if remaining > 0 {
                        attempt(remaining - 1)
                    }
                }
            }
            attempt(30)
        }
        // `-profile-tab <posts|saved|liked>` selects a tab on the viewer's own
        // profile, `<posts|reposts|tagged>` on someone else's (#696).
        if let wanted = LaunchArgument.profileTab.value(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self,
                      let index = host.tabs.firstIndex(where: { $0.title.lowercased() == wanted })
                else { return }
                host.selectTab(at: index)
            }
        }
        // `-profile-view-all [seconds]`: pushes the media gallery a chunk's
        // "View all" opens (#631), once the posts have had time to land.
        if LaunchArgument.profileViewAll.isPassed(in: arguments) {
            let delay = LaunchArgument.profileViewAll.doubleValue(in: arguments) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.host.pushMediaGallery()
            }
        }
        armProbeItem(arguments)
        // `-profile-scroll <points>` scrolls the active page before anything
        // else, so a tile can be driven while it is tucked UNDER the header —
        // at rest nothing is, since the content starts below it, and that is
        // the only state the header-alignment bug appears in.
        if let points = LaunchArgument.profileScroll.doubleValue(in: arguments) {
            // Polls: a fixed delay clamps to the top while the page is still
            // loading and the run then tests a tile at rest, which is the
            // one state the alignment bug cannot appear in.
            //
            // Through `QAWait` now, so running out of attempts PRINTS — it
            // used to fall off the end of the loop silently. What counts as
            // done is `debugSetVerticalOffset`'s to say: the requested offset,
            // or the end of a page whose content has actually loaded (see there
            // for why a loading page's clamp used to pass on the first try).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                QAWait.until("profile-scroll \(points)", timeout: 15, interval: 0.25, { [weak self] in
                    self?.host.galleryPager.debugSetVerticalOffset(CGFloat(points)) ?? false
                }) { [weak self] in
                    guard let self else { return }
                    print("[qa] profile-scroll settled requested=\(points) "
                        + "offset=\(host.galleryPager.verticalOffset)")
                }
            }
        }
        // `-profile-scroll-sweep`: scrolls the page from the top to 240pt and
        // back, frame by frame, 3s each way (after 2.5s) — the header's fade
        // and parallax filmed without touch injection — and says what each
        // frame cost (`HeroScrollFrameProbe`: `HERO-SCROLL profile …` on
        // standard error).
        if LaunchArgument.profileScrollSweep.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                host.debugSweepStep(began: CACurrentMediaTime(), probe: HeroScrollFrameProbe(name: "profile", root: host.headerView))
            }
        }
        // `-profile-stretch-sweep`: once the profile and its picture are in,
        // pulls the page down past its top — the banner stretching — to
        // `HeroStretchSweep.depth`, holds, lets go through the refresh a
        // finger's pull would start (#2235), and settles at rest while it lands
        // (`HERO-SCROLL profile-stretch/<phase> …` on standard error, see
        // `HeroScrollFrameProbe`).
        if LaunchArgument.profileStretchSweep.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                QAWait.until("-profile-stretch-sweep", { [weak self] in
                    guard let self else { return false }
                    return host.viewModel.profile != nil && host.headerView.debugBannerHasPicture
                }) { [weak self] in
                    // The bake lands a beat after the picture.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        host.debugStretchStep(
                            began: CACurrentMediaTime(),
                            probe: HeroScrollFrameProbe(name: "profile-stretch", root: host.headerView), phase: nil
                        )
                    }
                }
            }
        }
        armBarTree(arguments)
        // `-profile-dock`: drives the header all the way to DOCKED, and says so.
        //
        // ⚠️ **A scroll that lands is not a dock.** `-profile-scroll <points>`
        // stops when the offset applies — which happens while a page is still
        // loading and clamps short of the dock line — so runs meant to exercise
        // the docked selector quietly never docked, the bar had nothing to host,
        // and the audit reported "no selector on this bar". That was read as a
        // hosting failure twice, and two fixes were judged against it.
        //
        // This polls on the STATE the test is about, retries the scroll each
        // time, and prints either SETTLED or GAVE UP — so a run can never be
        // silently meaningless.
        if LaunchArgument.profileDock.isPassed(in: arguments) {
            let screen = host
            var attempts = 0
            func attempt() {
                attempts += 1
                // Far past any dock line; the page clamps to whatever it has.
                _ = screen.galleryPager.debugSetVerticalOffset(3_000)
                // ⚠️ THE SUCCESS EXIT THIS LOOP NEVER HAD. It re-forced the
                // offset for the full 40s and then printed GAVE UP on every run,
                // docked or not — so the promised SETTLED line did not exist and
                // the only verdict it could give was a failure. Docked is the
                // header's own definition: the active page has travelled at
                // least `headerTravel`, the line `applyHeaderOffset` stops the
                // header at and the identity fade finishes on. A zero travel
                // means the header has not laid out, which is not a dock.
                let dockLine = screen.headerTravel
                let offset = screen.galleryPager.verticalOffset
                if dockLine > 0, offset >= dockLine - 0.5 {
                    print("[dock] SETTLED docked=true attempts=\(attempts) "
                        + "offset=\(offset) dockLine=\(dockLine) "
                        + "offsets=\(screen.galleryPager.debugVerticalOffsets)")
                    return
                }
                if attempts < 160 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[dock] GAVE UP docked=false attempts=\(attempts) "
                        + "offsets=\(screen.galleryPager.debugVerticalOffsets) "
                        + "hasGallery=\(screen.viewModel.hasGallery)")
                    // The shared GAVE UP line too, so one grep covers every hook.
                    QAWait.fail("profile-dock", "offset=\(offset) dockLine=\(dockLine)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: attempt)
        }
        // `-profile-open-post <index>` taps a gallery tile once the gallery has
        // content. The sim injects no touches, and a tile tap is the only way
        // to reach either the open destination or the background reveal.
        if let index = LaunchArgument.profileOpenPost.intValue(in: arguments) {
            let screen = host
            var attempts = 0
            func attempt() {
                attempts += 1
                // Polls rather than firing on a fixed delay: the gallery's
                // first page has to land, and a fixed delay silently no-ops
                // under `-mock-latency`.
                if screen.galleryPager.debugSelectItem(at: index) { return }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
        }
        // Dev convenience: `-profile-share-demo [activity]` opens the QR share sheet once
        // the profile has loaded — the sheet is behind a tap on the header's
        // QR bubble, which the sim can't deliver.
        if LaunchArgument.profileShareDemo.isPassed(in: arguments) {
            // `activity` chains into the system share sheet and `send` into a
            // DM with the first quick-send target — both go through the real
            // dismiss-then-hand-off path, so the handoff itself is what gets
            // screenshotted, not a shortcut around it.
            let chained = LaunchArgument.profileShareDemo.value(in: arguments)
            // Both steps are gated on state now. `presentShareSheet` returns
            // without a word until `shareCard` exists (a loaded profile), and a
            // stack mid-transition refuses the presentation — so the fixed 2s
            // opened nothing on a slow run, and the chained step then optional-
            // chained every call onto a nil sheet: a whole scripted sequence
            // that exercised nothing and printed nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                QAWait.until("profile-share-demo present", { [weak self] in
                    guard let self, let navigation = host.navigationController else { return false }
                    return host.viewModel.shareCard != nil
                        && navigation.topViewController === host
                        && navigation.transitionCoordinator == nil
                        && host.presentedViewController == nil
                }) { [weak self] in
                    self?.host.presentShareSheet()
                    let chainedActions = [
                        "activity", "send", "search", "search-empty", "search-cancel",
                        "search-send", "search-scroll", "search-lower"
                    ]
                    guard chainedActions.contains(chained ?? "") else { return }
                    // Waits for the sheet to have FINISHED presenting (the 2s
                    // stood in for that) rather than for the clock.
                    QAWait.until("profile-share-demo \(chained ?? "")", { [weak self] in
                        guard let sheet = self?.host.presentedViewController as? ProfileShareViewController
                        else { return false }
                        return !sheet.isBeingPresented && sheet.transitionCoordinator == nil
                    }) { [weak self] in
                        self?.host.qaRunShareChain(chained)
                    }
                }
            }
        }
        // Dev convenience: `-profile-block-demo [account]` runs the block
        // command for real (mock `social_graph.v1/Block`, then the
        // confirmation toast and the pop), skipping only the confirmation
        // sheet — which needs a tap the simulator can't deliver. Pass
        // `account` to exercise the account-wide fan-out.
        if LaunchArgument.profileBlockDemo.isPassed(in: arguments) {
            let scope: ProfileBlockScope =
                LaunchArgument.profileBlockDemo.value(in: arguments) == "account" ? .account : .profile
            // `block` returns without a word unless the profile has loaded AND
            // the relationship read has made it moderatable — so the fixed 2s
            // blocked nothing on a slow run and the run still looked done.
            // Waits for the read to settle either way (moderatable, or known to
            // be the viewer), then says why when it cannot block.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                QAWait.until("profile-block-demo", { [weak self] in
                    guard let self else { return false }
                    return host.viewModel.canModerate
                        || host.viewModel.relationshipsSubject?.isSelf == true
                }) { [weak self] in
                    guard let self else { return }
                    guard host.viewModel.canModerate else {
                        QAWait.fail("profile-block-demo", "this is the viewer's own profile")
                        return
                    }
                    guard !host.viewModel.isBlocked else {
                        QAWait.fail("profile-block-demo", "the profile is already blocked")
                        return
                    }
                    host.viewModel.block(scope)
                }
            }
        }
    }
}
#endif
