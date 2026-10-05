import CoreContracts
import CoreModels
import Foundation

/// The presence and discovery switches the server enforces today (#406,
/// #412; backend #726, #727). All on by default; a 13–17 account starts with
/// some off (backend #726).
public struct ActivityDiscoverySettings: Equatable, Sendable {
    /// Others in a conversation see when this profile is active.
    public var activityStatus: Bool
    /// Others in a conversation see when this profile has read their messages.
    public var readReceipts: Bool
    /// The profile shows up when someone searches its handle or name.
    public var findableInSearch: Bool

    public init(activityStatus: Bool = true, readReceipts: Bool = true, findableInSearch: Bool = true) {
        self.activityStatus = activityStatus
        self.readReceipts = readReceipts
        self.findableInSearch = findableInSearch
    }

    init(_ proto: Profile_V1_DiscoverySettings) {
        self.init(activityStatus: proto.activityStatus, readReceipts: proto.readReceipts, findableInSearch: proto.byHandleSearch)
    }

    public enum Switch: Equatable, Sendable, CaseIterable {
        case activityStatus, readReceipts, findableInSearch
    }

    public subscript(_ key: Switch) -> Bool {
        get {
            switch key {
            case .activityStatus: activityStatus
            case .readReceipts: readReceipts
            case .findableInSearch: findableInSearch
            }
        }
        set {
            switch key {
            case .activityStatus: activityStatus = newValue
            case .readReceipts: readReceipts = newValue
            case .findableInSearch: findableInSearch = newValue
            }
        }
    }
}

/// Settings → Privacy → Activity and Discovery.
public protocol ActivityDiscoveryManaging: Sendable {
    func activityDiscoverySettings() async throws -> ActivityDiscoverySettings
    /// Changes one switch; the others keep their values (a partial update).
    func setActivityDiscovery(_ key: ActivityDiscoverySettings.Switch, to isOn: Bool) async throws
}

extension ProfileRepository: ActivityDiscoveryManaging {
    public func activityDiscoverySettings() async throws -> ActivityDiscoverySettings {
        // Owner-only on the view. An unset record reads as the defaults.
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return view.hasDiscoverySettings ? ActivityDiscoverySettings(view.discoverySettings) : ActivityDiscoverySettings()
    }

    public func setActivityDiscovery(_ key: ActivityDiscoverySettings.Switch, to isOn: Bool) async throws {
        var request = Profile_V1_SetDiscoverySettingsRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setActivityDiscovery").rawValue
        switch key {
        case .activityStatus: request.activityStatus = isOn
        case .readReceipts: request.readReceipts = isOn
        case .findableInSearch: request.byHandleSearch = isOn
        }
        let response = await profileClient.setDiscoverySettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
