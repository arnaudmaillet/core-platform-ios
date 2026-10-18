import CoreStorage
import Foundation

/// The profile items the Shop sells (#944, #947): the video banner today.
/// The shell answers it with the account's items and the wallet's gems; the
/// Shop never touches either. Owned, an item is still on the shelf, as owned.
@MainActor
public protocol ProfileItemSelling: AnyObject {
    /// What the shelf shows, in order.
    var items: [ProfileItem] { get }
    func owns(_ item: ProfileItem) -> Bool
    func buy(_ item: ProfileItem) -> ProfileItemPurchase
}

extension ProfileItem {
    /// The Shop's name for it.
    var shopTitle: String {
        switch self {
        case .videoBanner: "Video Banner"
        }
    }

    /// What it does, in a line.
    var shopDetail: String {
        switch self {
        case .videoBanner: "A loop from one of your videos at the top of your profile"
        }
    }

    /// Where it is used once owned.
    var whereToUse: String {
        switch self {
        case .videoBanner: "Choose its video in Edit Profile"
        }
    }

    var shopSymbol: String {
        switch self {
        case .videoBanner: "play.rectangle.fill"
        }
    }
}
