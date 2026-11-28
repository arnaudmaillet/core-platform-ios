import PostGrid

/// Builds For You's grid page in a style — `savesPosts` offers the save
/// control (#1273).
typealias ProfileGridPageFactory = (_ style: PostGridPageStyle, _ savesPosts: Bool) -> any PostGridPage

/// The post lists a profile hosts: its tabs, its media gallery, any list
/// inside the profile page, the person's own or someone else's.
@MainActor
enum ProfilePostLists {
    /// ⚠️ NO FOLLOW ON A PROFILE'S POST LISTS (#2419, the owner 2026-11-28):
    /// the profile carries its own Follow (the header's, #2248, #2302), and
    /// one on every row's author band would repeat it. Every page the
    /// profile builds goes through here, so the switch is the host's, once,
    /// never a check per cell (`PostGridPage.offersAuthorFollow`).
    ///
    /// A text post's page opened from the profile is another page: its
    /// caption row keeps its Follow (the owner, 2026-11-28).
    static func withoutAuthorFollow(_ make: @escaping ProfileGridPageFactory) -> ProfileGridPageFactory {
        { style, savesPosts in
            let page = make(style, savesPosts)
            page.offersAuthorFollow = false
            return page
        }
    }
}
