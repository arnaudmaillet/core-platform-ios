import CoreModels
import Foundation

/// Who is using the app, as every feature should ask it.
///
/// `AuthState` says whether a session exists; this says who it is FOR: the
/// account, and which of its profiles is active. A guest has no account yet —
/// the app runs read-only for them (`dev/GUEST_MODE_REPORT.md`).
public enum ViewerState: Equatable, Sendable {
    case guest
    /// `activeProfile` is nil until it has been resolved (the account's first
    /// profile, or whichever one a switch chose).
    case member(AccountID, activeProfile: ProfileID?)
}

public enum ViewerError: Error, Equatable, Sendable {
    /// Nobody is signed in: the action needs an account.
    case requiresMember
    /// The account holds no profile yet (sign-up not finished).
    case noProfileForAccount
}

/// The one place that answers "who am I". Repositories ask it instead of each
/// resolving and caching the viewer on their own.
public protocol ViewerProviding: Sendable {
    func current() async -> ViewerState
    /// Emits the current state, then every change — resolution included.
    func updates() async -> AsyncStream<ViewerState>
    /// Emits only when the viewer becomes someone else: another account, a
    /// sign-out, or a switch away from an already-resolved profile. Never the
    /// initial state, never a first resolution. What `ViewerScoped` caches hear.
    func transitions() async -> AsyncStream<ViewerState>
    /// The active profile, resolved on first use and then cached until the
    /// viewer changes. Throws `ViewerError.requiresMember` for a guest.
    func activeProfileID() async throws -> ProfileID
    /// Makes `id` the active profile, for every repository at once.
    func setActiveProfile(_ id: ProfileID) async
}

public extension Notification.Name {
    /// Posted on the main queue after every viewer transition, for main-actor
    /// caches no repository owns (`ProfileCache`). No object, no user info.
    static let viewerDidChange = Notification.Name("ViewerDidChange")
}

/// A cache that holds data about the viewer and must drop it when the viewer
/// becomes someone else (`ViewerProviding.transitions()`).
public protocol ViewerScoped: Sendable {
    func viewerDidChange(_ state: ViewerState) async
}

/// `ViewerProviding` over the auth session and a profile lister.
///
/// ⚠️ SIX COPIES OF THIS USED TO EXIST: Feed, Comments, Profile, Chat,
/// Notifications and the post composer each resolved account → first profile
/// and cached it forever. A switch reached only Profile (and Comments, through
/// a notification), and a logout reached none of them, so the next account
/// signed in on the previous one's profile id. One instance is shared by the
/// whole app (`AppContainer.viewerSession`).
///
/// The lister is a closure so this stays free of the generated contracts:
/// the composition root passes `AccountProfilesReader`.
public actor ViewerSession: ViewerProviding {
    public typealias ProfileLister = @Sendable (AccountID) async throws -> [ProfileID]

    private let authSession: any AuthSessionProviding
    private let listProfiles: ProfileLister

    /// False until the first auth state is read: that read sets the starting
    /// viewer without counting as a transition.
    private var known = false
    private var account: AccountID?
    private var profileID: ProfileID?
    /// Bumped whenever the account changes, so a profile list that comes back
    /// for an account that is no longer signed in is thrown away.
    private var generation = 0
    /// Single flight: concurrent first reads share one list call.
    private var inflight: Task<[ProfileID], any Error>?

    private var observing = false
    private var updateContinuations: [UUID: AsyncStream<ViewerState>.Continuation] = [:]
    private var transitionContinuations: [UUID: AsyncStream<ViewerState>.Continuation] = [:]

    public init(authSession: any AuthSessionProviding, listProfiles: @escaping ProfileLister) {
        self.authSession = authSession
        self.listProfiles = listProfiles
    }

    // MARK: - ViewerProviding

    public func current() async -> ViewerState {
        sync(with: await authSession.currentState())
        return state
    }

    public func updates() async -> AsyncStream<ViewerState> {
        let (stream, continuation) = AsyncStream<ViewerState>.makeStream()
        let id = UUID()
        updateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(id) }
        }
        continuation.yield(await current())
        startObservingIfNeeded()
        return stream
    }

    public func transitions() async -> AsyncStream<ViewerState> {
        let (stream, continuation) = AsyncStream<ViewerState>.makeStream()
        let id = UUID()
        transitionContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTransitionContinuation(id) }
        }
        startObservingIfNeeded()
        return stream
    }

    public func activeProfileID() async throws -> ProfileID {
        sync(with: await authSession.currentState())
        guard let account else { throw ViewerError.requiresMember }
        if let profileID { return profileID }

        let generation = generation
        let task: Task<[ProfileID], any Error>
        if let inflight {
            task = inflight
        } else {
            let listProfiles = listProfiles
            task = Task { try await listProfiles(account) }
            inflight = task
        }
        let ids: [ProfileID]
        do {
            ids = try await task.value
        } catch {
            if inflight == task { inflight = nil }
            throw error
        }
        // The account changed while the list was in flight: the answer is
        // someone else's. Ask again for whoever is signed in now. Read the
        // auth state again first — nothing else may have synced meanwhile.
        sync(with: await authSession.currentState())
        guard self.generation == generation else { return try await activeProfileID() }
        if inflight == task { inflight = nil }
        // A switch landed while the list was in flight; it wins.
        if let profileID { return profileID }
        guard let first = ids.first else { throw ViewerError.noProfileForAccount }
        profileID = first
        yieldUpdate()
        return first
    }

    public func setActiveProfile(_ id: ProfileID) async {
        sync(with: await authSession.currentState())
        guard account != nil, profileID != id else { return }
        let previous = profileID
        profileID = id
        yieldUpdate()
        // A first resolution is not a change of viewer; leaving a profile is.
        if previous != nil { yieldTransition() }
    }

    // MARK: - State

    private var state: ViewerState {
        guard let account else { return .guest }
        return .member(account, activeProfile: profileID)
    }

    private func sync(with authState: AuthState) {
        let newAccount: AccountID?
        switch authState {
        case .unauthenticated: newAccount = nil
        case .authenticated(let accountID): newAccount = accountID
        }
        guard known else {
            known = true
            account = newAccount
            return
        }
        guard newAccount != account else { return }
        account = newAccount
        profileID = nil
        generation += 1
        inflight = nil
        yieldUpdate()
        yieldTransition()
    }

    private func startObservingIfNeeded() {
        guard !observing else { return }
        observing = true
        Task { [weak self, authSession] in
            // Each emission is only a nudge: the state is read again, because
            // `current()` and `activeProfileID()` sync on their own too, and a
            // buffered emission replayed after them would flip the viewer back
            // to someone who has already left.
            for await _ in await authSession.stateUpdates() {
                guard let self else { return }
                await self.syncWithAuth()
            }
        }
    }

    private func syncWithAuth() async {
        sync(with: await authSession.currentState())
    }

    private func yieldUpdate() {
        let state = state
        for continuation in updateContinuations.values { continuation.yield(state) }
    }

    private func yieldTransition() {
        let state = state
        for continuation in transitionContinuations.values { continuation.yield(state) }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations[id] = nil
    }

    private func removeTransitionContinuation(_ id: UUID) {
        transitionContinuations[id] = nil
    }
}
