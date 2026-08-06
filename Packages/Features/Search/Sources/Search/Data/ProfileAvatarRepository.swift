import CoreContracts
import CoreModels
import Foundation

/// Resolves people to their pictures.
///
/// **Why this exists at all.** Only one of the search screen's three person
/// lists gets an avatar for free: Suggestions is built from the timeline,
/// which hydrates authors through `profile.v1` and so already carries a URL.
/// The other two do not, for two different reasons:
///
/// - `search.v1.ProfileHit` carries `avatar_key` — a STORAGE KEY, not a URL —
///   and nothing in the app resolves keys. Results would render initials
///   forever no matter how the UI was written.
/// - `search.v1.Suggest` answers with completion text and an id. There is no
///   avatar in the response at all.
///
/// So the picture has to be fetched. `profile.v1.GetProfileById` is the only
/// read that returns one, and it is per-person — which is the cost this type
/// exists to bound.
public protocol ProfileAvatarProviding: Sendable {
    /// Best-effort. A person who cannot be read, or has no picture, is simply
    /// absent from the result — the row keeps its initials, which is what
    /// initials are for.
    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL]
}

/// Reads avatars from `profile.v1`, once per person per session.
///
/// ⚠️ **This is an N+1 fan-out and it is deliberate.** `profile.v1` exposes
/// only a singular `GetProfileById` — there is no batch read anywhere in the
/// contracts — so a list of ten people is ten calls. What makes it affordable
/// rather than reckless:
///
/// - **The cache is permanent for the session** and remembers the *absence* of
///   a picture too, so a person with none is asked about exactly once rather
///   than on every keystroke that re-lists them.
/// - **In-flight requests are shared**, so the typeahead re-rendering three
///   times while a fetch is out spends one call, not three.
/// - **Callers pass only what is on screen.** Nothing prefetches.
///
/// The batched read is the right fix and it is a backend ask, not a client
/// one — see `dev/BACKEND_GAPS.md`, which already records the same shape for
/// the feed's hydration (a 20-item page costing 21+ round trips).
public actor ProfileAvatarRepository: ProfileAvatarProviding {
    private let profileClient: any Profile_V1_ProfileServiceClientInterface

    /// People already asked about. Present with a URL, or present with nil
    /// meaning "asked, has none" — the distinction is what stops the retry
    /// loop on people who simply have no picture.
    private var resolved: [ProfileID: URL?] = [:]
    /// Shared work, so concurrent callers for the same person queue behind one
    /// request instead of racing it.
    private var inFlight: [ProfileID: Task<URL?, Never>] = [:]

    public init(profileClient: any Profile_V1_ProfileServiceClientInterface) {
        self.profileClient = profileClient
    }

    public func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] {
        let wanted = Set(ids)
        // Everything already known, answered without touching the network.
        var found: [ProfileID: URL] = [:]
        var missing: [ProfileID] = []
        for id in wanted {
            if let cached = resolved[id] {
                if let url = cached { found[id] = url }
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return found }

        let tasks = missing.map { id in (id, task(for: id)) }
        for (id, task) in tasks {
            if let url = await task.value { found[id] = url }
        }
        return found
    }

    private func task(for id: ProfileID) -> Task<URL?, Never> {
        if let existing = inFlight[id] { return existing }
        let task = Task<URL?, Never> { [profileClient] in
            var request = Profile_V1_GetProfileByIdRequest()
            request.profileID = id.rawValue
            let response = await profileClient.getProfileByID(request: request, headers: [:])
            guard case .success(let view) = response.result else { return nil }
            return URL(string: view.avatarURL)
        }
        inFlight[id] = task
        Task { await self.finish(id, url: await task.value) }
        return task
    }

    private func finish(_ id: ProfileID, url: URL?) {
        // A failed read is cached as "no picture" on purpose: retrying it on
        // every re-render would turn one unreachable person into a request per
        // keystroke. The row keeps its initials, which is the honest fallback.
        resolved[id] = .some(url)
        inFlight[id] = nil
    }
}
