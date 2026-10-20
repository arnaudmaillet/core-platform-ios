import CoreContracts
import CoreNetworking
import CoreStorage
import Foundation

/// The gem-shop items a profile can wear (#947), as Edit Profile sees them:
/// whether the account owns one, and buying it with gems. The shell answers
/// it (the wallet and the account's items), the screen never touches either.
@MainActor
public protocol ProfileItemAccess: AnyObject {
    var gems: Int { get }
    func owns(_ item: ProfileItem) -> Bool
    /// Its price in gems: the catalogue's, as last read (#1475).
    func price(of item: ProfileItem) -> Int
    /// Buys it — through the server for a member (#1475), so it waits.
    func buy(_ item: ProfileItem) async -> ProfileItemPurchase
}

public extension ProfileItemAccess {
    func price(of item: ProfileItem) -> Int { item.gemPrice }
}

/// Edit Profile → Video banner (#944): the viewer's banner from the loop of
/// one of their own video posts, or none.
public protocol ProfileBannerManaging: Sendable {
    /// Sets the viewer's banner to the video `assetID` (a page of one of
    /// their own video posts), or back to none for nil, and returns the
    /// profile as it now reads.
    func setBannerVideo(assetID: String?) async throws -> UserProfile
}

public enum ProfileBannerError: Error, Equatable {
    case rejected(message: String)
    case transport(message: String)
}

extension ProfileRepository: ProfileBannerManaging {
    /// `UpdateBanner` with the asset alone: the server makes the banner
    /// from that media — the loop, and its poster as the still
    /// (core-platform-backend#915). Both fields empty clears it.
    public func setBannerVideo(assetID: String?) async throws -> UserProfile {
        var request = Profile_V1_UpdateBannerRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "updateBanner").rawValue
        request.bannerAssetID = assetID ?? ""
        let response = await profileClient.updateBanner(request: request, headers: [:])
        if let error = response.error {
            switch error.code {
            case .invalidArgument, .failedPrecondition, .permissionDenied:
                throw ProfileBannerError.rejected(message: error.message ?? "")
            default:
                throw ProfileBannerError.transport(message: error.message ?? "code \(error.code)")
            }
        }
        return try await currentUserProfile()
    }
}
