# Bar contract

The rules for every toolbar and navigation bar in the app. The owner settled them on 2026-10-24, from the profile card's toolbar (#1678 / PR #1680). Issue #1679 tracks applying them to every screen. The code side is `BarItems` (DesignSystem), and `BarContractGuardTests` keeps new screens to it.

## Why

iOS 26+ Liquid Glass bars draw and animate their own items. Every hand-made variant we tried looked wrong on device:
- a `UIButton` restyled inside a spring of ours cross-faded two titles over each other;
- with no item identifiers, UIKit matched Follow with the bell that replaced it and morphed one into the other.

What works is to **let the bar draw every bubble** and **let UIKit animate every change**, telling it which items are the same.

Measured on iOS 27 (iPhone 18 Pro simulator, 2026-10-24):
- A native title item cannot stretch: `width` is ignored for `.prominent` and plain items alike.
- A native item does not animate a change of its own title or style. Changing it in place, even inside `UIView.animate`, swaps in one frame.
- A custom view in an item **without** `hidesSharedBackground` gets the bar's own bubble, press highlight and `.prominent` tint, and it can stretch.
- Without identifiers, UIKit matches items by position across a rebuild.

## The rules

| | Rule | How |
|---|---|---|
| R1 | **Icons are native.** An icon-only control is never a `UIButton` (or any view) in a custom view. Two icons side by side are two items sharing the bar's platter, never a `UIStackView` of buttons. | `BarItems.icon(id:image:label:action:)` / `…menu:)` |
| R2 | **Every item has an identifier**, stable and named by function (`<screen>.<role>`). An item that appears on several screens keeps one shared identifier. | every `BarItems` maker takes `id`; shared ones in `BarItems.SharedID` (wallet, search, bell) |
| R3 | **UIKit animates.** A state change rebuilds the group and sets it animated. The trailing group goes through `setOwnTrailingBarItems`, so toasts keep their place. Never `UIView.animate` / `UIView.transition` around bar items or a bar, and never restyle an item's view in place. | `setToolbarItems(_:animated:)`, `navigationItem.setLeftBarButtonItems(_:animated:)`, `setOwnTrailingBarItems(_:animated:)` |
| R4 | **No "•••".** A bar never overflows into UIKit's automatic overflow menu. Every bar fits an iPhone SE (375pt) at the app's largest text size (XXXL, `TextSizeCeiling`). A screen with conditional items states its width budget. | check on the SE simulator at XXXL; `-header-audit` |
| R5 | **Wide items.** A control that takes the free width is a plain view holding its word, in an item whose bubble the bar draws. | `BarItems.stretched(id:title:prominent:action:)` (`StretchedBarLabel`) |
| R6 | **Complex containers are the only other custom views.** These are views a stock item cannot draw, each with an identifier. Their content changes are theirs to animate. | `BarItems.container(id:view:)` |
| R7 | **Toggles stay native.** A toggled glyph (save star, bell, flash, bookmark) is the item's `image`, from `SaveStar` / `AppSymbol` / `BarSymbol`. The action carries no image: a `UIAction`'s image is re-applied to its item when it fires. | `BarItems.icon` + `item.image = …` |

### Allowed containers (R6)

- **Person pill** (`SnapAuthorIdentityView`, `PersonBarItem`): avatar, name, handle, follow badge. It blurs one author into the next itself; the owner accepted this as an exception (2026-10-24).
- **Wallet badge** (`WalletBadgeButton`): `BarItems.SharedID.walletBalance` everywhere. It is re-minted when its width changes, because the bar freezes an item's width when the item is made.
- **Gems balance** (country shop).
- **Selector strips** (`PagedTabBar` through `SelectorToolbarItem`, `IconSelectorBar`, `IconActionBar`).
- **Search fields.** Inbox and relationships move to `UISearchController` (owner, 2026-10-24).
- **Segmented controls** (wallet stakes, activity).
- **Toasts** (`NavigationBarToasts`).
- **Sound pill** (`SoundPillView`), **day pill** (`SnapBarDayPill`, a custom view only so it can truncate), **comment sort** (`SnapCommentSortButton`, glyph + title + menu).

## Checklist for a new screen with a bar

1. Build every item through `BarItems`, and give each one an identifier by function.
2. On a state change, rebuild the group and set it animated (`setOwnTrailingBarItems` for the trailing group). Add no animation of your own.
3. Icons are `BarItems.icon`, wide words are `BarItems.stretched`, and anything else is a listed container.
4. Run the screen on the iPhone SE simulator at XXXL and check that nothing collapses into "•••".
5. `BarContractGuardTests` fails on a new `UIBarButtonItem(customView:`, `hidesSharedBackground = true`, `SnapNavControls.make…` or `morphNavigationBar(` outside its baseline. A change that converts a screen lowers that baseline.
6. `-header-audit` prints a `CONTRACT` line per surface listing items with no identifier and controls in custom views.
