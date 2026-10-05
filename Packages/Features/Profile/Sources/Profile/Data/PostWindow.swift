import CoreContracts
import CoreModels
import Foundation

/// How far back other people can see the active profile's posts (#411,
/// backend #729). The server enforces it: visitors' listings stop at the
/// window and an older post reads as not found. Nothing is deleted, and the
/// owner always sees everything.
public enum PostWindow: Equatable, Sendable, CaseIterable {
    case all, sixMonths, oneMonth, threeDays

    public var title: String {
        switch self {
        case .all: "All Posts"
        case .sixMonths: "Last 6 Months"
        case .oneMonth: "Last Month"
        case .threeDays: "Last 3 Days"
        }
    }

    init(_ proto: Profile_V1_PostWindow) {
        switch proto {
        case .sixMonths: self = .sixMonths
        case .oneMonth: self = .oneMonth
        case .threeDays: self = .threeDays
        case .all, .unspecified, .UNRECOGNIZED: self = .all
        }
    }

    var proto: Profile_V1_PostWindow {
        switch self {
        case .all: .all
        case .sixMonths: .sixMonths
        case .oneMonth: .oneMonth
        case .threeDays: .threeDays
        }
    }
}

/// Settings → Privacy → Posts Visible to Others.
public protocol PostWindowManaging: Sendable {
    func postWindow() async throws -> PostWindow
    func setPostWindow(_ window: PostWindow) async throws
}

extension ProfileRepository: PostWindowManaging {
    public func postWindow() async throws -> PostWindow {
        // Owner-only on the view: the active profile reading itself.
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return PostWindow(view.tabSettings.postWindow)
    }

    public func setPostWindow(_ window: PostWindow) async throws {
        var request = Profile_V1_SetTabSettingsRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setPostWindow").rawValue
        // Partial: the tab flags (left unset) keep their values.
        request.postWindow = window.proto
        let response = await profileClient.setTabSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
