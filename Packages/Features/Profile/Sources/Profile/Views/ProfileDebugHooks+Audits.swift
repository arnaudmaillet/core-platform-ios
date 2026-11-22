#if DEBUG
import CoreModels
import DesignSystem
import LaunchArguments
import ProfileData
import SettingsInterface
import UIKit

// The audits and probes of `ProfileDebugHooks` (#2522): what the header,
// the menu and the bar resolved to, printed — called from `armOnce` in
// their places.
extension ProfileDebugHooks {
    func armLayoutInkAndMenuAudits() {
        // Dev convenience: `-profile-layout-audit` prints the resolved header
        // view tree (frames included) once content has settled — numeric
        // spacing audits without pixel-measuring screenshots.
        if LaunchArgument.profileLayoutAudit.isPassed() {
            // The 1.5s is kept as a floor (the settle beat the audit was
            // calibrated on), but the print now WAITS FOR THE PROFILE: on a slow
            // run the fixed delay dumped the redacted skeleton header and the
            // spacing audit measured bones, reading like a real layout.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-layout-audit", { [weak self] in
                    self?.host.viewModel.profile != nil
                }) { [weak self] in
                    guard let self else { return }
                    // The content render lands in THIS turn's layout pass at
                    // the earliest; flush it so the frames are the loaded ones.
                    host.view.layoutIfNeeded()
                    let description = host.headerView
                        .perform(Selector(("recursiveDescription")))?
                        .takeUnretainedValue()
                    print("PROFILE-LAYOUT-AUDIT\n\(description.map(String.init(describing:)) ?? "unavailable")")
                }
            }
        }
        // Dev convenience: `-profile-ink-audit` prints the WCAG contrast of
        // the name and the handle against the pixels actually rendered behind
        // them (see `ProfileHeaderView.debugIdentityContrast`) — once the
        // profile AND its banner picture are in, since the picture decides
        // both the shape and what the type stands on.
        if LaunchArgument.profileInkAudit.isPassed() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-ink-audit", { [weak self] in
                    guard let self, host.viewModel.profile != nil else { return false }
                    return host.headerView.bannerFormat == .none || host.headerView.debugBannerHasPicture
                }) { [weak self] in
                    guard let self else { return }
                    // Past the banner's 0.25s dissolve.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self else { return }
                        host.view.layoutIfNeeded()
                        let style = host.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
                        guard let contrast = host.headerView.debugIdentityContrast() else {
                            print("PROFILE-INK-AUDIT unavailable")
                            return
                        }
                        print(
                            "PROFILE-INK-AUDIT format=\(host.headerView.bannerFormat) style=\(style) "
                                + "tones=\(host.headerView.debugInkTones) "
                                + "name=[\(contrast.name)] handle=[\(contrast.handle)] "
                                + String(format: "blur-bake=%.1fms %dKB", host.headerView.debugBlurBakeMilliseconds,
                                         host.headerView.debugBlurBakeBytes / 1024)
                                + " " + (host.headerView.debugBodyContrast() ?? [])
                                    .map { "\($0.0)=[\($0.1)]" }.joined(separator: " ")
                        )
                    }
                }
            }
        }
        // Dev convenience: `-profile-menu-audit` prints the "..." menu the
        // current state resolves to, and fires the copy action so the toast is
        // screenshottable. The menu is the one thing on this screen no launch
        // argument can otherwise reach — it opens on a tap, and the sim has no
        // touch injection.
        if LaunchArgument.profileMenuAudit.isPassed() {
            // Waits for the RELATIONSHIP READ, not just the clock: the menu's
            // moderation group and its Block/Unblock title are both decided by
            // it, and with `-profile-relationship-delay` (3s) the fixed 1.5s
            // printed `canModerate=false isBlocked=false` — the pre-read menu,
            // reported as the answer. The read is in when this is someone
            // else's profile we can moderate, or the subject is known to be the
            // viewer (own profile, or a routed one the read said is self).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until("profile-menu-audit", { [weak self] in
                    guard let self else { return false }
                    return host.viewModel.canModerate
                        || host.viewModel.relationshipsSubject?.isSelf == true
                }) { [weak self] in
                    guard let self else { return }
                    let titles = host.moreMenuElements().flatMap { element -> [String] in
                        guard let group = element as? UIMenu else { return [element.title] }
                        return ["—"] + group.children.map(\.title)
                    }
                    print("PROFILE-MENU-AUDIT canModerate=\(host.viewModel.canModerate) "
                        + "isBlocked=\(host.viewModel.isBlocked) items=\(titles)")
                    host.copyProfileLink()
                }
            }
        }
    }

    func armProbeItem(_ arguments: [String]) {
        // `-header-dock-demo`: docks and undocks the selector on a timer, ANIMATED,
        // so the hand-over can be recorded. A bar item's system capsule is not
        // ours to fade, so whether the pill pops or crossfades is a question only
        // frames can answer.
        // `-profile-probe-item`: a PLAIN 80x36 view as a leading bar item. If even
        // this is not hosted, the fault is this surface's leading group and not
        // anything about the selector's host.
        if LaunchArgument.profileProbeItem.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                let screen = host
                let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 36))
                swatch.backgroundColor = .systemRed
                swatch.translatesAutoresizingMaskIntoConstraints = true
                let probeItem = BarItems.container(id: "profile.debug.dock-probe", view: swatch)
                var leading = host.navigationItem.leftBarButtonItems ?? []
                leading.append(probeItem)
                host.navigationItem.leftBarButtonItems = leading
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("[dock] PROBE plainItemHosted=\(swatch.window != nil) "
                        + "frame=\(swatch.frame) leftCount=\(screen.navigationItem.leftBarButtonItems?.count ?? -1)")
                }
            }
        }
    }

    func armBarTree(_ arguments: [String]) {
        // `-profile-bar-tree`: the navigation bar's real subview tree. The own
        // profile reports a bar that is in a window, not hidden, at alpha 1, with
        // items in its arrays — and renders none of them. Only the tree can say
        // whether UIKit built wrappers for them at all.
        if LaunchArgument.profileBarTree.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                guard let bar = self?.host.navigationController?.navigationBar else { return }
                func walk(_ view: UIView, depth: Int) {
                    let pad = String(repeating: "  ", count: depth)
                    print(String(format: "[bar-tree] %@%@ frame=%.0f,%.0f %.0fx%.0f alpha=%.2f hidden=%@ subs=%d",
                                 pad, String(describing: type(of: view)),
                                 view.frame.minX, view.frame.minY, view.frame.width, view.frame.height,
                                 view.alpha, view.isHidden ? "Y" : "N", view.subviews.count))
                    guard depth < 6 else { return }
                    for sub in view.subviews { walk(sub, depth: depth + 1) }
                }
                walk(bar, depth: 0)
            }
        }
    }
}
#endif
