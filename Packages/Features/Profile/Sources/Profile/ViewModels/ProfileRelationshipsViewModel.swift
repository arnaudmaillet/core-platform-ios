import CoreModels
import CoreNavigation
import Foundation

/// Drives the follower / following screen: one state machine per direction,
/// only the visible one loaded.
///
/// The two lists are kept apart rather than merged into one paged stream
/// because they are independent reads with independent cursors, and the
/// segmented control switches between them instantly — a shared cursor would
/// re-fetch a list the user had already scrolled. Loading is lazy: the passive
/// tab costs nothing until it is selected, which halves the fan-out for the
/// (common) case where the user only ever looks at one.
@MainActor
public final class ProfileRelationshipsViewModel {
    /// Everything the screen knows about whose lists these are, seeded
    /// synchronously by the pushing profile screen.
    ///
    /// Seeded rather than re-fetched because the origin *already has all of
    /// it*: the profile it just rendered carries the visibility, and its
    /// relationship read carries the follow state. Re-reading both would put
    /// two round trips in front of a privacy decision that can then be made on
    /// the push's first frame.
    public nonisolated struct Subject: Equatable, Sendable {
        public let id: ProfileID
        /// Raw handle, no `@` sigil.
        public let handle: String
        public let visibility: ProfileVisibility
        /// Whether the viewer follows the subject — the second half of the
        /// privacy inference.
        public let viewerFollowsSubject: Bool
        public let isSelf: Bool
        /// The header's counters, carried through so the segmented control can
        /// show them on the push's first frame. These are the *profile's*
        /// counts, which is the right number to show: it is the size of the
        /// whole list, not of the page currently loaded, and it survives the
        /// search filter.
        public let followerCount: CountEstimate
        public let followingCount: CountEstimate

        public init(
            id: ProfileID,
            handle: String,
            visibility: ProfileVisibility,
            viewerFollowsSubject: Bool,
            isSelf: Bool,
            followerCount: CountEstimate = .unavailable,
            followingCount: CountEstimate = .unavailable
        ) {
            self.id = id
            self.handle = handle
            self.visibility = visibility
            self.viewerFollowsSubject = viewerFollowsSubject
            self.isSelf = isSelf
            self.followerCount = followerCount
            self.followingCount = followingCount
        }
    }

    /// The trailing action a row offers.
    ///
    /// `inert` rather than `none`: an optional `RowAction?` compared against
    /// `.none` silently means *nil*, so a case by that name turns every
    /// `row?.action == .none` into a question about the optional instead of
    /// the action — which is exactly the shape a test and a call site both
    /// reach for. It marks the viewer's own row (you cannot follow yourself)
    /// and any row a deployment has nothing to offer for.
    public nonisolated enum RowAction: Equatable, Sendable {
        case inert
        case follow
        case following
        /// Only on the viewer's OWN followers list, and only where the backend
        /// supports it — see `ProfileRelationshipsProviding.supportsFollowerRemoval`.
        case remove
    }

    /// One rendered row.
    public nonisolated struct Row: Equatable, Sendable, Identifiable {
        public let id: ProfileID
        public let displayName: String
        /// Includes the leading `@`.
        public let handle: String
        public let monogram: String
        public let avatarURL: URL?
        public let isVerified: Bool
        public let action: RowAction
        /// This row is the signed-in viewer, so it is badged "(Me)".
        ///
        /// Only ever true on someone else's list — you cannot follow yourself,
        /// so you appear in neither of your own — which is exactly the case
        /// the badge exists for: picking your own face out of a stranger's
        /// follower list.
        public let isViewer: Bool
    }

    /// What the screen shows for the active direction.
    public nonisolated enum Phase: Equatable, Sendable {
        case loading
        /// `isAppending` drives the paging spinner under the last row.
        case content(rows: [Row], isAppending: Bool)
        case empty(title: String, message: String)
        /// The list exists but isn't the viewer's to see.
        case restricted(title: String, message: String)
        case failed(message: String)
    }

    /// A settled row mutation the view surfaces as a toast. Successes are
    /// silent — the row itself already changed — so this only ever reports
    /// what went wrong.
    public nonisolated enum ActionResult: Equatable, Sendable {
        case failed(message: String)
    }

    /// A direction's phase changed. **Carries its direction**, because all
    /// three lists are on screen at once now — they sit side by side in a
    /// pager, and a background tab finishing its load has to repaint its own
    /// page rather than the visible one.
    public var onPhaseChange: ((RelationshipDirection, Phase) -> Void)?
    /// Fires when the segmented control's selection is changed programmatically
    /// (a debug launch argument today), so the control follows the model.
    public var onDirectionChange: ((RelationshipDirection) -> Void)?
    /// Fires when a segment's title changes — today only when removing a
    /// follower decrements the viewer's own count.
    /// Fires when a segment title changes — the Friends count only becomes
    /// known once that tab has loaded, and removing a follower moves the
    /// Followers count.
    public var onSegmentTitlesChange: (([String]) -> Void)?
    public var onActionResult: ((ActionResult) -> Void)?

    private let subject: Subject
    private let repository: any ProfileRelationshipsProviding
    private let router: (any Router)?
    private let pageSize: Int32

    /// Per-direction state. A person can appear in both lists, so a follow
    /// toggle applies to every tab holding that row.
    private struct TabState {
        var relations: [ProfileRelation] = []
        var nextPageToken = ""
        var hasLoaded = false
        var isLoading = false
        var isAppending = false
        var failure: String?
        /// Set when the backend itself refuses the list, which outranks the
        /// client-side inference.
        var isForbidden = false
    }

    /// Built from `allCases`, not listed by hand: a direction with no entry
    /// here guards out of `loadIfNeeded` and reports `.loading` from `phase`
    /// forever, so a missing key is a tab that shows skeletons and never
    /// resolves — which is exactly what adding Friends to a hand-written pair
    /// produced.
    private var states: [RelationshipDirection: TabState] = Dictionary(
        uniqueKeysWithValues: RelationshipDirection.allCases.map { ($0, TabState()) }
    )
    public private(set) var direction: RelationshipDirection = .followers
    private var loads: [RelationshipDirection: Task<Void, Never>] = [:]
    /// Follow toggles in flight, so a double tap can't issue two commands.
    private var mutating: Set<ProfileID> = []
    /// The live search text. Filtering is client-side over the rows already
    /// loaded — the graph exposes no search-within-followers RPC, and a
    /// server round trip per keystroke would be the wrong shape for it anyway.
    private var query = ""
    /// Counts behind the segment titles. Followers and Following are seeded
    /// from the subject; Friends has no backend count at all (there is no
    /// mutuals RPC — `dev/BACKEND_GAPS.md` §13d) and is filled in from what
    /// the tab actually loads.
    private var counts: [RelationshipDirection: CountEstimate] = [:]
    public init(
        subject: Subject,
        repository: any ProfileRelationshipsProviding,
        router: (any Router)? = nil,
        direction: RelationshipDirection = .followers,
        pageSize: Int32 = 24
    ) {
        self.subject = subject
        self.repository = repository
        self.router = router
        self.direction = direction
        self.pageSize = pageSize
        counts = [.followers: subject.followerCount, .following: subject.followingCount]
    }

    /// Segment titles in `RelationshipDirection.allCases` order, each led by
    /// its count when one is known ("1.2K Followers").
    public var segmentTitles: [String] {
        RelationshipDirection.allCases.map(segmentTitle)
    }

    /// The same segments without their counts, for when the counted titles do
    /// not fit the navigation bar.
    ///
    /// Offered as an alternative rather than decided here: whether "12.4K
    /// Followers" fits is a question about a control's width on a particular
    /// device, which is the view's to answer, not the view model's.
    public var bareSegmentTitles: [String] {
        RelationshipDirection.allCases.map(Self.noun)
    }

    /// "1.2K Followers", or the bare noun when the count is unknown.
    ///
    /// A count the backend never answered degrades to "Followers" rather than
    /// showing "—  Followers", which reads as a broken string. Friends starts
    /// out unknown on every profile and gains its count when the tab loads.
    ///
    /// ⚠️ Three counted titles are wider than two, and this control is the
    /// navigation item's `titleView`. The width that makes them fit is set in
    /// `ProfileRelationshipsViewController` — changing the wording here can
    /// push a segment into truncation, and "35 Follow…" is indistinguishable
    /// from "12 Follow…".
    private func segmentTitle(for direction: RelationshipDirection) -> String {
        let noun = Self.noun(for: direction)
        guard let count = counts[direction], count != .unavailable else { return noun }
        return "\(ProfileDisplayModel.format(count)) \(noun)"
    }

    private static func noun(for direction: RelationshipDirection) -> String {
        switch direction {
        case .followers: return "Followers"
        case .following: return "Following"
        case .friends: return "Friends"
        }
    }

    /// The screen's title — the subject's `@handle`, matching the profile
    /// screen it was pushed from.
    public var title: String { "@" + subject.handle }

    /// Resolved once, from what the origin already knew. A `.private` answer
    /// means no request is ever issued for either list — the client does not
    /// ask a question it has decided it may not know the answer to.
    public private(set) lazy var access: RelationshipListAccess = .resolve(
        subjectVisibility: subject.visibility,
        viewerFollowsSubject: subject.viewerFollowsSubject,
        isSelf: subject.isSelf
    )

    // MARK: - Inputs

    public func viewDidLoad() {
        emit()
        loadIfNeeded(direction)
    }

    /// Segmented-control selection. Renders the tab's cached state
    /// immediately; a never-loaded tab starts its first page here.
    public func selectDirection(_ direction: RelationshipDirection) {
        guard direction != self.direction else { return }
        self.direction = direction
        emit()
        loadIfNeeded(direction)
    }

    /// Pull-to-refresh: the active tab only. The viewer's cached follow set is
    /// dropped too, so rows that were followed elsewhere in the app come back
    /// with the right action.
    public func refresh() {
        guard access == .visible else {
            emit() // ends the refresh control on a list that can't reload
            return
        }
        let direction = direction
        loads[direction]?.cancel()
        loads[direction] = nil
        states[direction]?.isLoading = false
        Task { [weak self] in
            await self?.repository.invalidateViewerCache()
            self?.load(direction, reset: true)
        }
    }

    /// Called as the end of the list comes into view.
    ///
    /// Suspended while a search is active: the filter runs over rows already in
    /// hand, so paging on behalf of a query would fetch pages the user can't
    /// see and, worse, make the visible result set grow on its own while they
    /// are reading it.
    /// Takes the direction explicitly: every list is mounted at once now, and
    /// the one that reached its end is not necessarily the one selected.
    public func loadNextPageIfNeeded(for direction: RelationshipDirection) {
        guard access == .visible, query.isEmpty, let state = states[direction] else { return }
        guard state.hasLoaded, !state.isLoading, !state.nextPageToken.isEmpty else { return }
        load(direction, reset: false)
    }

    /// Live search text from the bottom search bar. Filters the loaded rows of
    /// **both** tabs (the query survives a tab switch, which is what a bar that
    /// stays on screen across the switch implies).
    public func searchQueryChanged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        emit()
    }

    /// Case- and diacritic-insensitive match on display name or handle — so
    /// "sofia" finds "Sofía Reyes", which an exact match would not.
    private func matches(_ relation: ProfileRelation) -> Bool {
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return relation.displayName.range(of: query, options: options) != nil
            || relation.handle.range(of: query, options: options) != nil
    }

    /// A row tapped — open that profile. Route-only, like every other
    /// cross-surface jump in this feature; the stub pre-seeds the destination's
    /// navigation chrome from what this row already renders.
    public func rowTapped(_ profileID: ProfileID) {
        guard let relation = relation(for: profileID) else { return }
        router?.route(to: .profile(relation.id, stub: ProfileIdentityStub(
            handle: relation.handle,
            displayName: relation.displayName,
            // Meaningless for your own row — you neither follow nor don't
            // follow yourself — so it stays nil and `isSelf` carries the answer.
            isFollowing: relation.isViewer ? nil : relation.viewerFollows,
            // This list is the one surface that reliably knows: the repository
            // resolved the viewer's id to mark the row in the first place.
            isSelf: relation.isViewer
        )))
    }

    /// Follow / unfollow from a row. Optimistic, matching the profile header's
    /// own toggle: flip immediately, roll back if the server rejects.
    public func toggleFollow(_ profileID: ProfileID) {
        guard let relation = relation(for: profileID), !relation.isViewer else { return }
        guard !mutating.contains(profileID) else { return }

        let target = !relation.viewerFollows
        mutating.insert(profileID)
        applyFollow(target, to: profileID)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setFollowing(target, for: profileID)
            } catch {
                self.applyFollow(!target, to: profileID)
                self.onActionResult?(.failed(
                    message: target ? "Couldn't follow this profile." : "Couldn't unfollow this profile."
                ))
            }
            self.mutating.remove(profileID)
        }
    }

    /// Drop someone from the viewer's own follower list.
    ///
    /// NOT optimistic, for the reason `ProfileViewModel.block` isn't: the
    /// visible consequence is a row disappearing, and a row that vanishes and
    /// then reappears reads as the app having lost the user's instruction.
    public func removeFollower(_ profileID: ProfileID) {
        guard subject.isSelf, direction == .followers, repository.supportsFollowerRemoval else { return }
        guard !mutating.contains(profileID) else { return }
        mutating.insert(profileID)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.removeFollower(profileID)
                self.states[.followers]?.relations.removeAll { $0.id == profileID }
                // The segment title counts this list, so it has to follow the
                // list down — otherwise "142 Followers" sits above 141 of them.
                self.counts[.followers] = self.counts[.followers]?.adjusted(by: -1)
                self.onSegmentTitlesChange?(self.segmentTitles)
                self.emit()
            } catch {
                self.onActionResult?(.failed(message: "Couldn't remove this follower."))
            }
            self.mutating.remove(profileID)
        }
    }

    // MARK: - Loading

    private func loadIfNeeded(_ direction: RelationshipDirection) {
        guard access == .visible else { return }
        guard let state = states[direction], !state.hasLoaded, !state.isLoading else { return }
        load(direction, reset: true)
    }

    private func load(_ direction: RelationshipDirection, reset: Bool) {
        guard var state = states[direction], !state.isLoading else { return }
        let token = reset ? "" : state.nextPageToken
        state.isLoading = true
        state.isAppending = !reset
        if reset { state.failure = nil }
        states[direction] = state
        emit(for: direction)

        loads[direction] = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.repository.relationships(
                    for: self.subject.id,
                    direction: direction,
                    pageToken: token,
                    limit: self.pageSize
                )
                guard !Task.isCancelled else { return }
                self.apply(page, to: direction, reset: reset)
            } catch is CancellationError {
                // Superseded; leave the tab's state alone.
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.applyFailure(error, to: direction, reset: reset)
            }
            self.loads[direction] = nil
        }
    }

    private func apply(_ page: RelationshipPage, to direction: RelationshipDirection, reset: Bool) {
        guard var state = states[direction] else { return }
        if reset {
            state.relations = page.relations
        } else {
            // Defensive de-duplication: a cursor that overlaps (or a row the
            // viewer followed between pages) must not produce a duplicate
            // identifier, which a diffable snapshot treats as a crash.
            let known = Set(state.relations.map(\.id))
            state.relations.append(contentsOf: page.relations.filter { !known.contains($0.id) })
        }
        state.nextPageToken = page.nextPageToken
        state.hasLoaded = true
        state.isLoading = false
        state.isAppending = false
        state.failure = nil
        states[direction] = state
        // Friends is the one tab whose count has no other source, so it is
        // taken from the rows in hand: exact once the cursor is spent, "n+"
        // while pages remain. Followers and Following keep the subject's own
        // numbers — those are the whole list's size, not the part loaded.
        if direction == .friends {
            let updated = CountEstimate.fromSample(
                count: state.relations.count, hasMore: !state.nextPageToken.isEmpty
            )
            if counts[.friends] != updated {
                counts[.friends] = updated
                onSegmentTitlesChange?(segmentTitles)
            }
        }
        emit(for: direction)
    }

    private func applyFailure(_ error: Error, to direction: RelationshipDirection, reset: Bool) {
        guard var state = states[direction] else { return }
        state.isLoading = false
        state.isAppending = false
        if case RelationshipsError.forbidden = error {
            // The backend refused: it outranks whatever the client inferred,
            // and the screen shows the private state, not a retry.
            state.isForbidden = true
            state.hasLoaded = true
            state.relations = []
        } else if reset {
            state.failure = "Couldn't load this list. Pull to retry."
        }
        // A failed *append* keeps the rows already on screen and simply stops
        // paging; the cursor is left in place so scrolling can retry.
        states[direction] = state
        emit(for: direction)
    }

    // MARK: - Output

    /// Publishes one direction's phase, or every direction's when unqualified.
    ///
    /// No longer filtered to the active tab. All three lists are mounted in a
    /// pager, so each one owns a page that must show its own state — the tab
    /// you are about to swipe to has to be right *before* it arrives, not once
    /// it settles.
    private func emit(for direction: RelationshipDirection? = nil) {
        for target in direction.map({ [$0] }) ?? RelationshipDirection.allCases {
            onPhaseChange?(target, phase(for: target))
        }
    }

    /// The rendering state of one list.
    public func phase(for direction: RelationshipDirection) -> Phase {
        guard let state = states[direction] else { return .loading }
        if access == .private || state.isForbidden {
            return .restricted(
                title: Self.restrictedTitle(for: direction),
                message: restrictedMessage(for: direction)
            )
        }
        if let failure = state.failure, state.relations.isEmpty {
            return .failed(message: failure)
        }
        if !state.hasLoaded {
            return .loading
        }
        guard !state.relations.isEmpty else {
            return .empty(
                title: Self.emptyTitle(for: direction),
                message: emptyMessage(for: direction)
            )
        }
        let visible = state.relations.filter(matches)
        guard !visible.isEmpty else {
            // A no-results state names the query, not the list: the list is
            // fine, the search just didn't hit anything in it.
            return .empty(
                title: "No Results",
                message: "No one in this list matches “\(query)”."
            )
        }
        // The paging spinner belongs to the unfiltered list; showing it under a
        // filtered result would promise more matches are coming.
        return .content(rows: visible.map(row), isAppending: state.isAppending && query.isEmpty)
    }

    private func row(for relation: ProfileRelation) -> Row {
        Row(
            id: relation.id,
            displayName: relation.displayName,
            handle: "@" + relation.handle,
            monogram: Self.monogram(for: relation),
            avatarURL: relation.avatarURL,
            isVerified: relation.isVerified,
            action: action(for: relation),
            isViewer: relation.isViewer
        )
    }

    /// The viewer's own row never offers an action. On the viewer's own
    /// followers list a *removable* follower gets Remove — the destructive
    /// action outranks Follow there, because "who can see my posts" is the
    /// decision that list exists to serve. Everywhere else it's the follow
    /// toggle.
    private func action(for relation: ProfileRelation) -> RowAction {
        if relation.isViewer { return .inert }
        if subject.isSelf, direction == .followers, repository.supportsFollowerRemoval {
            return .remove
        }
        return relation.viewerFollows ? .following : .follow
    }

    /// Initials for the identity disc: first letters of the display name's
    /// first two words, falling back to the handle.
    private static func monogram(for relation: ProfileRelation) -> String {
        let source = relation.displayName.isEmpty ? relation.handle : relation.displayName
        let initials = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
            .prefix(2)
            .compactMap(\.first)
        return initials.isEmpty
            ? String(source.prefix(1)).uppercased()
            : String(initials).uppercased()
    }

    // MARK: - Copy

    private static func restrictedTitle(for direction: RelationshipDirection) -> String {
        switch direction {
        case .followers: "Followers Are Private"
        case .following: "Following Is Private"
        case .friends: "Friends Are Private"
        }
    }

    private func restrictedMessage(for direction: RelationshipDirection) -> String {
        let list = switch direction {
        case .followers: "follower list"
        case .following: "following list"
        // The friends list is derived from the other two, so a refusal on
        // either surfaces here — naming it after the tab keeps the sentence
        // true whichever side was withheld.
        case .friends: "friends list"
        }
        return "@\(subject.handle)'s \(list) is private. Follow them to see it."
    }

    private static func emptyTitle(for direction: RelationshipDirection) -> String {
        switch direction {
        case .followers: "No Followers Yet"
        case .following: "Not Following Anyone"
        case .friends: "No Friends Yet"
        }
    }

    private func emptyMessage(for direction: RelationshipDirection) -> String {
        switch (direction, subject.isSelf) {
        case (.followers, true): "When someone follows you, they'll show up here."
        case (.followers, false): "@\(subject.handle) doesn't have any followers yet."
        case (.following, true): "Profiles you follow will show up here."
        case (.following, false): "@\(subject.handle) isn't following anyone yet."
        // "Friend" is mutual by definition, so the empty state has to say what
        // makes one rather than leaving it to be inferred from the tab.
        case (.friends, true): "People you follow who follow you back will show up here."
        case (.friends, false): "@\(subject.handle) doesn't follow anyone back yet."
        }
    }

    // MARK: - Row state

    private func relation(for profileID: ProfileID) -> ProfileRelation? {
        states[direction]?.relations.first { $0.id == profileID }
    }

    /// Applies a follow state to EVERY tab holding this person — the same
    /// profile routinely appears in both lists, and leaving the other tab's
    /// copy stale would show two different answers for one relationship.
    private func applyFollow(_ following: Bool, to profileID: ProfileID) {
        for key in states.keys {
            guard let index = states[key]?.relations.firstIndex(where: { $0.id == profileID }) else { continue }
            states[key]?.relations[index].viewerFollows = following
        }
        emit()
    }

    // MARK: - Debug hooks

    #if DEBUG
    /// Selects a direction from a launch argument, mirroring the change back to
    /// the segmented control — the simulator can't tap it.
    public func qaSelectDirection(_ direction: RelationshipDirection) {
        selectDirection(direction)
        onDirectionChange?(direction)
    }

    /// Selects the viewer's own "(Me)" row, as a tap on it would.
    public func qaOpenSelfRow() {
        guard let relation = states[direction]?.relations.first(where: \.isViewer) else { return }
        rowTapped(relation.id)
    }

    /// Fires the first row's trailing action, whatever it currently is.
    ///
    /// Runs the command for real — including the removal's graph write — and
    /// skips only the confirmation sheet, which needs a tap the simulator
    /// can't deliver. Same bargain as `-profile-block-demo`.
    public func qaActivateFirstRowAction() {
        guard let relation = states[direction]?.relations.first(where: { !$0.isViewer }) else { return }
        switch action(for: relation) {
        case .remove: removeFollower(relation.id)
        case .follow, .following: toggleFollow(relation.id)
        case .inert: break
        }
    }
    #endif
}
