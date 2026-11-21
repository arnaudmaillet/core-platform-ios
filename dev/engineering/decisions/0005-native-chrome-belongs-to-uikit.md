# 0005. Native chrome is shown, hidden and animated by UIKit only

Date: 2026-09-28, reaffirmed 2026-10-03, 2026-10-11, 2026-11-05 · Status: Accepted

## Context
The navigation bar, the tab bar and its accessory, the toolbars and system sheets are UIKit's. Every workaround that wrote their alpha, held them during a transition or re-timed their animations produced long-lived bugs: empty glass capsules, bars stuck half-shown, flicker on iOS updates. The 100–180 ms they sometimes cost is acceptable.

## Decision
- **Never write alpha or opacity on native chrome.** Show and hide it only through UIKit's API (`setTabBarHidden(_:animated:)`, `setToolbarHidden(_:animated:)`, `setBottomAccessory(_:animated:)`).
- **Leave its display and animation to UIKit**, including during pushes and pops. An overlap while UIKit animates is not a defect.
- **Don't optimise native latency** unless it is outrageous. Measure, optimise our own code, and report a native cost instead of working around it.

## Consequences
- Fewer custom states to keep in sync with UIKit across iOS versions.
- Some transitions show UIKit's own fade or overlap, by choice.
- Bar items follow the bar contract (`dev/BAR_CONTRACT.md`, `BarContractGuardTests`).
- The traps met with native chrome on iOS 26 and 27 are in [Platform traps § Bars](../PLATFORM_TRAPS.md#bars-tab-bar-and-glass-ios-2627).
