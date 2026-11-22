import MapsInterface
import ProfileData

/// What the map pin asks of its view model (#2522): the profile, the follow
/// state the pin is offered under, and where its button goes.
@MainActor
protocol ProfileMapPinHost: AnyObject {
    var profile: UserProfile? { get }
    var followButton: ProfileViewModel.FollowButton { get }
    var isMutual: Bool { get }
    var onMapPinButtonChange: ((ProfileViewModel.MapPinButton) -> Void)? { get }
}

/// The map-favorite pin, out of `ProfileViewModel` (#2522): the rails the
/// profile is on, their read and their write. The view model tells it when
/// the subject or the follow moves; the button goes out through the view
/// model's `onMapPinButtonChange`.
@MainActor
final class ProfileMapPin {
    typealias MapPinButton = ProfileViewModel.MapPinButton

    private unowned let host: any ProfileMapPinHost
    /// See `ProfileViewModel.mapPinning`.
    private let mapPinning: (any MapProfilePinning)?

    init(host: any ProfileMapPinHost, mapPinning: (any MapProfilePinning)?) {
        self.host = host
        self.mapPinning = mapPinning
    }

    public private(set) var mapPinButton: MapPinButton = .hidden {
        didSet {
            guard mapPinButton != oldValue else { return }
            host.onMapPinButtonChange?(mapPinButton)
        }
    }
    /// Which rails the service last reported (or an optimistic tap set);
    /// `nil` until it has been asked.
    ///
    /// Optional so the button is not shown wearing a guess: resolving the
    /// never-curated fallbacks can take a round trip, and an outline pin that
    /// silently fills in is a worse first impression than a button that
    /// arrives a frame late. Kept apart from `mapPinButton` so the answer
    /// survives the button being hidden and shown again — unfollowing does NOT
    /// unfavorite, by product decision, and re-following should not have to
    /// ask again.
    private var mapCategories: Set<MapFavoriteCategory>?
    /// Supersedes an in-flight read when the subject changes, so a slow answer
    /// about the previous profile cannot land on this one.
    private var mapPinReadTask: Task<Void, Never>?

    /// Another person on screen (the profile's `didSet`): their rails are
    /// asked again.
    func subjectChanged() {
        mapCategories = nil
        refreshMapPinButton()
        loadMapPinState()
    }

    /// Flips ONE rail, leaving the others exactly as they were — what each row
    /// of the checklist does.
    ///
    /// Optimistic, and deliberately without a rollback: the destination is a
    /// local list (`MapFavoritesStore`), so there is no server to disagree —
    /// the write cannot fail in a way the viewer could act on. What it CAN do
    /// is take a moment, because the very first write to a rail has to
    /// materialize its never-curated fallback, and the row must not sit inert
    /// for it.
    ///
    /// Independent toggles rather than presets: three rails have eight states,
    /// and a viewer reading three checkmarks can see all of them and reach any
    /// in one tap. An earlier menu carried a "Both" row for a state the other
    /// rows already spelled — a shortcut the checkmarks make redundant, and an
    /// item whose meaning (add both? clear both?) depended on state the row
    /// itself could not show.
    public func toggleMapCategory(_ category: MapFavoriteCategory) {
        guard case .shown(let categories, _) = mapPinButton else { return }
        setMapCategories(categories.symmetricDifference([category]))
    }

    /// Puts this profile on exactly these rails — what a checklist row
    /// commits, and what the plain toggle funnels through, so there is one
    /// write path and one optimistic update.
    public func setMapCategories(_ categories: Set<MapFavoriteCategory>) {
        guard mapPinButton != .hidden, let mapPinning, let profile = host.profile else { return }
        // A non-mutual cannot be a friend, whatever a caller asks for; the
        // Friends row is the map's mutuals row. The dock and the Following row
        // are open to anyone the viewer follows.
        let allowed = host.isMutual ? categories : categories.subtracting([.friends])
        mapCategories = allowed
        refreshMapPinButton()
        Task { await mapPinning.setCategories(allowed, for: profile.id) }
    }

    /// Re-reads rail membership for the current subject. Called whenever the
    /// subject or the relationship changes — a profile the viewer does not
    /// follow is never asked about, so a stranger's profile costs nothing.
    func loadMapPinState() {
        mapPinReadTask?.cancel()
        guard let mapPinning, let profile = host.profile, host.followButton == .following else { return }
        let id = profile.id
        mapPinReadTask = Task { [weak self] in
            let categories = await mapPinning.categories(for: id)
            guard !Task.isCancelled, let self, host.profile?.id == id else { return }
            self.mapCategories = categories
            self.refreshMapPinButton()
        }
    }

    /// Whether the pin's answer is in: not offered at all, or offered with
    /// its rails read. False only while a followed profile's rails are still
    /// being asked for — the pin would otherwise land beside Message after
    /// the screen is up and squeeze the tray's capsules to make room.
    public var isMapPinSettled: Bool {
        !(mapPinning != nil && host.profile != nil && host.followButton == .following && mapCategories == nil)
    }

    /// The visibility rule, in one place: only a followed profile can be kept
    /// on a rail, and only when there is somewhere to keep them.
    func refreshMapPinButton() {
        guard mapPinning != nil, host.profile != nil, host.followButton == .following,
              let mapCategories else {
            mapPinButton = .hidden
            return
        }
        // A mutual gets the Friends row too; everyone else gets the dock and
        // the Following row.
        mapPinButton = .shown(categories: mapCategories, includesFriends: host.isMutual)
    }
}
