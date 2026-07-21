import MediaCore
import ProfileInterface
import UIKit

/// Builds the reusable native profile-switcher `UIMenu`: each account profile
/// (rounded avatar + name + @handle) with a checkmark on the active one, plus a
/// trailing "Add Profile" action. Shared by the profile header's switcher bar
/// button and the map avatar's long-press context menu, so both surfaces show
/// the exact same menu. It populates through a deferred element — profiles and
/// their avatars are fetched when the menu opens, and re-fetched each time (so
/// the checkmark always reflects the current active profile).
@MainActor
final class ProfileSwitcherMenuFactory {
    private let switching: any ProfileSwitching
    private let imagePipeline: ImagePipeline

    init(switching: any ProfileSwitching, imagePipeline: ImagePipeline) {
        self.switching = switching
        self.imagePipeline = imagePipeline
    }

    /// - Parameters:
    ///   - onSwitch: fired on the main thread after the active profile changes,
    ///     so the caller refreshes its identity UI (avatar / profile screen).
    ///   - onAddProfile: fired when "Add Profile" is tapped.
    func makeMenu(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            Task { @MainActor in
                completion(await self.buildElements(onSwitch: onSwitch, onAddProfile: onAddProfile))
            }
        }
        return UIMenu(title: "Switch Profile", children: [deferred])
    }

    private func buildElements(onSwitch: @escaping () -> Void, onAddProfile: @escaping () -> Void) async -> [UIMenuElement] {
        let profiles = (try? await switching.accountProfiles()) ?? []
        let activeID = await switching.activeProfileID()

        var rows: [UIMenuElement] = []
        for profile in profiles {
            let image = await thumbnail(for: profile.avatarURL)
            let action = UIAction(
                title: profile.displayName,
                subtitle: "@" + profile.handle,
                image: image,
                state: profile.id == activeID ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.switching.setActiveProfile(profile.id)
                    // Broadcast so any identity chrome (the map avatar) refreshes,
                    // then let this caller refresh its own surface.
                    NotificationCenter.default.post(name: .activeProfileDidChange, object: nil)
                    onSwitch()
                }
            }
            rows.append(action)
        }
        let profilesMenu = UIMenu(title: "", options: .displayInline, children: rows)

        let addAction = UIAction(
            title: "Add Profile",
            image: UIImage(systemName: "person.badge.plus")
        ) { _ in onAddProfile() }
        let addMenu = UIMenu(title: "", options: .displayInline, children: [addAction])

        return [profilesMenu, addMenu]
    }

    /// A small circular avatar for the menu row (or nil — the row then shows no
    /// image). Rendered `.alwaysOriginal` so the photo shows through the menu's
    /// template tinting.
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
