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
    func firstController<T>(as type: T.Type) -> T? {
        sequence(first: self, next: \.next).lazy
            .compactMap { ($0 as? UIViewController) as? T }
            .first
    }
}
