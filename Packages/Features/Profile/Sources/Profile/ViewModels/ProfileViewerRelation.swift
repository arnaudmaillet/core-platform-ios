import CoreModels
import LaunchArguments
import OSLog
import ProfileData

/// What the relationship asks of its view model (#2522): the profile and
/// whose it is, where its answers go, and the parts a follow change moves —
/// the follower count (the view model's to write), the gallery, the map pin
/// and the mute and restrict read.
@MainActor
protocol ProfileViewerRelationHost: AnyObject {
    var profile: UserProfile? { get }
    var isOwnProfile: Bool { get }
    var handle: String? { get }
    var onFollowButtonChange: ((ProfileViewModel.FollowButton) -> Void)? { get }
    var onRelationshipSettled: (() -> Void)? { get }
    var onActionResult: ((ProfileViewModel.ActionResult) -> Void)? { get }
    var onDismissRequested: (() -> Void)? { get }
    func nudgeFollowerCount(_ following: Bool, on profile: UserProfile)
    func viewerFollowDidChange()
    func renderGallery()
    func refreshMapPinButton()
    func loadMapPinState()
    func readMuteAndRestrict(for id: ProfileID, relationship: ProfileRelationship) async
}

/// The viewer's relationship to the profile, out of `ProfileViewModel`
/// (#2522): the Follow button and the state behind it, follow, request,
/// withdraw, block and unblock, the relationship read and the follow-graph
/// events. The view model hears the events and forwards them here.
///
/// ⚠️ THE `didSet`S KEEP THEIR ORDER: `apply` sets `isFollowing` (the
/// gallery) before `followButton` (the button, then the map pin).
///
/// ⚠️ A TASK THAT HOLDS ITSELF ACROSS AN AWAIT HOLDS THE VIEW MODEL TOO
/// (`let host = self.host`): the view model used to be what such a Task
/// kept alive, and the host is `unowned`.
@MainActor
final class ProfileViewerRelation {
    typealias FollowButton = ProfileViewModel.FollowButton

    private unowned let host: any ProfileViewerRelationHost
    private let repository: any ProfileProviding
    private let cache: ProfileCache?

    init(host: any ProfileViewerRelationHost, repository: any ProfileProviding, cache: ProfileCache?) {
        self.host = host
        self.repository = repository
        self.cache = cache
    }

    private(set) var followButton: FollowButton = .hidden {
        didSet {
            // ⚠️ AN ANSWER THAT AGREES WITH THE SCREEN SAYS NOTHING. Every
            // refresh reads the relationship again, and each identical answer
            // used to re-pose the tray's capsule, cross-dissolve the whole
            // navigation bar and re-ask the map pin — a landing turn's worth
            // of work, on a pull-to-refresh, to arrive where it already was.
            guard followButton != oldValue else { return }
            host.onFollowButtonChange?(followButton)
            // The pin is offered only while the viewer follows, so the two
            // move together — including the optimistic flip a follow tap makes
            // before the server has answered. A newly-followed profile has
            // never been asked about, so ask now.
            host.refreshMapPinButton()
            host.loadMapPinState()
        }
    }
    /// Whether they follow back. Only a mutual may be kept on the Friends
    /// rail, so only a mutual is offered the choice.
    private(set) var isMutual = false
    /// Whether the viewer and the profile follow each other: the bar's
    /// badge reads friends then (#1451).
    var isMutualFollow: Bool { isMutual }
    private(set) var isFollowing = false {
        // A private profile's pages lock and unlock with the follow (#447).
        didSet {
            guard isFollowing != oldValue else { return }
            host.viewerFollowDidChange()
        }
    }
    /// Internal for tests: a follow, request or withdrawal still on its way.
    private(set) var followInFlight = false
    /// The viewer's outbound block on this profile, from the relationship read
    /// and kept current by `setBlocked`. Drives which of Block / Unblock the
    /// overflow menu offers.
    public private(set) var isBlocked = false
    private var blockInFlight = false
    private(set) var relationshipLoad: Task<Void, Never>?
    /// Whether a relationship read is out — for tests that wait on its answer.
    var isLoadingRelationship: Bool { relationshipLoad != nil }
    /// Whether the follow state on screen is an answer rather than a wait:
    /// a relationship read has come back (or failed), or a cache seeded one.
    public private(set) var isRelationshipSettled = false {
        didSet {
            guard isRelationshipSettled, !oldValue else { return }
            host.onRelationshipSettled?()
            // A private profile not followed locks its pages now (#1900).
            if isPrivateToViewer { host.renderGallery() }
        }
    }

    /// Follow, request and withdraw failures, with the server's code (#1450).
    private static let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "profile")

    /// A request made or withdrawn ANYWHERE — a list row, a suggestion — for
    /// this profile (#1450): its button reads "Requested" when the viewer
    /// comes back to it, so its next tap is no refused duplicate. Its own
    /// request in flight answers for itself.
    func followRequestDidChange(_ change: FollowRequestChange) {
        guard let profile = host.profile, change.profileID == profile.id, !followInFlight, !isFollowing else { return }
        if change.isPending, followButton == .follow {
            showRequested(true)
        } else if !change.isPending, followButton == .requested {
            showRequested(false)
        }
    }

    /// Takes a change about THIS profile the way its own toggle would —
    /// button, and the follower count nudged by one — unless the button says
    /// so already (which is how its own accepted toggle comes back), or its
    /// own toggle is still in flight and about to answer for itself.
    func followGraphDidChange(_ change: FollowChange) {
        guard let profile = host.profile, change.profileID == profile.id,
              followButton == .follow || followButton == .following,
              change.isFollowing != isFollowing, !followInFlight else { return }
        applyFollow(change.isFollowing, on: profile)
    }

    /// Whether the "Message" action applies (another user's profile).
    public var canMessage: Bool { followButton.isOtherProfile }

    /// Whether the moderation actions (Block / Report) apply. False for the
    /// viewer's own profile, and false until the relationship is known — a
    /// menu opened mid-load offers sharing only rather than guessing.
    public var canModerate: Bool { followButton.isOtherProfile }

    /// Follow-button tapped. No-op for the viewer's own profile ("Edit"); an
    /// optimistic toggle otherwise — flip immediately, roll back if the server
    /// rejects. One mutation in flight at a time.
    ///
    /// A private profile is asked rather than followed (#396): Follow turns
    /// into Requested (no follower count moves), and Requested withdraws the
    /// request. The server has the last word: a profile that turned public
    /// meanwhile is followed, one that turned private is asked.
    ///
    /// Answers whether the tap turned the follow ON (a request counts): the
    /// view plays `toggleOn` then (#1886), and nothing for turning it off.
    @discardableResult
    public func toggleFollow() -> Bool {
        guard let profile = host.profile, !followInFlight else { return false }
        guard followButton.isOtherProfile, followButton != .unavailable else { return false }
        if let requests = repository as? any FollowRequestSending {
            switch followButton {
            case .requested:
                withdrawRequest(on: profile, through: requests)
                return false
            case .follow:
                follow(profile, through: requests)
                return true
            default: break
            }
        }

        let target = !isFollowing
        applyFollow(target, on: profile)
        followInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                try await self.repository.setFollowing(target, for: profile.id)
            } catch {
                Self.logger.error("\(target ? "follow" : "unfollow") \(profile.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // Roll back to the pre-tap state — and say so (#802): a button
                // that flips back on its own reads as a glitch.
                if let current = host.profile {
                    self.applyFollow(!target, on: current)
                }
                host.onActionResult?(.followFailed(message: ProfileViewModel.followFailureMessage(
                    handle: host.handle, change: target ? .follow : .unfollow
                )))
            }
            self.followInFlight = false
        }
        return target
    }

    private func follow(_ profile: UserProfile, through requests: any FollowRequestSending) {
        let asks = profile.visibility == .private
        if asks { showRequested(true) } else { applyFollow(true, on: profile) }
        followInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                let outcome = try await requests.follow(profile.id)
                switch (outcome, asks) {
                case (.requested, false):
                    if let current = host.profile { self.applyFollow(false, on: current) }
                    self.showRequested(true)
                case (.following, true):
                    if let current = host.profile { self.applyFollow(true, on: current) }
                default:
                    break
                }
            } catch {
                // What the server said (#1450): a device run that failed
                // could not tell which code came back.
                Self.logger.error("follow \(profile.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if asks {
                    self.showRequested(false)
                } else if let current = host.profile {
                    self.applyFollow(false, on: current)
                }
                host.onActionResult?(.followFailed(message: ProfileViewModel.followFailureMessage(
                    handle: host.handle, change: asks ? .request : .follow
                )))
            }
            self.followInFlight = false
        }
    }

    private func withdrawRequest(on profile: UserProfile, through requests: any FollowRequestSending) {
        showRequested(false)
        followInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                try await requests.cancelFollowRequest(to: profile.id)
            } catch {
                Self.logger.error("withdraw \(profile.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.showRequested(true)
                host.onActionResult?(.followFailed(message: ProfileViewModel.followFailureMessage(
                    handle: host.handle, change: .withdraw
                )))
            }
            self.followInFlight = false
        }
    }

    /// Requested ⇄ Follow. Neither follows, so no count moves.
    private func showRequested(_ requested: Bool) {
        isFollowing = false
        followButton = requested ? .requested : .follow
        rememberRelationship()
    }

    /// Block this profile, or the whole account behind it.
    ///
    /// Unlike follow, this is NOT optimistic: a block is a safety action whose
    /// UI consequence is leaving the screen, so it must not be shown as done
    /// and then silently rolled back. The state changes only once the server
    /// accepts. One mutation in flight at a time.
    public func block(_ scope: ProfileBlockScope) {
        guard let profile = host.profile, canModerate, !blockInFlight, !isBlocked else { return }
        blockInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                let count: Int
                switch scope {
                case .profile:
                    try await self.repository.setBlocked(true, for: profile.id)
                    count = 1
                case .account:
                    count = try await self.repository.blockAccount(behind: profile.id).count
                }
                self.isBlocked = true
                // Blocking severs the follow edge server-side; mirror that so
                // a re-entry before the next relationship read agrees.
                self.isFollowing = false
                self.followButton = .follow
                self.rememberRelationship()
                // A block hides their posts both ways: no revisit opens on
                // them (#887).
                self.cache?.removeGallery(for: profile.id)
                host.onActionResult?(.blocked(handle: "@" + profile.handle, profileCount: count))
                host.onDismissRequested?()
            } catch {
                host.onActionResult?(.failed(message: "Couldn't block this profile."))
            }
            self.blockInFlight = false
        }
    }

    /// Lift a block on this profile. Account-scoped blocks are NOT undone as a
    /// set: the viewer unblocks whichever profile they navigated to, because
    /// the client can't tell which of the account's profiles were blocked
    /// together versus individually — and silently unblocking aliases the user
    /// never asked about is the wrong way to be wrong about a safety action.
    public func unblock() {
        guard let profile = host.profile, canModerate, !blockInFlight, isBlocked else { return }
        blockInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                try await self.repository.setBlocked(false, for: profile.id)
                self.isBlocked = false
                self.rememberRelationship()
                self.cache?.removeGallery(for: profile.id)
                host.onActionResult?(.unblocked(handle: "@" + profile.handle))
            } catch {
                host.onActionResult?(.failed(message: "Couldn't unblock this profile."))
            }
            self.blockInFlight = false
        }
    }

    /// Someone else's private profile the viewer doesn't follow — what a
    /// guest always is (#447). Its pages come back empty from the server.
    var isPrivateToViewer: Bool {
        !host.isOwnProfile && host.profile?.visibility.isPrivate == true && !isFollowing
    }

    /// The relationship is best-effort: if it can't be read, the button simply
    /// stays hidden rather than failing the whole screen.
    func loadRelationship(for id: ProfileID) {
        relationshipLoad = Task { [weak self] in
            guard let self else { return }
            let host = self.host
            #if DEBUG
            // Dev convenience: `-profile-relationship-delay` holds the
            // relationship answer for a few seconds, making the nav-bar
            // skeleton capsule and its cross-fade to Follow/Following
            // observable (the mock otherwise answers mid-push).
            if LaunchArgument.profileRelationshipDelay.isPassed() {
                try? await Task.sleep(for: .seconds(3))
            }
            #endif
            let relationship: ProfileRelationship
            do {
                relationship = try await self.repository.relationship(for: id)
            } catch {
                // Superseded by a newer read: that one answers. Otherwise a
                // failure is still an answer — the button stays as it is.
                guard !Task.isCancelled else { return }
                self.isRelationshipSettled = true
                self.relationshipLoad = nil
                return
            }
            guard !Task.isCancelled else { return }
            self.apply(relationship)
            self.cache?.store(relationship, for: id)
            self.relationshipLoad = nil
            await host.readMuteAndRestrict(for: id, relationship: relationship)
        }
    }

    /// Puts a relationship on screen — the read's answer or the cache's.
    func apply(_ relationship: ProfileRelationship) {
        switch relationship {
        case .me:
            isFollowing = false
            isBlocked = false
            followButton = .edit
        case .other(let following, let mutual, let blocked):
            isFollowing = following
            isMutual = mutual
            isBlocked = blocked
            followButton = following ? .following : .follow
        case .requested:
            isFollowing = false
            isMutual = false
            isBlocked = false
            followButton = .requested
        case .cannotFollow:
            isFollowing = false
            isMutual = false
            isBlocked = false
            followButton = .unavailable
        }
        isRelationshipSettled = true
    }

    /// The relationship as this screen now holds it, for the cache — so the
    /// next visit opens on what the viewer last saw here, including a follow
    /// they just made.
    private func rememberRelationship() {
        guard let id = host.profile?.id, followButton.isOtherProfile else { return }
        let relationship: ProfileRelationship = switch followButton {
        case .requested: .requested
        case .unavailable: .cannotFollow
        default: .other(isFollowing: isFollowing, isMutual: isMutual, isBlocked: isBlocked)
        }
        cache?.store(relationship, for: id)
    }

    /// Applies a follow state everywhere it shows: the button and the
    /// optimistic follower count on the rendered profile.
    private func applyFollow(_ following: Bool, on profile: UserProfile) {
        isFollowing = following
        followButton = following ? .following : .follow
        defer { rememberRelationship() }

        host.nudgeFollowerCount(following, on: profile)
    }
}
