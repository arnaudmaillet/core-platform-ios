import Connect
import CoreContracts
import CoreModels
import Foundation

/// A `profile.v1` client that answers identity reads and nothing else.
///
/// Shared because two suites need the same thirteen-method conformance for
/// entirely different reasons — one cares which ids survive an intersection,
/// the other how many times a repository asks about the same person — and the
/// stubs for the eleven commands neither of them calls are identical either way.
///
/// It COUNTS `getProfileByID`, which is the only interesting thing a fake can
/// say here: the difference between a repository that resolves an author once
/// and one that resolves it per post is invisible in the result and is exactly
/// the kind of fan-out that regresses silently.
final class StubProfileServiceClient: Profile_V1_ProfileServiceClientInterface, @unchecked Sendable {
    /// Identities to answer with, by profile id. An id that is absent still
    /// gets a view, echoing the id into both name fields — the behaviour
    /// callers that do not care about rendering rely on.
    struct Identity: Sendable {
        let handle: String
        let displayName: String
        let avatarURL: String

        init(handle: String, displayName: String, avatarURL: String = "") {
            self.handle = handle
            self.displayName = displayName
            self.avatarURL = avatarURL
        }
    }

    private let identities: [String: Identity]
    /// Ids that must answer as a FAILED read, so a caller's degraded path is
    /// reachable without taking the whole client down.
    private let unreachable: Set<String>

    private let lock = NSLock()
    private var reads: [String] = []

    init(identities: [String: Identity] = [:], unreachable: Set<String> = []) {
        self.identities = identities
        self.unreachable = unreachable
    }

    /// Every id asked about, in call order — duplicates included, which is the
    /// whole point.
    var readIDs: [String] { lock.withLock { reads } }

    var readCount: Int { readIDs.count }

    /// `withLock`, not `lock()`/`unlock()`: the bare pair is unavailable from an
    /// async context, and this method is one — the reads it counts arrive
    /// concurrently from a task group, which is the only reason a lock is here.
    private func record(_ id: String) {
        lock.withLock { reads.append(id) }
    }

    func getProfileByID(
        request: Profile_V1_GetProfileByIdRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_ProfileView> {
        record(request.profileID)
        if unreachable.contains(request.profileID) {
            return ResponseMessage(result: .failure(ConnectError(code: .unavailable, message: "stub")))
        }
        var view = Profile_V1_ProfileView()
        view.profileID = request.profileID
        if let identity = identities[request.profileID] {
            view.handle = identity.handle
            view.displayName = identity.displayName
            view.avatarURL = identity.avatarURL
        } else {
            view.handle = request.profileID
            view.displayName = request.profileID
        }
        return ResponseMessage(result: .success(view))
    }

    func getProfileByHandle(
        request: Profile_V1_GetProfileByHandleRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_ProfileView> {
        ResponseMessage(result: .success(Profile_V1_ProfileView()))
    }

    func listProfilesByAccount(
        request: Profile_V1_ListProfilesByAccountRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_ListProfilesByAccountResponse> {
        ResponseMessage(result: .success(Profile_V1_ListProfilesByAccountResponse()))
    }

    func createProfile(
        request: Profile_V1_CreateProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func updateProfile(
        request: Profile_V1_UpdateProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func changeHandle(
        request: Profile_V1_ChangeHandleRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func updateAvatar(
        request: Profile_V1_UpdateAvatarRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func updateBanner(
        request: Profile_V1_UpdateBannerRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func setVisibility(
        request: Profile_V1_SetVisibilityRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func verifyProfile(
        request: Profile_V1_VerifyProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func hideProfile(
        request: Profile_V1_HideProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func restoreProfile(
        request: Profile_V1_RestoreProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }

    func deleteProfile(
        request: Profile_V1_DeleteProfileRequest, headers: Connect.Headers
    ) async -> ResponseMessage<Profile_V1_CommandResponse> {
        ResponseMessage(result: .success(Profile_V1_CommandResponse()))
    }
}
