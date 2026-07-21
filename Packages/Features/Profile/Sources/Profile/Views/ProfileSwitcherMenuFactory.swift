import CoreModels
import MediaCore
import ProfileInterface
import UIKit

/// The reusable profile switcher: lists the account's profiles (rounded avatar +
/// name), marks the active one, and offers "Add Profile". Shared by the profile
/// header's switcher bar button (a `UIMenu`) and the map avatar's long-press
/// (an action sheet the shell presents through `presentSwitcher`).
///
/// Profiles + avatars are pre-fetched into a snapshot (`reload`) so the menu is
/// built **synchronously** — its content, including the active row's subtitle,
/// is in the first layout frame instead of popping in after the popover
/// animates (which a `UIDeferredMenuElement` would cause).
@MainActor
final class ProfileSwitcherMenuFactory {
    private let switching: any ProfileSwitching
    private let imagePipeline: ImagePipeline

    private var snapshot: [(profile: AccountProfile, image: UIImage?)] = []
    private var activeID: ProfileID?

    init(switching: any ProfileSwitching, imagePipeline: ImagePipeline) {
        self.switching = switching
        self.imagePipeline = imagePipeline
    }

    /// Pre-fetch profiles + avatars so subsequent `makeMenu` calls are synchronous.
    func reload() async {
        let profiles = (try? await switching.accountProfiles()) ?? []
        activeID = await switching.activeProfileID()
        var loaded: [(profile: AccountProfile, image: UIImage?)] = []
        for profile in profiles {
            loaded.append((profile: profile, image: await thumbnail(for: profile.avatarURL)))
        }
        snapshot = loaded
    }

    /// The current snapshot's profiles + active id (for the action-sheet path).
    var profiles: [AccountProfile] { snapshot.map(\.profile) }
    var currentActiveID: ProfileID? { activeID }

    /// A synchronous switcher `UIMenu` from the current snapshot. The active
    /// profile is highlighted in place of a checkmark: an "Active Profile"
    /// subtitle plus a red (`.destructive`) accent so it reads at a glance.
    func makeMenu(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) -> UIMenu {
        var rows: [UIMenuElement] = []
        for entry in snapshot {
            let isActive = entry.profile.id == activeID
            let action = UIAction(
                title: entry.profile.displayName,
                subtitle: isActive ? "Active Profile" : "@" + entry.profile.handle,
                image: entry.image,
                attributes: isActive ? .destructive : []
            ) { [weak self] _ in
                self?.commitSwitch(to: entry.profile.id, then: onSwitch)
            }
            rows.append(action)
        }
        let profilesMenu = UIMenu(title: "", options: .displayInline, children: rows)

        let addAction = UIAction(
            title: "Add Profile",
            image: UIImage(systemName: "person.badge.plus")
        ) { _ in onAddProfile() }
        let addMenu = UIMenu(title: "", options: .displayInline, children: [addAction])

        // No title — a clean, compact popover.
        return UIMenu(title: "", children: [profilesMenu, addMenu])
    }

    /// Switches the active profile, broadcasts the change (so identity chrome
    /// like the map avatar refreshes), then runs the caller's `onSwitch`.
    func commitSwitch(to id: ProfileID, then onSwitch: @escaping () -> Void) {
        Task { @MainActor in
            await switching.setActiveProfile(id)
            NotificationCenter.default.post(name: .activeProfileDidChange, object: nil)
            onSwitch()
        }
    }

    /// A small circular avatar for a menu row (or nil). Rendered `.alwaysOriginal`
    /// so the photo shows through the menu's template tinting.
    private func thumbnail(for url: URL?) async -> UIImage? {
        guard let url, let image = try? await imagePipeline.image(for: url) else { return nil }
        let side: CGFloat = 36
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }
}
