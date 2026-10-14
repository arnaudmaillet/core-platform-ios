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
    /// Builds the Shop on its Boosts (`AppContainer.makeStakeShopScreen`);
    /// nil, or nil answered, sells no packs.
    var makeStakeShopScreen: (() -> UIViewController?)?
    /// The app's one gate (`AppContainer.memberGate`), set by the shell before
    /// any screen can ask for it.
    var memberGate: any MemberGating = MemberGate()

    override func viewDidLoad() {
        super.viewDidLoad()
        // The selected tab is NEUTRAL (#1169, decided 2026-10-14): the label's
        // colour on the glass selection, the accent kept for what matters.
        tabBar.tintColor = Palette.rules.selectedTabIsNeutral ? .label : Palette.tint
        // One colour for every unread count (#1169) — the Messages selector's
        // and the inbox rows' too. `UITab` has no badge colour of its own:
        // the bar's item appearances carry it, on a copy of what UIKit set up
        // so its glass is untouched.
        let appearance = tabBar.standardAppearance.copy()
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            item.normal.badgeBackgroundColor = Palette.counter
            item.selected.badgeBackgroundColor = Palette.counter
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

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
        makeStakeShopScreen?()
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
