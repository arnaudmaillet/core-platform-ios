import CoreContracts
import CoreModels
import Foundation

/// The presence and discovery switches the server enforces (#406, #412;
/// backend #726, #727, #661). All on by default; a 13–17 account starts with
/// some off (backend #726).
public struct ActivityDiscoverySettings: Equatable, Sendable {
    /// Others in a conversation see when this profile is active.
    public var activityStatus: Bool
    /// Others in a conversation see when this profile has read their messages.
    public var readReceipts: Bool
    /// The profile shows up when someone searches its handle or name.
    public var findableInSearch: Bool
    /// Someone with the account's phone number in their contacts finds it.
    public var findableByPhone: Bool
    /// Someone with the account's email address in their contacts finds it.
    public var findableByEmail: Bool
    /// The profile's QR code and shared links open it (`ResolveShareToken`).
    public var reachableByLink: Bool
    /// The profile can be suggested to people who might know it.
    public var inSuggestions: Bool

    public init(
        activityStatus: Bool = true, readReceipts: Bool = true, findableInSearch: Bool = true,
        findableByPhone: Bool = true, findableByEmail: Bool = true, reachableByLink: Bool = true,
        inSuggestions: Bool = true
    ) {
        self.activityStatus = activityStatus
        self.readReceipts = readReceipts
        self.findableInSearch = findableInSearch
        self.findableByPhone = findableByPhone
        self.findableByEmail = findableByEmail
        self.reachableByLink = reachableByLink
        self.inSuggestions = inSuggestions
    }

    init(_ proto: Profile_V1_DiscoverySettings) {
        self.init(
            activityStatus: proto.activityStatus, readReceipts: proto.readReceipts,
            findableInSearch: proto.byHandleSearch, findableByPhone: proto.byPhone,
            findableByEmail: proto.byEmail, reachableByLink: proto.byQr, inSuggestions: proto.inSuggestions
        )
    }

    public enum Switch: Equatable, Sendable, CaseIterable {
        case activityStatus, readReceipts, findableInSearch
        case findableByPhone, findableByEmail, reachableByLink, inSuggestions
    }

    public subscript(_ key: Switch) -> Bool {
        get {
            switch key {
            case .activityStatus: activityStatus
            case .readReceipts: readReceipts
            case .findableInSearch: findableInSearch
            case .findableByPhone: findableByPhone
            case .findableByEmail: findableByEmail
            case .reachableByLink: reachableByLink
            case .inSuggestions: inSuggestions
            }
        }
        set {
            switch key {
            case .activityStatus: activityStatus = newValue
            case .readReceipts: readReceipts = newValue
            case .findableInSearch: findableInSearch = newValue
            case .findableByPhone: findableByPhone = newValue
            case .findableByEmail: findableByEmail = newValue
            case .reachableByLink: reachableByLink = newValue
            case .inSuggestions: inSuggestions = newValue
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
        case .findableByPhone: request.byPhone = isOn
        case .findableByEmail: request.byEmail = isOn
        case .reachableByLink: request.byQr = isOn
        case .inSuggestions: request.inSuggestions = isOn
        }
        let response = await profileClient.setDiscoverySettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}

/// The active profile's QR code and share link (#412, backend #661): a random
/// token, independent of the handle, that the owner can replace — the old one
/// stops opening the profile at once.
public protocol ShareLinkManaging: Sendable {
    /// The current token (issued on first ask).
    func shareToken() async throws -> String
    /// A new token; the old QR code and links stop working.
    func rotateShareToken() async throws -> String
}

extension ProfileRepository: ShareLinkManaging {
    public func shareToken() async throws -> String {
        var request = Profile_V1_GetShareTokenRequest()
        request.profileID = try await resolveViewerProfileID().rawValue
        let response = await profileClient.getShareToken(request: request, headers: [:])
        switch response.result {
        case .success(let body): return body.token
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func rotateShareToken() async throws -> String {
        var request = Profile_V1_RotateShareTokenRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "rotateShareToken").rawValue
        let response = await profileClient.rotateShareToken(request: request, headers: [:])
        switch response.result {
        case .success(let body): return body.token
        case .failure(let error): throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
