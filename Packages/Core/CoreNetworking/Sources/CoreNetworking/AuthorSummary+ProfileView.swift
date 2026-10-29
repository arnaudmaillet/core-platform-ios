import CoreContracts
import CoreModels
import Foundation

public extension AuthorSummary {
    /// The person a `profile.v1` view describes, as every screen shows them
    /// (#1858): what `PeopleSightings` is told by each surface that hydrated
    /// them. An empty avatar or frame is none.
    init(profileView view: Profile_V1_ProfileView) {
        self.init(
            id: ProfileID(view.profileID),
            handle: view.handle,
            displayName: view.displayName,
            avatarURL: view.avatarURL.isEmpty ? nil : URL(string: view.avatarURL),
            avatarFrameID: view.avatarFrameID.isEmpty ? nil : view.avatarFrameID,
            // `banner_url`, or a banner media (#944): either is a banner.
            hasBanner: !view.bannerURL.isEmpty || !view.banner.renditions.isEmpty
        )
    }
}
