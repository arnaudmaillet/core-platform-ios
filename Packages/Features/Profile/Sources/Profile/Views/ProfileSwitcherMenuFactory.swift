import CoreModels
import DesignSystem
import MediaCore
import ProfileInterface
import UIKit

/// THE profile switcher (#2034), the same component on every surface — the
/// Profile tab's hold, the profile screen's toolbar, Settings, the comment
/// composer (`ProfileSwitcherMenuController`).
///
/// `reload` (an async fetch) pre-formats every row into ready strings,
/// pre-decodes its rounded avatar and reads its unread count, so the
/// switcher opens complete on its first frame — no image work, no fetch at
/// opening time.
@MainActor
final class ProfileSwitcherMenuFactory: ProfileSwitcherPresenting {
    private let switching: any ProfileSwitching
    private let imagePipeline: ImagePipeline
    /// One profile's unread notifications (#2034), nil when it can't be read.
    private let unreadCount: (@MainActor @Sendable (ProfileID) async -> Int?)?
    /// Every profile's, as last read.
    private(set) var unreadCounts: [ProfileID: Int] = [:]

    /// A pre-built row: nothing here is computed at menu-build time.
    private struct Row {
        let id: ProfileID
        let title: String
        let image: UIImage?
        let isActive: Bool
    }
    private var rows: [Row] = []

    init(
        switching: any ProfileSwitching,
        imagePipeline: ImagePipeline,
        unreadCount: (@MainActor @Sendable (ProfileID) async -> Int?)? = nil
    ) {
        self.switching = switching
        self.imagePipeline = imagePipeline
        self.unreadCount = unreadCount
    }

    /// Fetches the account's profiles and pre-builds every row (strings + rounded
    /// avatar, unread count), so the switcher opens complete.
    func reload() async {
        let profiles = (try? await switching.accountProfiles()) ?? []
        let activeID = await switching.activeProfileID()
        // The counts with the avatars, in parallel (#2034).
        async let counts = Self.counts(for: profiles.map(\.id), reading: unreadCount)
        var loaded: [Row] = []
        for profile in profiles {
            loaded.append(Row(
                id: profile.id,
                title: profile.displayName,
                image: await thumbnail(for: profile.avatarURL),
                isActive: profile.id == activeID
            ))
        }
        rows = loaded
        unreadCounts = await counts
    }

    func reloadUnreadCounts() async {
        let ids: [ProfileID]
        if rows.isEmpty {
            ids = ((try? await switching.accountProfiles()) ?? []).map(\.id)
        } else {
            ids = rows.map(\.id)
        }
        unreadCounts = await Self.counts(for: ids, reading: unreadCount)
    }

    /// Every profile's unread count at once; the ones that could not be read
    /// are left out.
    private static func counts(
        for ids: [ProfileID], reading read: (@MainActor @Sendable (ProfileID) async -> Int?)?
    ) async -> [ProfileID: Int] {
        guard let read else { return [:] }
        return await withTaskGroup(of: (ProfileID, Int?).self) { group in
            for id in ids { group.addTask { (id, await read(id)) } }
            var counts: [ProfileID: Int] = [:]
            for await (id, count) in group { if let count { counts[id] = count } }
            return counts
        }
    }

    /// The switcher's sections from the last `reload`, in the ONE order every
    /// surface shows (#2034): the other profiles, then the active one and
    /// "Add Profile" — never flipped for a source at the bottom.
    func sections(includesAddProfile: Bool) -> [[ProfileSwitcherItem]] {
        func item(_ row: Row) -> ProfileSwitcherItem {
            ProfileSwitcherItem(
                kind: .profile(row.id, isActive: row.isActive), title: row.title,
                image: row.image, count: unreadCounts[row.id]
            )
        }
        var active = rows.filter(\.isActive).map(item)
        if includesAddProfile {
            active.append(ProfileSwitcherItem(kind: .addProfile, title: "Add Profile", image: nil, count: nil))
        }
        return [rows.filter { !$0.isActive }.map(item), active]
    }

    func present(
        from source: ProfileSwitcherSource,
        over presenter: UIViewController,
        includesAddProfile: Bool,
        onSwitch: @escaping () -> Void,
        onAddProfile: @escaping () -> Void
    ) {
        _ = open(from: source, over: presenter, includesAddProfile: includesAddProfile,
                 onSwitch: onSwitch, onAddProfile: onAddProfile)
    }

    func beginTracking(
        from source: UIView,
        over presenter: UIViewController,
        includesAddProfile: Bool,
        onSwitch: @escaping () -> Void,
        onAddProfile: @escaping () -> Void
    ) -> (any ProfileSwitcherTracking)? {
        let menu = open(from: .view(source), over: presenter, includesAddProfile: includesAddProfile,
                        onSwitch: onSwitch, onAddProfile: onAddProfile)
        // The hold's own beat, as a system menu lifting under the finger.
        if menu != nil { Haptics.play(.held) }
        return menu
    }

    private func open(
        from source: ProfileSwitcherSource,
        over presenter: UIViewController,
        includesAddProfile: Bool,
        onSwitch: @escaping () -> Void,
        onAddProfile: @escaping () -> Void
    ) -> ProfileSwitcherMenuController? {
        let sections = sections(includesAddProfile: includesAddProfile)
        guard sections.contains(where: { !$0.isEmpty }), presenter.presentedViewController == nil else { return nil }
        let menu = ProfileSwitcherMenuController(
            sections: sections,
            sourceRect: { [weak presenter] in Self.frame(of: source, in: presenter?.view.window) },
            onPick: { [weak self] item in
                switch item.kind {
                case .profile(let id, let isActive):
                    guard !isActive else { return }
                    self?.commitSwitch(to: id, then: onSwitch)
                case .addProfile:
                    onAddProfile()
                }
            }
        )
        presenter.present(menu, animated: false)
        return menu
    }

    /// Where `source` stands, in window coordinates.
    private static func frame(of source: ProfileSwitcherSource, in window: UIWindow?) -> CGRect? {
        switch source {
        case .view(let view):
            return view.window.map { view.convert(view.bounds, to: $0) }
        case .barItem(let item):
            guard let window else { return nil }
            return item.frame(in: window)
        }
    }

    /// Switches the active profile, broadcasts the change (so identity chrome
    /// like the map avatar refreshes), then runs the caller's `onSwitch`.
    private func commitSwitch(to id: ProfileID, then onSwitch: @escaping () -> Void) {
        Task { @MainActor in
            await switching.setActiveProfile(id)
            // The id rides along so observers can render that profile from
            // cache on this very turn, rather than waiting to be told who it
            // is by a round trip.
            NotificationCenter.default.post(
                name: .activeProfileDidChange,
                object: nil,
                userInfo: [ActiveProfileChange.profileIDKey: id]
            )
            onSwitch()
        }
    }

    /// A small circular avatar for a menu row (or nil). Rendered `.alwaysOriginal`
    /// so the photo shows through the menu's tinting (incl. the active row's red).
    private func thumbnail(for url: URL?) async -> UIImage? {
        guard let url, let image = try? await imagePipeline.image(for: url, size: .avatar) else { return nil }
        // Aspect-filled, never squeezed into the square (#1339).
        return image.circularThumbnail(side: 36)
    }
}
