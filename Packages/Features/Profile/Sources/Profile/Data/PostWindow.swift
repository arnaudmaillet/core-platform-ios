import CoreContracts
import CoreModels
import CoreNetworking
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
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}

/// Which of the active profile's tabs other people see (#411, backend
/// #829). The server enforces it: a hidden tab is empty for anyone but the
/// owner, and visitors read the flags as `ProfileView.visible_tabs`. The
/// owner always sees every tab.
///
/// Places has a flag on the wire too; no iOS profile draws a Places tab, so
/// no switch is offered for it.
public struct ProfileTabVisibility: Equatable, Sendable {
    public enum Tab: CaseIterable, Sendable {
        case likes, saved, reposts

        public var title: String {
            switch self {
            case .likes: "Liked"
            case .saved: "Saved"
            case .reposts: "Reposts"
            }
        }
    }

    public var likes: Bool
    public var saved: Bool
    public var reposts: Bool

    public init(likes: Bool, saved: Bool, reposts: Bool) {
        self.likes = likes
        self.saved = saved
        self.reposts = reposts
    }

    init(_ settings: Profile_V1_TabSettings) {
        self.init(likes: settings.showLikes, saved: settings.showSaved, reposts: settings.showReposts)
    }

    public subscript(tab: Tab) -> Bool {
        get {
            switch tab {
            case .likes: likes
            case .saved: saved
            case .reposts: reposts
            }
        }
        set {
            switch tab {
            case .likes: likes = newValue
            case .saved: saved = newValue
            case .reposts: reposts = newValue
            }
        }
    }
}

/// Settings → Privacy → Profile Tabs.
public protocol ProfileTabVisibilityManaging: Sendable {
    func tabVisibility() async throws -> ProfileTabVisibility
    func setTab(_ tab: ProfileTabVisibility.Tab, visible: Bool) async throws
}

extension ProfileRepository: ProfileTabVisibilityManaging {
    public func tabVisibility() async throws -> ProfileTabVisibility {
        // Owner-only on the view: the active profile reading itself.
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return ProfileTabVisibility(view.tabSettings)
    }

    public func setTab(_ tab: ProfileTabVisibility.Tab, visible: Bool) async throws {
        var request = Profile_V1_SetTabSettingsRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setTabVisibility").rawValue
        // Partial: the window (unspecified) and the other flags (unset) keep
        // their values.
        switch tab {
        case .likes: request.showLikes = visible
        case .saved: request.showSaved = visible
        case .reposts: request.showReposts = visible
        }
        let response = await profileClient.setTabSettings(request: request, headers: [:])
        if let error = response.error {
            throw ProfileError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }
}
