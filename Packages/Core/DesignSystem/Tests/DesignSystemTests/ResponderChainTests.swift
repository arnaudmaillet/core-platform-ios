import Testing
import UIKit
@testable import DesignSystem

/// The shell's services are found up the responder chain, from controllers
/// only (#2116): a failed protocol cast of every private UIKit view on the
/// way cost ~8 ms per lookup in the app.
@MainActor
struct ResponderChainTests {
    private protocol Service: AnyObject {}
    private final class Holder: UIViewController, Service {}
    private final class ServiceView: UIView, Service {}

    /// The app's window: a container at the root (the notifications
    /// drawer's) whose child is the shell holding the services.
    private final class Container: UIViewController {
        let shell = Holder()

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(shell)
            view.addSubview(shell.view)
            shell.didMove(toParent: self)
        }
    }

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

    /// A sheet with a control deep in it: on a screen the sheet holds as a
    /// child, as a post's comments sheet holds its panel.
    private func sheet(_ presented: UIViewController = UIViewController()) -> (UIViewController, UIButton) {
        let screen = UIViewController()
        presented.addChild(screen)
        presented.view.addSubview(screen.view)
        screen.didMove(toParent: presented)
        let control = UIButton()
        screen.view.addSubview(control)
        presented.modalPresentationStyle = .pageSheet
        return (presented, control)
    }

    @Test func aControllerUpTheChainIsFoundThroughItsViews() {
        let holder = Holder()
        let scroll = UIScrollView()
        let button = UIButton()
        scroll.addSubview(button)
        holder.view.addSubview(scroll)
        #expect(button.firstController(as: (any Service).self) === holder)
        #expect(UIButton().firstController(as: (any Service).self) == nil)
    }

    /// A view adopting the protocol is not a provider: controllers only.
    @Test func aViewIsNeverAsked() {
        let view = ServiceView()
        let button = UIButton()
        view.addSubview(button)
        #expect(button.firstController(as: (any Service).self) == nil)
    }

    /// A control in a sheet finds the shell (#2565): the sheet is presented
    /// by the window's root, a container, and the shell is that container's
    /// child, never up the sheet's own chain.
    @Test func aControlInASheetFindsTheShellBesideItsPresenter() {
        let root = Container()
        hosting(root) {
            let (presented, control) = sheet()
            root.present(presented, animated: false)
            #expect(presented.presentingViewController === root)
            #expect(control.firstController(as: (any Service).self) === root.shell)
        }
    }

    /// With the shell itself at the window's root, the sheet's presenter is
    /// the shell, found as the presenter.
    @Test func aControlInASheetPresentedByTheShellFindsIt() {
        let shell = Holder()
        hosting(shell) {
            let (presented, control) = sheet()
            shell.present(presented, animated: false)
            #expect(control.firstController(as: (any Service).self) === shell)
        }
    }

    /// The sheet's own controllers come first: a provider inside the sheet
    /// answers before the shell under it.
    @Test func aProviderInsideTheSheetAnswersFirst() {
        let root = Container()
        hosting(root) {
            let holder = Holder()
            let (presented, control) = sheet(holder)
            root.present(presented, animated: false)
            #expect(control.firstController(as: (any Service).self) === holder)
        }
    }

    /// Off the presentation, a sibling is never asked: the children of a
    /// controller the chain merely passes are left alone.
    @Test func aSiblingOffAPresentationIsNotAsked() {
        let root = Container()
        let screen = UIViewController()
        root.addChild(screen)
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        let control = UIButton()
        screen.view.addSubview(control)
        #expect(control.firstController(as: (any Service).self) == nil)
    }
}
