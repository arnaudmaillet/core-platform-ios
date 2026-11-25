import Foundation

/// The places of the app shell's bar, in bar order. In CoreNavigation since
/// #2386, beside `AppRoute`, so the debug tools can name a tab.
///
/// Three places since #2489 (the owner 2026-11-18): `| Explore  Messages |
/// Profile |`, Profile apart on iOS 27 (`ShellTabs`). The "+" that stood
/// detached at the trailing edge, never a place, moved to Explore's top bar
/// (`CreateBarItem`).
///
/// **For You left the bar on 2026-11-15 (#2453):** the app is the map's
/// first, and For You comes back later. Its slot was 1, so `-select-tab 1`
/// is Messages and `-select-tab 2` Profile since then.
///
/// Backed by a stable string identifier (not an ordinal), so reordering the bar
/// never silently repoints a route.
///
/// ⚠️ Declaration order IS bar order, and `-select-tab <n>` indexes
/// `allCases`.
///
/// `.explore` was `.maps` until 2026-09-26 (the tab is named for the job, the
/// Maps feature behind it kept its name). Same slot, so `-select-tab 0` still
/// opens it; the raw value moved with the case, so the one place a NAME is
/// typed — `-nav-stress <cycles> <tab>` — takes `explore`.
public enum AppTab: String, CaseIterable, Sendable {
    case explore
    case messages
    case profile
}
