import Testing
import UIKit
@testable import DesignSystem

/// The window hears a presentation come and go (#1970): UIKit installs a
/// presentation's container in the window, and takes it out, and the window
/// says so — what CoreNavigation's `ScreenCovers` reads the chain again on.
@MainActor
struct AppWindowSubviewsSignalTests {
    @Test func theWindowSaysASubviewCameAndWent() {
        let window = AppWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(
            forName: AppWindow.subviewsDidChange, object: window, queue: nil
        ) { _ in MainActor.assumeIsolated { heard.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        let container = UIView()
        window.addSubview(container)
        #expect(heard.count == 1, "a container joining the window was not said")
        container.removeFromSuperview()
        #expect(heard.count == 2, "a container leaving the window was not said")
    }

    /// The declared default: a sheet covers at its large detent only.
    @Test func aDeclaredSheetCoversAtLargeByDefault() throws {
        let screen = DeclaredSheet()
        screen.modalPresentationStyle = .pageSheet
        let sheet = try #require(screen.sheetPresentationController)
        sheet.detents = [.medium(), .large()]
        sheet.selectedDetentIdentifier = .medium
        #expect(!screen.coversScreen)
        sheet.selectedDetentIdentifier = .large
        #expect(screen.coversScreen)
    }
}

@MainActor
private final class Heard {
    var count = 0
}

@MainActor
private final class DeclaredSheet: UIViewController, ScreenCovering {}
