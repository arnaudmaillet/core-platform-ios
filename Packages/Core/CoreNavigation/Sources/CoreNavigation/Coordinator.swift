import UIKit

/// A Coordinator owns a unit of navigation flow: it builds view controllers,
/// decides what is pushed/presented where, and holds its child flows alive.
/// View controllers never navigate directly; they report intents upward and
/// coordinators translate them into navigation.
@MainActor
public protocol Coordinator: AnyObject {
    var childCoordinators: [Coordinator] { get set }

    /// Builds the flow's initial UI and attaches it to its container
    /// (window, navigation controller, or tab slot).
    func start()
}

extension Coordinator {
    public func addChild(_ coordinator: Coordinator) {
        childCoordinators.append(coordinator)
    }

    public func removeChild(_ coordinator: Coordinator) {
        childCoordinators.removeAll { $0 === coordinator }
    }
}
