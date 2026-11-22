import CoreModels
import ProfileData

/// What mute, restrict and reports ask of their view model (#2522): the
/// profile, whether it can be moderated, and where results and Undo go.
@MainActor
protocol ProfileModerationHost: AnyObject {
    var profile: UserProfile? { get }
    var canModerate: Bool { get }
    var onUndoable: ((UndoableAction) -> Void)? { get }
    var onActionResult: ((ProfileViewModel.ActionResult) -> Void)? { get }
    var onMuteScopesChange: ((MuteScopes) -> Void)? { get }
}

/// Mute, restrict and reports, out of `ProfileViewModel` (#2522): the
/// toggles with their Undo and rollback, the read that rides beside the
/// relationship, and the profile's and the gallery posts' reports.
///
/// ⚠️ A TASK THAT HOLDS ITSELF ACROSS AN AWAIT HOLDS THE VIEW MODEL TOO
/// (`let host = self.host`): the view model used to be what such a Task
/// kept alive, and the host is `unowned`.
@MainActor
final class ProfileModeration {
    private unowned let host: any ProfileModerationHost
    private let repository: any ProfileProviding
    private let reporting: (any ContentReporting)?

    init(host: any ProfileModerationHost, repository: any ProfileProviding, reporting: (any ContentReporting)?) {
        self.host = host
        self.repository = repository
        self.reporting = reporting
    }

    private var reportInFlight = false
    /// What of this profile the viewer has muted (#403), read beside the
    /// relationship; the nav bar's bell shows and edits it (#689).
    public private(set) var muteScopes: MuteScopes = .none {
        didSet {
            guard muteScopes != oldValue else { return }
            host.onMuteScopesChange?(muteScopes)
        }
    }
    private(set) var muteInFlight = false
    /// Bumped by every mute toggle, so a read that started before one can't
    /// land after it and put the old scopes back.
    private var muteGeneration = 0
    /// Whether this composition can mute at all.
    public var canMute: Bool { repository is any ProfileMuting }
    /// Whether the viewer restricts this profile (#416), read beside the mute.
    public private(set) var isRestricted = false
    private var restrictInFlight = false
    /// Same guard as `muteGeneration`, for restrict.
    private var restrictGeneration = 0
    public var canRestrict: Bool { repository is any ProfileRestricting }

    /// Switches one mute scope. Optimistic, unlike block: a mute is a quiet
    /// preference the target never sees, so a rollback costs nothing. The
    /// toast says what is muted now.
    public func toggleMute(_ scope: MuteScope) {
        guard let profile = host.profile, host.canModerate, !muteInFlight, let muting = repository as? any ProfileMuting else { return }
        let before = muteScopes
        let after = before.toggling(scope)
        // Muting MORE is shown with Undo (#957), a deferred commit; un-muting
        // stays the menu's own reverse row and goes out at once.
        if after.contains(scope), host.onUndoable != nil {
            muteScopes = after
            // A read out from before the toggle must not overwrite it.
            muteGeneration += 1
            let handle = "@" + profile.handle
            let id = profile.id
            host.onUndoable?(UndoableAction(
                message: Self.muteMessage(handle: handle, scopes: after),
                symbol: "speaker.slash.fill",
                commit: { [weak self] in
                    // Superseded on this screen (un-muted from the menu, or a
                    // later mute that carries this one): not sent. Gone with
                    // the screen, it still is.
                    if let self, self.muteScopes != after { return }
                    Task { @MainActor [weak self] in
                        do {
                            try await muting.setMuteScopes(after, for: id)
                        } catch {
                            guard let self, self.muteScopes == after else { return }
                            self.muteScopes = before
                            host.onActionResult?(.commitFailed(message: "Couldn't mute \(handle)"))
                        }
                    }
                },
                undo: { [weak self] in
                    guard let self, self.muteScopes == after else { return }
                    self.muteScopes = before
                    self.muteGeneration += 1
                }
            ))
            return
        }
        muteScopes = after
        muteInFlight = true
        muteGeneration += 1
        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                try await muting.setMuteScopes(after, for: profile.id)
                host.onActionResult?(.muteChanged(handle: "@" + profile.handle, scopes: after))
            } catch {
                self.muteScopes = before
                host.onActionResult?(.failed(message: "Couldn't change what you mute from this profile."))
            }
            self.muteInFlight = false
        }
    }

    /// Restrict or unrestrict. Optimistic, like mute: the target never sees it.
    public func toggleRestrict() {
        guard let profile = host.profile, host.canModerate, !restrictInFlight, let restricting = repository as? any ProfileRestricting else { return }
        let target = !isRestricted
        // Restricting is shown with Undo (#957), a deferred commit;
        // unrestricting stays the menu's reverse row and goes out at once.
        if target, host.onUndoable != nil {
            isRestricted = true
            // A read out from before the toggle must not overwrite it.
            restrictGeneration += 1
            let handle = "@" + profile.handle
            let id = profile.id
            host.onUndoable?(UndoableAction(
                message: "Restricted \(handle)",
                symbol: "person.crop.circle.badge.minus",
                commit: { [weak self] in
                    // Unrestricted from the menu meanwhile: not sent.
                    if let self, !self.isRestricted { return }
                    Task { @MainActor [weak self] in
                        do {
                            try await restricting.setRestricted(true, for: id)
                        } catch {
                            guard let self, self.isRestricted else { return }
                            self.isRestricted = false
                            host.onActionResult?(.commitFailed(message: "Couldn't restrict \(handle)"))
                        }
                    }
                },
                undo: { [weak self] in
                    self?.isRestricted = false
                    self?.restrictGeneration += 1
                }
            ))
            return
        }
        isRestricted = target
        restrictInFlight = true
        restrictGeneration += 1
        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                try await restricting.setRestricted(target, for: profile.id)
                host.onActionResult?(.restrictChanged(handle: "@" + profile.handle, restricted: target))
            } catch {
                self.isRestricted = !target
                host.onActionResult?(.failed(message: target ? "Couldn't restrict this profile." : "Couldn't unrestrict this profile."))
            }
            self.restrictInFlight = false
        }
    }

    /// "Muted @ada's posts and messages", "Unmuted @ada".
    public nonisolated static func muteMessage(handle: String, scopes: MuteScopes) -> String {
        guard !scopes.isEmpty else { return "Unmuted \(handle)" }
        let names = MuteScope.allCases.filter(scopes.contains).map { $0.title.lowercased() }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
        return "Muted \(handle)'s \(list)"
    }

    /// File a moderation report against this profile. Reports are fire-and-
    /// confirm: the result is reported either way, because a report the user
    /// believes was filed but wasn't is the worst outcome here.
    public func report(_ reason: ReportReason) {
        guard let profile = host.profile, host.canModerate, !reportInFlight else { return }
        guard let reporting else {
            host.onActionResult?(.failed(message: "Reporting isn't available right now."))
            return
        }
        reportInFlight = true

        Task { [weak self] in
            guard let self else { return }
            let host = self.host
            do {
                // The surface is a triage signal: the same profile reported
                // from its own screen and from a post card are different
                // reports.
                try await reporting.report(
                    .profile(profile.id), reason: reason, surface: "ios.profile"
                )
                host.onActionResult?(.reported)
            } catch {
                host.onActionResult?(.failed(message: "Couldn't send this report. Try again."))
            }
            self.reportInFlight = false
        }
    }

    /// The mute and restrict states, read beside the relationship once it
    /// has answered (the relationship read awaits it).
    func readMuteAndRestrict(for id: ProfileID, relationship: ProfileRelationship) async {
        // The mute rides beside the relationship; only someone else's
        // profile can be muted.
        // A toggle made while a read was out wins: the read is from before.
        let muteAsked = self.muteGeneration
        if relationship != .me, let muting = self.repository as? any ProfileMuting,
           let scopes = try? await muting.muteScopes(for: id),
           !self.muteInFlight, self.muteGeneration == muteAsked {
            self.muteScopes = scopes
        }
        let restrictAsked = self.restrictGeneration
        if relationship != .me, let restricting = self.repository as? any ProfileRestricting,
           let restricted = try? await restricting.isRestricted(id),
           !self.restrictInFlight, self.restrictGeneration == restrictAsked {
            self.isRestricted = restricted
        }
    }

    public func canReportPost(by authorID: ProfileID?) -> Bool {
        guard reporting != nil else { return false }
        // `canModerate` is false exactly on the viewer's own profile, and there
        // an author matching the profile IS the viewer.
        return host.canModerate || authorID != host.profile?.id
    }

    /// File a moderation report against one of the gallery's posts. Same
    /// fire-and-confirm contract as `report(_:)`, and the same reason: a report
    /// the user believes was filed but wasn't is the worst outcome here.
    public func reportPost(_ postID: PostID, reason: ReportReason) {
        guard let reporting else {
            host.onActionResult?(.failed(message: "Reporting isn't available right now."))
            return
        }
        Task { [weak self] in
            do {
                try await reporting.report(
                    .post(postID), reason: reason, surface: "ios.profile.gallery"
                )
                self?.host.onActionResult?(.reported)
            } catch {
                self?.host.onActionResult?(.failed(message: "Couldn't send this report. Try again."))
            }
        }
    }
}
