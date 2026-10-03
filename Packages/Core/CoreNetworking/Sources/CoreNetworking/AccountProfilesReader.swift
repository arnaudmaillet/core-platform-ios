import CoreContracts
import Foundation

/// An account's profile ids, in the order `profile.v1` lists them (the first is
/// the account's default profile).
///
/// The transport half of the viewer resolution that `AuthInterface.ViewerSession`
/// owns; the session takes it as a closure so the interface package stays free
/// of the generated contracts. Ids are plain strings for the same reason
/// `PostCounterReader` keys by string: nothing above the contracts comes with it.
public enum AccountProfilesReader {
    public struct ReadError: Error, Equatable, Sendable {
        public let message: String
    }

    public static func profileIDs(
        ofAccount accountID: String,
        using client: any Profile_V1_ProfileServiceClientInterface
    ) async throws -> [String] {
        var request = Profile_V1_ListProfilesByAccountRequest()
        request.accountID = accountID
        let response = await client.listProfilesByAccount(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return body.profiles.map(\.profileID)
        case .failure(let error):
            throw ReadError(message: error.message ?? "code \(error.code)")
        }
    }
}
