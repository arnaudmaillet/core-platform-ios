import CoreStorage
import WalletInterface

/// The shop's words and symbols for each profile item (the seller's contract,
/// `ProfileItemSelling`, is in WalletInterface since #2385).
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
