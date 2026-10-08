import CoreModels
import CoreNavigation
import DesignSystem
import UIKit

/// The shell's tab bar controller, with two additions: it reports its layout
/// passes, and it opens the Shop for a stake menu.
///
/// The Profile tab's long-press menu is carried by an invisible button the shell
/// keeps aligned over the tab (see `MainTabCoordinator`). That tab's button view
/// belongs to UIKit and moves whenever the bar lays out — rotation, a size-class
/// change, the bar hiding and coming back — so the overlay needs a hook to
/// follow it. `UITabBarController` publishes none, hence this.
///
/// The window's root, so every screen's responder chain ends here — which is
/// how the stake menu's "Get ×100 cartridges in the Shop" finds the Shop from
/// the feed rail, the composer or a card (`StakeShopOpening`) — and how any
/// control finds the gate that asks a guest to sign up (`MemberGateProviding`).
final class ShellTabBarController: UITabBarController, StakeShopOpening, MemberGateProviding, TextEntityOpening {
    /// Called after every layout pass.
    var onLayout: (() -> Void)?
    /// Builds the Shop on its Boosts (`AppContainer.makeStakeShopSheet`);
    /// nil, or nil answered, sells no packs.
    var makeStakeShopSheet: (() -> UIViewController?)?
    /// The app's one gate (`AppContainer.memberGate`), set by the shell before
    /// any screen can ask for it.
    var memberGate: any MemberGating = MemberGate()

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }

    /// Called when the bar is on screen (#694: the shell redraws its items
    /// once it is — see `MainTabCoordinator.refreshTabLabelsIfNeeded`).
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    func makeStakeShop() -> UIViewController? {
        makeStakeShopSheet?()
    }

    /// Opens a tapped `@handle` and a tapped `#tag` (#524), set by the shell.
    var openMention: ((_ handle: String, _ source: UIView) -> Void)?
    var openHashtag: ((_ tag: String) -> Void)?

    func openTextEntity(_ token: String, from source: UIView) {
        let bare = String(token.dropFirst())
        switch TextEntityLinks.kind(of: token) {
        case .mention: openMention?(bare, source)
        case .hashtag: openHashtag?(bare)
        }
    }

    func opensTextEntities(of kind: TextEntity.Kind) -> Bool {
        switch kind {
        case .mention: openMention != nil
        case .hashtag: openHashtag != nil
        }
    }

    /// `@` and `#` completions for every composer up this chain (#524), set
    /// by the shell.
    var textCompletions: (any TextCompletionProviding)?
}

extension ShellTabBarController: TextCompletionSource {}
