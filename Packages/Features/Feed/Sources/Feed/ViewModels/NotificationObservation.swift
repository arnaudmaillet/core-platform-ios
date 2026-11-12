import Foundation

/// Holds a block-based `NotificationCenter` token and removes it on release.
final class NotificationObservation: @unchecked Sendable {
    var token: NSObjectProtocol?

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
