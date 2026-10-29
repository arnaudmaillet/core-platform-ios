import Foundation
import Testing
import UIKit
@testable import DesignSystem

/// The one feedback presenter (#804): the right host, the failure style, the
/// paired haptic, and nothing else calling the renderer.
@MainActor
@Suite(.serialized)
struct FeedbackTests {
    /// `root` as a visible window's root, taken down within the test (a
    /// window released visible in a dirty turn crashes the host).
    private func hosting(_ root: UIViewController, _ body: () throws -> Void) rethrows {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body()
    }

    /// Records the haptics played instead of playing them; synchronous, and
    /// restored before the test returns (never held across an `await`).
    private func recordingHaptics(_ body: () throws -> Void) rethrows -> [Haptic] {
        try HapticRecorder.recording(body)
    }

    /// A screen in a shell: the source a call site would pass.
    private func shell() -> (root: UIViewController, screen: UIViewController) {
        let root = UIViewController()
        let screen = UIViewController()
        root.addChild(screen)
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        return (root, screen)
    }

    // MARK: - The host

    /// ⚠️ The bug this type exists for: a toast fired from a screen a sheet
    /// covers is drawn on the sheet, not behind it.
    @Test func aToastFiredUnderASheetShowsAboveIt() {
        let (root, screen) = shell()
        hosting(root) {
            let sheet = UIViewController()
            root.present(sheet, animated: false)
            _ = recordingHaptics {
                let toast = Feedback.success("Copied", from: screen)
                #expect(toast.superview === sheet.view, "the toast went under the sheet")
            }
        }
    }

    /// Nothing covers the screen: the toast stays on the screen itself, whose
    /// safe area clears the tab bar (the shell's does not).
    @Test func anUncoveredScreenHostsItsOwnToast() {
        let (root, screen) = shell()
        hosting(root) {
            #expect(Feedback.host(for: screen) === screen)
            _ = recordingHaptics {
                let toast = Feedback.info("Hidden from this feed", from: screen)
                #expect(toast.superview === screen.view)
            }
        }
    }

    /// A screen inside the sheet on top is its own host.
    @Test func aScreenInsideTheTopSheetHostsItsOwnToast() {
        let (root, _) = shell()
        hosting(root) {
            let inner = UIViewController()
            let sheet = UINavigationController(rootViewController: inner)
            root.present(sheet, animated: false)
            #expect(Feedback.host(for: inner) === inner)
        }
    }

    /// An alert is not somewhere to draw: the toast goes to what it covers.
    @Test func anAlertIsNeverTheHost() {
        let (root, screen) = shell()
        hosting(root) {
            root.present(UIAlertController(title: "?", message: nil, preferredStyle: .alert), animated: false)
            #expect(Feedback.host(for: screen) === screen)
        }
    }

    /// A toast sourced from the tab shell — a sheet's presenter once the
    /// sheet has gone, "Posted" (#803) — goes to the selected tab, whose safe
    /// area clears the tab bar; the shell's view does not.
    @Test func aTabShellHandsItsToastToTheSelectedTab() {
        let tabs = UITabBarController()
        let first = UINavigationController(rootViewController: UIViewController())
        tabs.viewControllers = [first, UIViewController()]
        tabs.selectedIndex = 0
        hosting(tabs) {
            #expect(Feedback.host(for: tabs) === first)
            // The overlay's hosting rule; with a bar the toast goes there
            // (#1058, `NavigationBarToastsTests`).
            let previousBar = NavigationBarToasts.isEnabled
            NavigationBarToasts.isEnabled = false
            defer { NavigationBarToasts.isEnabled = previousBar }
            _ = recordingHaptics {
                let toast = Feedback.success("Posted", from: tabs)
                #expect(toast.superview === first.view)
            }
        }
    }

    /// ⚠️ A share sheet is the system's: a toast fired while one is up goes
    /// to the screen under it, never inside it.
    ///
    /// The share sheet is reported presented by the root rather than really
    /// presented: in the package test host its presentation never lands
    /// (`presentedViewController` stays nil, measured), and the walk only
    /// reads that property.
    @Test func aShareSheetIsNeverTheHost() {
        final class PresentingRoot: UIViewController {
            var reportedPresented: UIViewController?
            override var presentedViewController: UIViewController? { reportedPresented }
        }
        let root = PresentingRoot()
        let screen = UIViewController()
        root.addChild(screen)
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        hosting(root) {
            let share = UIActivityViewController(activityItems: ["https://example.com"], applicationActivities: nil)
            root.reportedPresented = share
            #expect(root.presentedViewController === share, "guard: the share sheet is presented")
            #expect(Feedback.host(for: screen) === screen)
            _ = recordingHaptics {
                let toast = Feedback.success("Link copied", from: screen)
                #expect(toast.superview === screen.view, "the toast went inside the share sheet")
            }
        }
    }

    /// What counts as the system's: share sheets, alerts, popovers, and
    /// controllers defined in system frameworks — never the generic
    /// containers the app's own screens are presented in.
    @Test func systemSurfacesAreToldFromTheAppsOwnScreens() {
        #expect(Feedback.isSystemSurface(UIActivityViewController(activityItems: [], applicationActivities: nil)))
        #expect(Feedback.isSystemSurface(UIAlertController(title: nil, message: nil, preferredStyle: .alert)))
        let popover = UIViewController()
        popover.modalPresentationStyle = .popover
        #expect(Feedback.isSystemSurface(popover))
        #expect(!Feedback.isSystemSurface(UIViewController()))
        #expect(!Feedback.isSystemSurface(UINavigationController(rootViewController: UIViewController())))
        final class AppScreen: UIViewController {}
        #expect(!Feedback.isSystemSurface(AppScreen()))
    }

    /// A screen out of any window keeps its own view: nothing better to guess.
    @Test func aScreenOutOfAWindowHostsItsOwnToast() {
        let screen = UIViewController()
        #expect(Feedback.host(for: screen) === screen)
    }

    // MARK: - Style and haptic

    /// A failure reads as one: the failure style, and the error haptic.
    @Test func aFailureUsesTheFailureStyleAndAnErrorHaptic() {
        let (root, screen) = shell()
        hosting(root) {
            var toast: ToastView?
            let played = recordingHaptics {
                toast = Feedback.failure("Couldn't follow @ava", from: screen)
            }
            #expect(toast?.style == .failure)
            #expect(played == [.error])
        }
    }

    /// A success confirms in the confirmation style, with the success haptic.
    @Test func aSuccessUsesTheConfirmationStyleAndASuccessHaptic() {
        let (root, screen) = shell()
        hosting(root) {
            var toast: ToastView?
            let played = recordingHaptics {
                toast = Feedback.success("Copied", from: screen)
            }
            #expect(toast?.style == .confirmation)
            #expect(played == [.success])
        }
    }

    /// A neutral notice has nothing for the hand to learn: no haptic.
    @Test func aNoticePlaysNoHaptic() {
        let (root, screen) = shell()
        hosting(root) {
            let played = recordingHaptics {
                Feedback.info("Hidden from this feed", from: screen)
            }
            #expect(played.isEmpty)
        }
    }

    /// An action that played its own haptic asks its toast for none; with no
    /// such ask, the toast plays its outcome role once (#1882).
    @Test func playsHapticFalsePlaysNoneAndTheDefaultPlaysOnce() {
        do {
            let (root, screen) = shell()
            hosting(root) {
                let silent = recordingHaptics {
                    Feedback.undoable("Staked", from: screen, playsHaptic: false, commit: {}, undo: {})
                }
                #expect(silent.isEmpty, "a toast doubled its action's own haptic: \(silent)")
            }
        }
        let (root, screen) = shell()
        hosting(root) {
            let played = recordingHaptics { Feedback.undoable("Staked", from: screen, commit: {}, undo: {}) }
            #expect(played == [.success])
        }
    }

    /// A toggle that shows on its control (a bookmark) plays `toggleOn`
    /// turning on, nothing turning off, and draws nothing (#803, #1881).
    @Test func aToggledStatePlaysOnlyTurningOnAndNoToast() {
        let (root, screen) = shell()
        hosting(root) {
            let on = recordingHaptics { Feedback.toggled(on: true) }
            #expect(on == [.toggleOn], "turning on played \(on)")
            let off = recordingHaptics { Feedback.toggled(on: false) }
            #expect(off.isEmpty, "turning off played \(off)")
            #expect(!screen.view.subviews.contains { $0 is ToastView })
        }
    }

    /// VoiceOver hears the toast as a QUEUED announcement, so a context
    /// menu's own dismissal does not drop it.
    @Test func theAnnouncementIsQueued() {
        let spoken = ToastView.announcement("Copied")
        #expect(spoken.string == "Copied")
        let queued = spoken.attribute(.accessibilitySpeechQueueAnnouncement, at: 0, effectiveRange: nil) as? Bool
        #expect(queued == true)
    }

    /// A failure takes the place of the confirmation before it (#954: a
    /// failure preempts info) — a fast double-tap still cannot build a tower.
    @Test func aFailurePreemptsTheConfirmationBeforeIt() {
        let (root, screen) = shell()
        hosting(root) {
            _ = recordingHaptics {
                Feedback.success("Copied", from: screen)
                Feedback.failure("Couldn't copy", from: screen)
            }
            #expect(ToastView.stack(at: .bottom, in: screen.view).map(\.message) == ["Couldn't copy"])
        }
    }

    /// The same toast twice is one toast (#954): its time restarts.
    @Test func theSameToastTwiceIsOne() {
        let (root, screen) = shell()
        hosting(root) {
            _ = recordingHaptics {
                Feedback.success("Copied", from: screen)
                Feedback.success("Copied", from: screen)
            }
            #expect(ToastView.stack(at: .bottom, in: screen.view).count == 1)
        }
    }

    // MARK: - The guard

    /// ⚠️ The presenter only works if NOTHING bypasses it. Scans the app's and
    /// the packages' sources for `ToastView.present(` anywhere but `Feedback`
    /// and the scene overlay it draws through (#954), which only `Feedback`
    /// reaches.
    @Test func onlyFeedbackPresentsToasts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        let pattern = try Regex(#"\bToastView\s*\.\s*present\s*\("#)
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/"),
                      !["Feedback.swift", "ToastOverlay.swift"].contains(url.lastPathComponent) else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "ToastView.present called outside Feedback in: \(offenders)")
    }
}
