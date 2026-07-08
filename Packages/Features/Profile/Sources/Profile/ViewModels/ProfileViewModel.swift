import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class ProfileViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        case content(ProfileDisplayModel)
        case failed(message: String)
    }

    /// Whose profile this view model loads.
    public nonisolated enum Source: Equatable, Sendable {
        case currentUser
        case profile(ProfileID)
    }

    /// The header's action button. `hidden` until the relationship is known, so
    /// the button never flickers a wrong state on first paint.
    public nonisolated enum FollowButton: Equatable, Sendable {
        case hidden
        case edit
        case follow
        case following
    }

    public var onPhaseChange: ((Phase) -> Void)?
    public var onFollowButtonChange: ((FollowButton) -> Void)?

    private let repository: any ProfileProviding
    private let source: Source
    private let router: (any Router)?

    private var phase: Phase = .loading {
        didSet { onPhaseChange?(phase) }
    }
    private var followButton: FollowButton = .hidden {
        didSet { onFollowButtonChange?(followButton) }
    }

    /// The currently rendered profile — retained so a follow toggle can nudge
    /// its follower count without a full reload.
    private var profile: UserProfile?
    private var isFollowing = false
    private var followInFlight = false

    private var load: Task<Void, Never>?
    private var relationshipLoad: Task<Void, Never>?

    public init(repository: any ProfileProviding, source: Source = .currentUser, router: (any Router)? = nil) {
        self.repository = repository
        self.source = source
        self.router = router
    }

    /// Whether the "Message" action applies (another user's profile).
    public var canMessage: Bool { followButton == .follow || followButton == .following }

    // MARK: - Inputs

    public func viewDidLoad() {
        reload()
    }

    /// Pull-to-refresh. Coalesced: a refresh while one is in flight is ignored.
    public func refresh() {
        guard load == nil else { return }
        reload()
    }

    /// Follow-button tapped. No-op for the viewer's own profile ("Edit"); an
    /// optimistic toggle otherwise — flip immediately, roll back if the server
    /// rejects. One mutation in flight at a time.
    public func toggleFollow() {
        guard let profile, !followInFlight else { return }
        guard followButton == .follow || followButton == .following else { return }

        let target = !isFollowing
        applyFollow(target, on: profile)
        followInFlight = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setFollowing(target, for: profile.id)
            } catch {
                // Roll back to the pre-tap state.
                if let current = self.profile {
                    self.applyFollow(!target, on: current)
                }
            }
            self.followInFlight = false
        }
    }

    /// "Message" tapped — open a DM with this profile via routing. Profile never
    /// imports Chat; it only emits a route.
    public func messageTapped() {
        guard canMessage, let profile else { return }
        router?.route(to: .messageUser(profile.id))
    }

    // MARK: - Loading

    private func reload() {
        load?.cancel()
        relationshipLoad?.cancel()
        followButton = .hidden
        load = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await self.fetch()
                self.profile = profile
                self.phase = .content(ProfileDisplayModel(profile: profile))
                self.loadRelationship(for: profile.id)
            } catch is CancellationError {
                // Superseded by a newer load; leave the phase alone.
            } catch {
                // Only surface a hard failure when there is nothing on screen;
                // a failed refresh keeps the last good content.
                if case .content = self.phase {} else {
                    self.phase = .failed(message: "Couldn't load this profile. Pull to retry.")
                }
            }
            self.load = nil
        }
    }

    private func fetch() async throws -> UserProfile {
        switch source {
        case .currentUser: try await repository.currentUserProfile()
        case .profile(let id): try await repository.profile(id: id)
        }
    }

    /// The relationship is best-effort: if it can't be read, the button simply
    /// stays hidden rather than failing the whole screen.
    private func loadRelationship(for id: ProfileID) {
        relationshipLoad = Task { [weak self] in
            guard let self else { return }
            guard let relationship = try? await self.repository.relationship(for: id) else { return }
            switch relationship {
            case .me:
                self.isFollowing = false
                self.followButton = .edit
            case .other(let following):
                self.isFollowing = following
                self.followButton = following ? .following : .follow
            }
            self.relationshipLoad = nil
        }
    }

    /// Applies a follow state everywhere it shows: the button and the
    /// optimistic follower count on the rendered profile.
    private func applyFollow(_ following: Bool, on profile: UserProfile) {
        isFollowing = following
        followButton = following ? .following : .follow

        let updated = UserProfile(
            id: profile.id,
            handle: profile.handle,
            displayName: profile.displayName,
            bio: profile.bio,
            avatarURL: profile.avatarURL,
            websiteURL: profile.websiteURL,
            isVerified: profile.isVerified,
            followerCount: profile.followerCount.adjusted(by: following ? 1 : -1),
            followingCount: profile.followingCount
        )
        self.profile = updated
        phase = .content(ProfileDisplayModel(profile: updated))
    }
}
