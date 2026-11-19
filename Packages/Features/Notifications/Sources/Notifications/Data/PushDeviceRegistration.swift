import CoreContracts
import CoreNetworking
import Foundation
import NotificationsInterface

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
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func unregisterPushDevice(deviceID: String) async throws {
        var request = Notification_V1_UnregisterDeviceRequest()
        request.profileID = try await activeProfileIDForWrite("unregisterDevice").rawValue
        request.deviceID = deviceID
        let response = await notificationClient.unregisterDevice(request: request, headers: [:])
        if let error = response.error {
            throw NotificationsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}
