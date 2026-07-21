import CoreModels
import ProfileInterface
import UIKit

/// The reusable profile switcher, shared by the profile header's switcher bar
/// button and the map avatar's long-press context menu — both build the exact
/// same `UIMenu`.
///
/// Rows are pre-formatted into ready-to-render strings by `reload` (an async
/// fetch of the account's profiles). `makeMenu` is then **fully synchronous**:
/// no async work, no deferred element, no image loading/formatting — every
/// `UIAction(title:subtitle:)` is complete, so title and subtitle render
/// together in the menu's first frame with zero delay.
@MainActor
final class ProfileSwitcherMenuFactory: ProfileSwitcherPresenting {
    private let switching: any ProfileSwitching

    /// A pre-formatted row: nothing here is computed at menu-build time.
    private struct Row {
        let id: ProfileID
        let title: String
        let subtitle: String
        let isActive: Bool
    }
    private var rows: [Row] = []

    init(switching: any ProfileSwitching) {
        self.switching = switching
    }

    /// Fetches the account's profiles and pre-formats every row's strings, so
    /// subsequent `makeMenu` calls are synchronous.
    func reload() async {
        let profiles = (try? await switching.accountProfiles()) ?? []
        let activeID = await switching.activeProfileID()
        rows = profiles.map { profile in
            let isActive = profile.id == activeID
            return Row(
                id: profile.id,
                title: profile.displayName,
                subtitle: isActive ? "Active Profile" : "@" + profile.handle,
                isActive: isActive
            )
        }
    }

    /// A synchronous switcher `UIMenu` from the pre-formatted rows. The active
    /// profile is highlighted in place of a checkmark: an "Active Profile"
    /// subtitle plus a red (`.destructive`) accent, so it reads at a glance.
    func makeMenu(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) -> UIMenu {
        var elements: [UIMenuElement] = []
        for row in rows {
            let action = UIAction(
                title: row.title,
                subtitle: row.subtitle,
                attributes: row.isActive ? .destructive : []
            ) { [weak self] _ in
                self?.commitSwitch(to: row.id, then: onSwitch)
            }
            elements.append(action)
        }
        let profilesMenu = UIMenu(title: "", options: .displayInline, children: elements)

        // A system glyph (SF Symbol) — synchronous, no formatting.
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
    private func commitSwitch(to id: ProfileID, then onSwitch: @escaping () -> Void) {
        Task { @MainActor in
            await switching.setActiveProfile(id)
            NotificationCenter.default.post(name: .activeProfileDidChange, object: nil)
            onSwitch()
        }
    }
}
