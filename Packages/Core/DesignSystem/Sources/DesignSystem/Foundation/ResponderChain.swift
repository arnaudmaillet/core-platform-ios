import UIKit

public extension UIResponder {
    /// The first VIEW CONTROLLER up the responder chain that is a `T` — how
    /// a control deep in a screen finds the shell's gate, Shop opener, text
    /// entity opener or completions.
    ///
    /// ⚠️ CONTROLLERS ONLY, AND THAT IS THE POINT (#2116). Asking every
    /// responder `as? any SomeProtocol` asked a dozen private UIKit views
    /// too, and a failed cast of an Objective-C class to a Swift protocol
    /// scans the binary's conformance records: ~8 ms per lookup in the app
    /// (0.3 ms in a test host's smaller binary), paid in the tap's turn of
    /// every route. A class check first leaves the protocol cast to the two
    /// or three controllers on the way. Every adopter is a controller.
    ///
    /// ⚠️ FROM A SHEET, THE PRESENTER'S CHILDREN ARE ASKED TOO (#2565). UIKit
    /// does not present from the controller `present` was called on: it
    /// forwards the presentation to the controller that covers the screen,
    /// the window's root, which is the notifications drawer's container. Its
    /// CHILD is the shell's tab bar controller that adopts these protocols.
    /// A presented controller's next responder is that container, then the
    /// window: the shell was never on the way, so a sheet's stake menu had
    /// no Shop, its comments bar no gate, its tags and mentions no opener
    /// (checked in the app with lldb, 2026-11-25). So the climb leaves a
    /// presented controller for its presenter, as UIKit does, and asks that
    /// presenter's direct children before going on up. One level only: the
    /// shell is the root's child, and a deeper walk would cast every
    /// controller of every tab.
    func firstController<T>(as type: T.Type) -> T? {
        var responder: UIResponder? = self
        var presenter: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController {
                if let match = controller as? T { return match }
                if controller === presenter,
                   let match = controller.children.lazy.compactMap({ $0 as? T }).first {
                    return match
                }
                // The presented controller itself, not a child inside it
                // (every controller under a presentation answers its
                // `presentingViewController`).
                if controller.parent == nil, let presenting = controller.presentingViewController {
                    presenter = presenting
                    responder = presenting
                    continue
                }
            }
            responder = current.next
        }
        return nil
    }
}
