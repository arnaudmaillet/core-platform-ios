import CoreModels
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

    /// A pre-built row: nothing here is computed at menu-build time.
    private struct Row {
        let id: ProfileID
        let title: String
        let image: UIImage?
        let isActive: Bool
    }
    private var rows: [Row] = []

    init(switching: any ProfileSwitching, imagePipeline: ImagePipeline) {
        self.switching = switching
        self.imagePipeline = imagePipeline
    }

    /// Fetches the account's profiles and pre-builds every row (strings + rounded
    /// avatar), so subsequent `makeMenu` calls are synchronous.
    func reload() async {
        let profiles = (try? await switching.accountProfiles()) ?? []
        let activeID = await switching.activeProfileID()
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
    }

    /// A synchronous switcher `UIMenu` from the pre-built rows, in the Telegram
    /// two-section shape: inactive profiles up top, then an inline section with
    /// the active profile and "Add Profile". Just avatar + display name, all in
    /// standard `.label` — the section split marks the active one, no checkmark
    /// or accent color.
    func makeMenu(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) -> UIMenu {
        func action(for row: Row) -> UIAction {
            UIAction(title: row.title, image: row.image) { [weak self] _ in
                self?.commitSwitch(to: row.id, then: onSwitch)
            }
        }

        // Section 1: the other profiles you can switch to.
        let inactive = rows.filter { !$0.isActive }.map(action(for:))
        let inactiveSection = UIMenu(title: "", options: .displayInline, children: inactive)

        // Section 2: the active profile, then Add Profile.
        var activeAndActions: [UIMenuElement] = rows.filter(\.isActive).map(action(for:))
        activeAndActions.append(UIAction(
            title: "Add Profile",
            image: UIImage(systemName: "person.badge.plus")
        ) { _ in onAddProfile() })
        let activeSection = UIMenu(title: "", options: .displayInline, children: activeAndActions)

        return UIMenu(title: "", children: [inactiveSection, activeSection])
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

    /// A small circular avatar for a menu row (or nil). Rendered `.alwaysOriginal`
    /// so the photo shows through the menu's tinting (incl. the active row's red).
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
