import CoreModels
import Foundation

/// Where every screen reads whether the viewer saved a post, in memory: the
/// app's `EntityStore` (#896), whose saved fact is viewer-scoped (wiped on a
/// viewer change) and observed, so a save made on one screen re-draws the
/// glyph on every other. Declared here because the store depends on this
/// package, not the other way round.
public protocol PostSaveFacts: AnyObject, Sendable {
    /// Whether the viewer saved the post; nil while not known.
    func isSaved(_ id: PostID) -> Bool?
    func setSaved(_ isSaved: Bool, for id: PostID)
}

/// The posts the viewer has saved.
///
/// **Client-side, and that is the whole truth rather than a stand-in for it.**
/// No wire contract for saving exists — `engagement.v1` carries reactions,
/// views and shares and nothing else, and no service anywhere accepts a "saved
/// by" predicate — so there is no server answer this could disagree with. That
/// is the same footing `MapFavoritesStore` stands on for the map's pinned
/// profiles, and this follows its shape deliberately.
///
/// ⚠️ It also means what this is NOT. A saved list that lives on the device
/// does not follow the viewer to another one and does not survive deleting the
/// app. When a real seam arrives, this becomes a local cache in front of it and
/// the reconciliation is the interesting part — a post saved here while offline
/// has to be pushed, and one saved elsewhere has to arrive. Nothing here
/// pretends that work is done.
///
/// Order is preserved and most-recent-first, because a saved list is read as a
/// pile rather than as a set: the thing you saved a minute ago is the thing you
/// came back for.
///
/// **A view over the EntityStore's saved fact (#896).** One instance in the app
/// (`shared`), handed the store as its `facts`: a save writes the pile — the
/// device's record and its order — and then the fact, which every screen
/// observes; a read asks the fact first, the pile when the fact is unknown.
/// The pile stays the persistence: the fact is memory, bounded and wiped on a
/// viewer change. When #837 lands (engagement's SavePost / ListSavedPosts),
/// this becomes the cache in front of the server that it describes — the
/// server's list fills the pile and the fact, a toggle writes through — and
/// the screens keep reading the fact as they do now.
public final class PostBookmarkStore: @unchecked Sendable {
    /// The app's one pile: every surface reads and writes it, so the facts it
    /// writes are the ones every screen observes. The app hands it the
    /// EntityStore (`facts`) at launch.
    public static let shared = PostBookmarkStore()

    private static let baseKey = "profile.savedPostIDs"
    private let defaults: UserDefaults
    /// Whose pile: the active profile's (`StorageScope`).
    private let scope: StorageScope
    private var key: String { scope.profileKey(Self.baseKey, adoptingLegacyIn: defaults) }
    private let lock = NSLock()
    /// The in-memory saved fact every screen observes (the app's
    /// `EntityStore`). Nil: the pile alone answers.
    private var _facts: (any PostSaveFacts)?
    /// Whose pile the facts were last written from: a fact written for
    /// another profile (between a switch and the store's wipe) is never read.
    private var factsOwner: String?

    public var facts: (any PostSaveFacts)? {
        get { lock.withLock { _facts } }
        set { lock.withLock { _facts = newValue; factsOwner = nil } }
    }

    /// Fires after every change, on whatever thread made it — the profile's
    /// Saved tab reloads from this rather than polling.
    public var onChange: (() -> Void)?

    public convenience init(defaults: UserDefaults = .standard, scope: StorageScope = .shared) {
        self.init(defaults: defaults, scope: scope, launchArguments: ProcessInfo.processInfo.arguments)
    }

    /// - Parameter launchArguments: where the DEBUG QA hooks read
    ///   `-reset-bookmarks` and `-seed-bookmarks` (the process's, outside
    ///   tests). Ignored in Release.
    init(defaults: UserDefaults, scope: StorageScope, launchArguments: [String]) {
        self.defaults = defaults
        self.scope = scope
        #if DEBUG
        armLaunchHooks(launchArguments)
        #endif
    }

    #if DEBUG
    deinit {
        if let observer = launchHooksObserver { NotificationCenter.default.removeObserver(observer) }
    }
    #endif

    /// Most recently saved first.
    public var savedPostIDs: [String] {
        lock.withLock { defaults.array(forKey: key) as? [String] ?? [] }
    }

    public func isSaved(_ id: String) -> Bool {
        let (pile, memory, owner) = lock.withLock { (key, _facts, factsOwner) }
        if owner == pile, let known = memory?.isSaved(PostID(id)) { return known }
        return lock.withLock { (defaults.array(forKey: pile) as? [String] ?? []).contains(id) }
    }

    /// Saves, or unsaves if it was already there, and reports which it did.
    ///
    /// Returns the new state rather than nothing, because every caller so far
    /// needs it immediately: the glyph flips from it.
    @discardableResult
    public func toggle(_ id: String) -> Bool {
        let (saved, memory): (Bool, (any PostSaveFacts)?) = lock.withLock {
            let pile = key
            var ids = defaults.array(forKey: pile) as? [String] ?? []
            let saved: Bool
            if let existing = ids.firstIndex(of: id) {
                ids.remove(at: existing)
                saved = false
            } else {
                // Front, not back: newest first is how the pile reads.
                ids.insert(id, at: 0)
                saved = true
            }
            defaults.set(ids, forKey: pile)
            factsOwner = pile
            return (saved, _facts)
        }
        // Outside the lock: the store calls its observers, which read back.
        memory?.setSaved(saved, for: PostID(id))
        onChange?()
        return saved
    }

    // MARK: - DEBUG launch hooks

    #if DEBUG
    /// What the launch asked of the pile, until the scope says whose it is.
    private struct LaunchHooks {
        /// `-reset-bookmarks`: deterministic QA, so a scripted launch always
        /// starts from an empty pile. The map's favorites store carries the
        /// same hook for the same reason.
        var reset: Bool
        /// `-seed-bookmarks a,b,c`: a pile without having to save three posts
        /// by hand first. The Saved tab is otherwise empty on a fresh install,
        /// which is exactly the state that cannot show whether it renders.
        var seed: [String]?
    }

    private var pendingLaunchHooks: LaunchHooks?
    private var launchHooksObserver: NSObjectProtocol?

    /// ⚠️ NOT AT INIT (#1074): the app's one pile (`shared`) is made before
    /// the viewer is known, while the scope is still unscoped, and a reset
    /// there cleared the original key — never the member's pile. The hooks
    /// wait for the scope to name a viewer — a guest, or a member whose
    /// active profile resolved — and run once, for that pile: a later
    /// profile switch in the same launch resets nothing.
    private func armLaunchHooks(_ arguments: [String]) {
        let seed: [String]? = arguments.firstIndex(of: "-seed-bookmarks").flatMap { index in
            arguments.indices.contains(index + 1)
                ? arguments[index + 1].split(separator: ",").map(String.init)
                : nil
        }
        let hooks = LaunchHooks(reset: arguments.contains("-reset-bookmarks"), seed: seed)
        guard hooks.reset || hooks.seed != nil else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: StorageScope.didChangeNotification, object: scope, queue: nil
        ) { [weak self] _ in
            self?.runLaunchHooksIfViewerKnown()
        }
        lock.withLock {
            pendingLaunchHooks = hooks
            launchHooksObserver = observer
        }
        runLaunchHooksIfViewerKnown()
    }

    private func runLaunchHooksIfViewerKnown() {
        switch scope.owner {
        case .guest, .member(_, _?): break
        case .unscoped, .member(_, nil): return
        }
        // Taken under the lock, so a change racing this one runs nothing twice.
        typealias Run = (hooks: LaunchHooks, cleared: [String], memory: (any PostSaveFacts)?, done: NSObjectProtocol?)
        let run: Run? = lock.withLock {
            guard let hooks = pendingLaunchHooks else { return nil }
            pendingLaunchHooks = nil
            let done = launchHooksObserver
            launchHooksObserver = nil
            let pile = key
            var cleared: [String] = []
            if hooks.reset {
                cleared = defaults.array(forKey: pile) as? [String] ?? []
                defaults.removeObject(forKey: pile)
            }
            if let seed = hooks.seed { defaults.set(seed, forKey: pile) }
            factsOwner = pile
            return (hooks, cleared, _facts, done)
        }
        guard let run else { return }
        if let done = run.done { NotificationCenter.default.removeObserver(done) }
        // The saved facts every screen observes say it too: a glyph drawn
        // from a fact already in memory re-draws empty (or seeded).
        let seeded = Set(run.hooks.seed ?? [])
        for id in run.cleared where !seeded.contains(id) {
            run.memory?.setSaved(false, for: PostID(id))
        }
        for id in seeded {
            run.memory?.setSaved(true, for: PostID(id))
        }
        onChange?()
    }
    #endif
}
