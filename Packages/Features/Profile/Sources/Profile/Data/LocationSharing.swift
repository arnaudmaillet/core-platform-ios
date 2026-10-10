import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// How the active profile's location reaches others (#398; backend #717,
/// #718). Enforced at read time on the map (geo-discovery) and on posts
/// (`GetPost`), for everyone but the author. A 13–17 profile starts ghosted
/// at city level.
public struct LocationSharingSettings: Equatable, Sendable {
    /// Ghost mode: the profile's pins and cards leave everyone else's map,
    /// and its posts carry no location for others.
    public var ghost: Bool
    /// City level: others see the city, never the exact point.
    public var cityLevel: Bool

    public init(ghost: Bool = false, cityLevel: Bool = false) {
        self.ghost = ghost
        self.cityLevel = cityLevel
    }

    init(_ proto: Profile_V1_LocationSettings) {
        self.init(ghost: proto.ghost, cityLevel: proto.precision == .city)
    }

    var proto: Profile_V1_LocationSettings {
        var proto = Profile_V1_LocationSettings()
        proto.ghost = ghost
        proto.precision = cityLevel ? .city : .precise
        return proto
    }
}

/// Settings → Privacy → Location Sharing.
public protocol LocationSharingManaging: Sendable {
    func locationSharing() async throws -> LocationSharingSettings
    func setLocationSharing(_ settings: LocationSharingSettings) async throws
}

extension ProfileRepository: LocationSharingManaging {
    public func locationSharing() async throws -> LocationSharingSettings {
        // Owner-only on the view (others never learn a profile ghosts the
        // map). Unset reads as the defaults: not ghosted, precise.
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return view.hasLocationSettings ? LocationSharingSettings(view.locationSettings) : LocationSharingSettings()
    }

    public func setLocationSharing(_ settings: LocationSharingSettings) async throws {
        var request = Profile_V1_SetLocationSettingsRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setLocationSharing").rawValue
        request.settings = settings.proto
        let response = await profileClient.setLocationSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}
