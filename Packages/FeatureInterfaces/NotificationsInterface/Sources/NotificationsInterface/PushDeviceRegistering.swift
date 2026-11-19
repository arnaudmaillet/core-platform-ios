import Foundation

/// Which APNs gateway a token belongs to — APNs routes by it, so a sandbox
/// token sent to production (or the reverse) is simply never delivered.
public enum PushEnvironment: Sendable, Equatable {
    /// Development builds: signed with a development profile.
    case sandbox
    /// TestFlight and App Store builds.
    case production
}

/// Tells the notification service where this install's pushes go (#651):
/// `notification.v1 RegisterDevice` on every launch with permission, and
/// `UnregisterDevice` when the viewer signs out.
public protocol PushDeviceRegistering: Sendable {
    /// Registers (or refreshes — same `deviceID`) this install's APNs token for
    /// the active profile.
    ///
    /// `deviceID` is the install's own id, the one the session sent at login
    /// (`auth.v1.DeviceContext.device_id`): the edge registers a session's own
    /// device only.
    func registerPushDevice(token: String, deviceID: String, environment: PushEnvironment) async throws
    /// Stops pushes to this install for the active profile — before signing
    /// out, while the session can still say who it is.
    func unregisterPushDevice(deviceID: String) async throws
}
