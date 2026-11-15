import Foundation

/// The places of the app shell's bar, in bar order. In CoreNavigation since
/// #2386, beside `AppRoute`, so the debug tools can name a tab.
///
/// The bar shows a fourth item, DETACHED at the trailing edge — the "+"
/// (`CreateTabItem`) — giving `| Explore  Messages  Profile |  + |` with no
/// custom bar. It is deliberately NOT a case here: it opens a menu and is
/// never selected, so nothing can route to it and `-select-tab` has no index
/// for it.
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
