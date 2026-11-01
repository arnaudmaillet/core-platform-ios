import CoreModels
import DesignSystem
import MediaCore
import ProfileInterface
import UIKit

/// The reusable profile switcher, shared by the profile header's switcher bar
/// button and the map avatar's long-press context menu — both build the exact
/// same `UIMenu`.
///
/// `reload` (an async fetch) pre-formats every row into ready strings AND
/// pre-decodes its rounded avatar `UIImage`. `makeMenu` is then **fully
/// synchronous**: each `UIAction(title:subtitle:image:)` is assembled complete
/// in one pass — no deferred element, no async, no image work at build time —
/// so title, subtitle, and avatar all render together in the menu's first frame.
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
    /// avatar), so subsequent `makeMenu` calls are synchronous.
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

    /// A synchronous switcher `UIMenu` from the pre-built rows, in the Telegram
    /// two-section shape: inactive profiles up top, then an inline section with
    /// the active profile and "Add Profile". Just avatar + display name, all in
    /// standard `.label` — the section split marks the active one, no checkmark
    /// or accent color.
    func makeMenu(
        includesAddProfile: Bool,
        onSwitch: @escaping () -> Void,
        onAddProfile: @escaping () -> Void
    ) -> UIMenu {
        func action(for row: Row) -> UIAction {
            UIAction(title: row.title, image: row.image) { [weak self] _ in
                self?.commitSwitch(to: row.id, then: onSwitch)
            }
        }

        // Section 1: the other profiles you can switch to.
        let inactive = rows.filter { !$0.isActive }.map(action(for:))
        let inactiveSection = UIMenu(title: "", options: .displayInline, children: inactive)

        // Section 2: the active profile, then Add Profile — unless the caller
        // is a switch-only surface with nowhere to send that row.
        var activeAndActions: [UIMenuElement] = rows.filter(\.isActive).map(action(for:))
        if includesAddProfile {
            activeAndActions.append(UIAction(
                title: "Add Profile",
                image: UIImage(systemName: "person.badge.plus")
            ) { _ in onAddProfile() })
        }
        let activeSection = UIMenu(title: "", options: .displayInline, children: activeAndActions)

        return UIMenu(title: "", children: [inactiveSection, activeSection])
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
