import CoreStorage

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
