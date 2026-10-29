import CoreModels
import CoreNavigation
import CoreNetworking
import Foundation

/// The follow half a contact row needs: follow (or ask a private profile),
/// unfollow, withdraw a request, and where the viewer stands — the same
/// writers every other follow button goes through, so the app's follow
/// channel (`FollowGraphEvents`) hears every change made here.
public typealias ContactFollowing = FollowRequestSending & SocialGraphReading & SocialGraphWriting

/// Find Friends from Contacts (#412, `FindProfilesByContacts`, backend #806):
/// reads the address book once access is given, sends only SHA-256 hashes of
/// normalized identifiers, and lists the profiles found with a follow button.
@MainActor
public final class ContactFriendsViewModel {
    public enum Phase: Equatable, Sendable {
        /// Nothing decided yet (the first frame).
        case idle
        /// Never asked: the screen explains before iOS asks.
        case needsPermission
        /// Access refused: only Settings can change it.
        case denied
        case loading
        /// What was found; empty is the "none of your contacts" state.
        /// `isLimited`: the person shared only some contacts.
        case loaded(rows: [Row], isLimited: Bool)
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        /// The lookup never got an answer, or got a fault. `nil` when it
        /// did not come from the network.
        case network(NetworkFailure?)
        /// ACC-7007: the day's lookups are used up.
        case dailyLimit
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: ProfileID
        public let displayName: String
        /// Without the `@`.
        public let handle: String
        /// The name the viewer gave the contact, when it says more than the
        /// profile's own name.
        public let contactName: String?
        public let avatarURL: URL?
        public var relation: FollowRelation
    }

    public var onChange: (() -> Void)?
    /// A follow, unfollow or withdrawal that didn't happen: the screen says
    /// so through `Feedback`.
    public var onActionFailed: ((String) -> Void)?

    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onChange?() } }
    }

    private let book: any ContactBookReading
    private let finder: any ContactProfileFinding
    private let following: any ContactFollowing
    private let router: (any Router)?
    private let region: String?
    private var busy: Set<ProfileID> = []
    private var followSubscription: FollowGraphSubscription?
    private var loadTask: Task<Void, Never>?

    /// - Parameter region: the region a number written without its country
    ///   code is read in; the device's by default.
    public init(
        book: any ContactBookReading = SystemContactBook(),
        finder: any ContactProfileFinding,
        following: any ContactFollowing,
        router: (any Router)? = nil,
        followEvents: FollowGraphEvents? = nil,
        region: String? = Locale.current.region?.identifier
    ) {
        self.book = book
        self.finder = finder
        self.following = following
        self.router = router
        self.region = region
        // A follow made anywhere else (the profile this list opened) shows
        // on its row when the viewer comes back.
        followSubscription = followEvents?.subscribeOnMain { [weak self] change in
            self?.update(change.profileID) { $0.relation = $0.relation.settingFollow(change.isFollowing) }
        }
    }

    public func isBusy(_ profileID: ProfileID) -> Bool { busy.contains(profileID) }

    /// Where the screen starts: the explanation, the refusal, or the list.
    public func start() {
        switch book.access() {
        case .notDetermined: phase = .needsPermission
        case .denied: phase = .denied
        case .limited, .authorized: load()
        }
    }

    /// The pre-prompt's Continue: iOS asks, then the list or the refusal.
    public func allowAccess() {
        Task { [weak self] in
            guard let self else { return }
            switch await book.requestAccess() {
            case .notDetermined, .denied: phase = .denied
            case .limited, .authorized: load()
            }
        }
    }

    /// Back from iOS Settings: access may have changed either way.
    public func accessMayHaveChanged() {
        let access = book.access()
        switch (phase, access) {
        case (.denied, .limited), (.denied, .authorized), (.needsPermission, .limited), (.needsPermission, .authorized):
            load()
        case (.loaded(_, let isLimited), .authorized) where isLimited:
            load()
        case (.loaded(_, let isLimited), .limited) where !isLimited:
            load()
        case (.loaded, .denied), (.failed, .denied):
            phase = .denied
        default:
            break
        }
    }

    public func retry() { load() }

    public func load() {
        loadTask?.cancel()
        phase = .loading
        let isLimited = book.access() == .limited
        loadTask = Task { [weak self, book, finder, following, region] in
            let outcome: Result<[Row], ContactFriendsLookupError>
            do {
                let entries = try await book.entries()
                outcome = .success(try await Self.lookUp(entries, region: region, finder: finder, following: following))
            } catch let error as ContactFriendsLookupError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.other(error))
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let rows): phase = .loaded(rows: rows, isLimited: isLimited)
            case .failure(.dailyLimit): phase = .failed(.dailyLimit)
            case .failure(.other(let error)): phase = .failed(.network(NetworkFailure.of(error)))
            }
        }
    }

    enum ContactFriendsLookupError: Error {
        case dailyLimit
        case other(any Error)
    }

    /// Hashes, asks in pages of the contract's cap, and builds the rows.
    /// A daily limit hit after some pages keeps what they found.
    nonisolated static func lookUp(
        _ entries: [ContactEntry], region: String?,
        finder: any ContactProfileFinding, following: any ContactFollowing
    ) async throws -> [Row] {
        let request = ContactHashes(entries, region: region)
        var matches: [ContactProfileMatch] = []
        for page in request.pages(of: ContactLookupLimits.maxHashesPerCall) {
            do {
                matches += try await finder.findProfiles(emailHashes: page.emails, phoneHashes: page.phones)
            } catch ContactMatchError.dailyLimitReached {
                if matches.isEmpty { throw ContactFriendsLookupError.dailyLimit }
                break
            }
        }
        // One row per profile: a contact matched by both its email and its
        // phone, or two contacts of the same person, is still one person.
        var seen: Set<ProfileID> = []
        let unique = matches.filter { seen.insert($0.profileID).inserted }
        let relations = await withTaskGroup(of: (ProfileID, FollowRelation).self) { group in
            for match in unique {
                group.addTask {
                    // Unknown reads as Follow: a tap on someone already
                    // followed corrects itself.
                    let relation = (try? await following.followRelation(to: match.profileID)) ?? .notFollowing
                    return (match.profileID, relation)
                }
            }
            var answered: [ProfileID: FollowRelation] = [:]
            for await (id, relation) in group { answered[id] = relation }
            return answered
        }
        let rows: [Row] = unique.compactMap { match in
            let relation = relations[match.profileID] ?? .notFollowing
            // The server leaves out the viewer's own and anyone blocked
            // either way; a block placed since is honoured here too.
            guard relation != .viewer, relation != .blocked else { return nil }
            let contact = request.names[match.contactHash]
            let displayName = match.displayName.isEmpty ? match.handle : match.displayName
            return Row(
                id: match.profileID,
                displayName: displayName,
                handle: match.handle,
                contactName: contact.flatMap { $0.isEmpty || $0 == displayName ? nil : $0 },
                avatarURL: match.avatarURL,
                relation: relation
            )
        }
        return rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Rows

    public func rowTapped(_ profileID: ProfileID) {
        guard let row = currentRow(profileID) else { return }
        router?.route(to: .profile(row.id, stub: ProfileIdentityStub(
            handle: row.handle, displayName: row.displayName, isFollowing: row.relation.isFollowing, isSelf: false
        )))
    }

    /// The row's button: Follow (or ask), Unfollow, or withdraw the request.
    ///
    /// Follow is NOT optimistic, like the followers list's (#726): the
    /// button changes once, to the server's answer — Following, or Requested
    /// for a private profile. Unfollow and withdraw are, and come back on a
    /// failure.
    /// Answers whether the tap turned the follow ON (a request counts): the
    /// view plays `toggleOn` then (#1886).
    @discardableResult
    public func toggleFollow(_ profileID: ProfileID) -> Bool {
        guard let row = currentRow(profileID), !busy.contains(profileID) else { return false }
        let handle = "@" + row.handle
        let relation = row.relation
        switch relation {
        case .viewer, .blocked:
            return false
        case .notFollowing, .followedBy:
            busy.insert(profileID)
            onChange?()
            Task { [weak self, following] in
                let outcome = try? await following.follow(profileID)
                guard let self else { return }
                busy.remove(profileID)
                switch outcome {
                case .following: update(profileID) { $0.relation = $0.relation.settingFollow(true) }
                case .requested: update(profileID) { $0.relation = .requested }
                case nil:
                    onChange?()
                    onActionFailed?("Couldn't follow \(handle)")
                }
            }
            return true
        case .following, .mutual:
            busy.insert(profileID)
            update(profileID) { $0.relation = relation.settingFollow(false) }
            Task { [weak self, following] in
                let failed = (try? await following.setFollowing(false, for: profileID)) == nil
                guard let self else { return }
                busy.remove(profileID)
                if failed {
                    update(profileID) { $0.relation = relation }
                    onActionFailed?("Couldn't unfollow \(handle)")
                } else {
                    onChange?()
                }
            }
            return false
        case .requested:
            busy.insert(profileID)
            update(profileID) { $0.relation = .notFollowing }
            Task { [weak self, following] in
                let failed = (try? await following.cancelFollowRequest(to: profileID)) == nil
                guard let self else { return }
                busy.remove(profileID)
                if failed {
                    update(profileID) { $0.relation = .requested }
                    onActionFailed?("Couldn't withdraw your request")
                } else {
                    onChange?()
                }
            }
            return false
        }
    }

    private func currentRow(_ profileID: ProfileID) -> Row? {
        guard case .loaded(let rows, _) = phase else { return nil }
        return rows.first { $0.id == profileID }
    }

    private func update(_ profileID: ProfileID, _ change: (inout Row) -> Void) {
        guard case .loaded(var rows, let isLimited) = phase,
              let index = rows.firstIndex(where: { $0.id == profileID }) else { return }
        change(&rows[index])
        phase = .loaded(rows: rows, isLimited: isLimited)
    }
}

/// An address book turned into what the contract takes: unique SHA-256
/// hashes of normalized emails and E.164 numbers, and the contact name each
/// hash came from — which never leaves the device.
struct ContactHashes: Sendable {
    private(set) var emails: [Data] = []
    private(set) var phones: [Data] = []
    private(set) var names: [Data: String] = [:]

    init(_ entries: [ContactEntry], region: String?) {
        var seen: Set<Data> = []
        for entry in entries {
            for email in entry.emails.compactMap(ContactIdentifiers.normalizedEmail) {
                let hash = ContactIdentifiers.hash(email)
                if seen.insert(hash).inserted { emails.append(hash); names[hash] = entry.name }
            }
            for phone in entry.phones.compactMap({ ContactIdentifiers.normalizedPhone($0, region: region) }) {
                let hash = ContactIdentifiers.hash(phone)
                if seen.insert(hash).inserted { phones.append(hash); names[hash] = entry.name }
            }
        }
    }

    /// The hashes in calls of at most `size`, emails and phones together.
    func pages(of size: Int) -> [(emails: [Data], phones: [Data])] {
        let all: [(hash: Data, isEmail: Bool)] = emails.map { ($0, true) } + phones.map { ($0, false) }
        return stride(from: 0, to: all.count, by: size).map { start in
            let slice = all[start..<min(start + size, all.count)]
            return (emails: slice.filter(\.isEmail).map(\.hash), phones: slice.filter { !$0.isEmail }.map(\.hash))
        }
    }
}
