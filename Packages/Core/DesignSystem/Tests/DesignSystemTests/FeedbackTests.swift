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
    private func recordingHaptics(_ body: () throws -> Void) rethrows -> [UINotificationFeedbackGenerator.FeedbackType] {
        let previous = Feedback.playHaptic
        var played: [UINotificationFeedbackGenerator.FeedbackType] = []
        Feedback.playHaptic = { played.append($0) }
        defer { Feedback.playHaptic = previous }
        try body()
        return played
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

    /// A second toast replaces the first rather than stacking.
    @Test func aSecondToastReplacesTheFirst() {
        let (root, screen) = shell()
        hosting(root) {
            _ = recordingHaptics {
                Feedback.success("Copied", from: screen)
                Feedback.failure("Couldn't copy", from: screen)
            }
            #expect(screen.view.subviews.filter { $0 is ToastView }.count == 1)
        }
    }

    // MARK: - The guard

    /// ⚠️ The presenter only works if NOTHING bypasses it. Scans the app's and
    /// the packages' sources for `ToastView.present(` anywhere but here.
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
                      url.lastPathComponent != "Feedback.swift" else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains(pattern) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "ToastView.present called outside Feedback in: \(offenders)")
    }
}
