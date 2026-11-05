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
}
