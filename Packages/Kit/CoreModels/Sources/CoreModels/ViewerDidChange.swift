import Foundation

public extension Notification.Name {
    /// Posted on the main queue after every viewer transition, for main-actor
    /// caches no repository owns (`ProfileCache`, `UnavailablePosts`). No
    /// object, no user info. Declared here, below every layer, so a Core
    /// surface can forget what it learnt for the previous viewer (#2379); the
    /// session (`ViewerSession`, AuthInterface) posts it.
    static let viewerDidChange = Notification.Name("ViewerDidChange")
}
