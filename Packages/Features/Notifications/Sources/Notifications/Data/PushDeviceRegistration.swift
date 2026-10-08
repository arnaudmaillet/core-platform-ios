import CoreContracts
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

extension NotificationsRepository: PushDeviceRegistering {
    public func registerPushDevice(token: String, deviceID: String, environment: PushEnvironment) async throws {
        var request = Notification_V1_RegisterDeviceRequest()
        request.profileID = try await activeProfileIDForWrite("registerDevice").rawValue
        request.deviceID = deviceID
        request.token = token
        request.platform = .ios
        request.environment = switch environment {
        case .sandbox: .sandbox
        case .production: .production
        }
        // Quiet hours are read in this zone.
        request.timezone = TimeZone.current.identifier
        let response = await notificationClient.registerDevice(request: request, headers: [:])
        if let error = response.error {
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func unregisterPushDevice(deviceID: String) async throws {
        var request = Notification_V1_UnregisterDeviceRequest()
        request.profileID = try await activeProfileIDForWrite("unregisterDevice").rawValue
        request.deviceID = deviceID
        let response = await notificationClient.unregisterDevice(request: request, headers: [:])
        if let error = response.error {
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
