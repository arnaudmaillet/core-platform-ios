# Responsiveness audit (#2116): every action answers on screen within 100 ms

**The rule:** from the input to the first frame on screen that shows the response, 100 ms at most. The clock starts at the input's own timestamp and stops at the presented frame. The animation has to start in that time, not finish. The full statement is in #2116 and in the charter's clause P16.

This file records:
- the instrument;
- the measurements;
- the offenders and their causes;
- what this pull request fixed, and what it leaves, with an issue for each.

The code-level list of every interactive element is in [`RESPONSIVENESS_INVENTORY.md`](RESPONSIVENESS_INVENTORY.md).

## 1. The instruments

- **`-interaction-latency`** (`CoreNavigation/InteractionLatency.swift`, DEBUG only). It measures input → frame for every input.
  - **The input:** `UIApplication.sendEvent`. The last finger up is a tap, or a release past 10 pt of travel. A long-press recognizer's `.began` after 300 ms of real hold is a long press.
  - **The response:** the strongest within 1.2 s.
    - **Screen:** `viewWillAppear` / `viewWillDisappear` (push, pop, present, dismiss, tab), or a menu or popover view entering a window.
    - **Action:** `UIControl` sends its action (target-action or `UIAction`), or a tap recognizer fires.
    - **Animation:** any `CALayer` animation, as a last resort.
  - **The frame:** the commit's turn end (an observer after Core Animation's commit), then the display's phase. The commit is picked up at the next vsync and shown one frame later. This is computed, not waited for: the render server shows a commit even while the main thread hangs in the next turn.
  - **Output:** a log line per input (latency, commit, turns, busy, idle, worst turn, first response), and a `HANG` line for any turn of 100 ms or more. Also a probe on the key window, and with `-interaction-latency-hud`, a badge (red over 100 ms, amber from 60 ms).
  - **Tests:** `InteractionLatencyTests`. They cover a push deferred by an `await` (idle time), a push after 150 ms of main-thread work (busy time), a control action, the phase arithmetic, and that nothing is hooked without the argument.
- **`-latency-bench`** (`App/Shell/LatencyBench.swift`). Empty screens in the app's own kind of shell (the UITab API, two stacks): a tab, a push, a sheet, a full-screen cover, an alert and a menu. **UIKit's own floor**, measured the same way.
- **Hot frames:** `-presentation-budget -presentation-budget-ms 50` beside it names the app frames of every turn past 50 ms. A Time Profiler trace (`xctrace record --device <sim> --attach <pid>`) covers the rest.

## 2. Protocol, and where it fell short of #2116's

- **Build:** Debug with `SWIFT_OPTIMIZATION_LEVEL=-O`, on the iPhone 18 Pro simulator (iOS 27.0), with the mock BFF.
- **Input:** real taps injected into the simulator (the iOS Simulator tool), never XCUITest.
- **Load average** at each series: 3.2–5.5, except the first tab series (load about 40–65, re-run quiet, below).

**Short of the protocol, said plainly:**
- **Runs:** 1 cold and 2–4 warm per action, not 10 warm. An injected tap costs seconds, and the night was spent on breadth first. The numbers are p50-like, not p95.
- **Scope:** member, plus a guest's sign-in path; light appearance only.
- **Coverage:** about 75 interactions measured, about 240 listed. The rest of the inventory is not measured yet; section 5 says which areas.
- **A back tapped while a transition still runs waits for it:** `StackArbiter.close(whenBusy: .retry)` defers the close to the transition's end. That is by design, and it is what UIKit's native back does too (it is ignored mid-push). Two measurements of 693 and 749 ms with about 500 ms of idle were such taps; they are left out.
- **Network:** `-mock-latency 700` was run on a subset (tabs, a thread, relationships, pops). No response moved with it: idle time stayed 3–15 ms. **No measured action waits on the network before answering.**

## 3. UIKit's floor on this simulator (`-latency-bench`)

| Response | Cold (first use after launch) | Warm |
|---|---|---|
| Tab switch | 200 ms | 54–64 ms |
| Push | 206 ms | 45–56 ms |
| Pop | — | 46–58 ms |
| Medium sheet | — | 98–129 ms |
| Sheet dismiss | — | 63–65 ms |
| Full-screen cover | — | 36–58 ms |
| Alert | 175 ms | 56 ms |
| Menu (`showsMenuAsPrimaryAction`) | 209 ms | 67 ms |

**What it means:**
- **The first use of any UIKit component after a launch costs 175–210 ms** with nothing of ours on screen. "Cold must pass" cannot hold on this simulator for a first use: that part is **system floor**.
- **A medium sheet is at or over the budget by itself, warm.** Every sheet in the app inherits 98–129 ms before any of our work. Replacing system sheets is a product decision (section 6).

## 4. Measured inventory

**Warm** is the best and the worst of the repeats. The verdict is ok (< 60 ms), at risk (60–100 ms) or over (> 100 ms).

### Shell and tabs

| Action | Response | Cold | Warm (before) | Warm (after this PR) | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|---|
| Tab → Explore | map root | 341–704 ms | 299–332 ms | — | 54–64 ms | over | #2120 |
| Tab → For You | Shots | — | 125–136 ms | 117–127 ms | 54–64 ms | over | #2118, #2120 |
| Tab → Messages | inbox | 295–411 ms | 150–184 ms, then a ~70 ms hang | 136–154 ms, no hang | 54–64 ms | over | #2117, #2120 |
| Tab → Profile | own profile | 164–198 ms | 134–150 ms | 113–114 ms | 54–64 ms | over | #2118, #2120 |
| "+" | the create menu | 207 ms | — | — | menu: cold 209, warm 67 ms | system floor (cold) | — |
| "+" → Text Post | composer sheet | 383 ms | — | — | sheet 98–129 ms | over | #2123 |
| Bell | notifications drawer | 163 ms | — | — | — | over | not analysed |
| Likes badge | wallet sheet | 521 ms | 145–146 ms | — | sheet 98–129 ms | over | #2122, #2123 |

### Shots (For You)

| Action | Response | Cold | Warm | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|
| Save (star) | optimistic state | 91 ms | — | — | at risk | — |
| Share | share sheet | 231 ms | 127 ms | sheet 98–129 ms | over (near floor warm) | #2123 |
| Author name | profile card sheet | 346 ms | 189 ms | sheet 98–129 ms | over | #2124 |
| Profile card ✕ | dismiss | — | 74–110 ms | dismiss 63–65 ms | at risk | — |
| Comment ticker | comments sheet | 322 ms | 193 ms | sheet 98–129 ms | over | #2123 |
| Comments ✕ | dismiss | — | 77–164 ms, then a 102–181 ms hang (rewarm) | dismiss 63–65 ms | over → see #2119 | #2119 |
| Tap on the video | pause (tap recognizer) | — | 83 ms | — | at risk | — |
| Sheet's dimmed area | dismiss | — | 74–97 ms | 63–65 ms | at risk | — |

### Messages

| Action | Response | Cold | Warm | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|
| Conversation row | thread push | 384–582 ms | 186–216 ms | push 45–56 ms | over | #2121 |
| Back from a thread | pop to the inbox | — | 116–152 ms | pop 46–58 ms | over | #2120 |
| Thread "⋯" | menu | — | 83 ms | menu 67 ms | at risk (floor) | — |
| Menu → View Profile | profile push | 236 ms | — | push 45–56 ms | over | #2125 |
| Requests segment | page | 198 ms | 65 ms | — | over cold, at risk | #2123 |

### Profile

| Action | Response | Cold | Warm | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|
| Followers | relationships push | 342 ms | 186–212 ms | push 45–56 ms | over | #2123 |
| Back | pop to the profile | — | 104–198 ms | pop 46–58 ms | over | #2120 |
| Settings gear | settings push | 349 ms | 147–152 ms | push 45–56 ms | over | #2123 |
| Edit Profile | push | 157 ms | — | push 45–56 ms | over | — |
| Edit Profile → Name | push | — | 81 ms | push 45–56 ms | at risk | — |
| Posts / History | segment | — | 79–81 ms | — | at risk | — |
| Grid post | hero post open | 373 ms | 212 ms | — | over | #2126 |
| Back from the post | hero close | — | 167–198 ms | — | over | #2126 |

### Explore

| Action | Response | Cold | Warm | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|
| A media pin | hero feed | 346–404 ms (565–649 ms once) | 200–216 ms | — | over | #2126 |
| Back from the pin's feed | hero close | — | 178–214 ms | — | over | #2126 |
| A text pin | native push feed | — | — | push 45–56 ms | not measured alone | — |
| Magnifier | search, keyboard up | 563 ms | 230 ms | push 45–56 ms | over | #2129 |
| A search suggestion | profile push | — | 238 ms | push 45–56 ms | over | #2125 |
| Search's Cancel | back to the map | — | 103–117 ms | pop 46–58 ms | over | #2120 |
| A comment's like (text page) | optimistic state | — | 71 ms | — | at risk | — |
| Sound disc | sound sheet | 248 ms | — | sheet 98–129 ms | over | #2123 |
| Sound sheet ✕ | dismiss | — | 102 ms | dismiss 63–65 ms | at risk/over | — |
| Likes badge | wallet sheet | 541 ms | — | sheet 98–129 ms | over | #2122 |

### Settings

| Action | Response | Cold | Warm | Floor | Verdict | Issue |
|---|---|---|---|---|---|---|
| Security and Login | push | 617 ms before the fix, 132 ms after | 88 ms | push 45–56 ms | at risk warm | #2128 (fixed) |
| Account | push | 98 ms | — | push 45–56 ms | at risk | — |
| Privacy | push | 142 ms | — | push 45–56 ms | over | #2123 |
| Notifications | push | 75 ms | — | push 45–56 ms | at risk | — |
| Your Activity | push | 138 ms | — | push 45–56 ms | over | #2123 |
| Back to Settings | pop | — | 68–78 ms | pop 46–58 ms | at risk | — |

### Guest

| Action | Response | Cold | Warm | Verdict | Issue |
|---|---|---|---|---|---|
| Like (gated) | sign-in sheet | 200–314 ms | — | over | #2123 |
| Continue with email | email step, keyboard up | 453–1067 ms | — | over | #2129 |

### Create

| Action | Response | Cold | Verdict | Issue |
|---|---|---|---|---|
| "+" → Upload Media | media picker | 199 ms | over (first use) | #2123 |

The picker itself is not measured: it asks for photo library access first, and the agent does not answer a system permission prompt.

### Notifications drawer

| Action | Response | Cold | Warm | Verdict | Issue |
|---|---|---|---|---|---|
| A row | post opens over the drawer | 129 ms | — | over | not analysed |
| Its back | close | — | 70 ms | at risk | — |
| An author's avatar on that post | profile push | 242 ms | — | over | #2125 |

## 5. Not measured yet

These areas come from the inventory and were not reached tonight:
- clusters, the place page and the map's filters;
- the camera, the media picker (behind the permission prompt), the editor and crop;
- the shortcut wheel and the emotes rail;
- account settings' deeper screens, and the shop's purchases;
- a guest's other surfaces;
- the composer keys.

**Prime suspects** in the inventory's section 2 are code paths that await before presenting. They are not measured yet:
- `StepUpPrompt` (`.signInAgain`): an alert after a network round trip, with no loading UI;
- `TwoStepViewController`'s backup codes;
- the country unlock;
- the profile block and unblock, with no pending UI at all.

**Keys:** the software keyboard is another process, so a keystroke has no in-app `UIEvent` to start the clock. Composers are covered only by `HANG` lines (any turn of 100 ms or more while typing).

## 6. Offenders by cause

### Fixed in this pull request

| Issue | Cause | Before → after |
|---|---|---|
| #2117 | The inbox reloaded an unchanged list on every appearance (`reloadData` in the unanimated path), re-dequeuing every visible row in the turn after a tab switch or a pop. | A ~70 ms hang after the switch → none. Tab → Messages warm 150–184 → 136–154 ms. |
| #2118 | All six tab faces were redrawn, and identical templates re-sent to the bar, on every switch into or out of Shots. | Tab → Profile warm 134–150 → 113–114 ms; → For You 125–136 → 117–127 ms. |
| #2119 | The comments panel was rebuilt (`PostDetailViewController.viewDidLoad`, 66–102 ms) in the comments close's own turn. | A 102–181 ms hang after a close → moved to the idle clock (`scheduleIdleCommentsWarm`). |
| #2127 | Four responder-chain lookups (the member gate, the Shop opener, the text entity opener, the completions) cast every responder to a Swift protocol. A failed cast of an Objective-C class scans the binary's conformance records. | 0.319 → 0.007 ms per lookup in a test host. About 8 ms per gated route in the app (Time Profiler), and every composer's `didMoveToWindow`. |
| #2128 | Security and Login asked `LAContext.canEvaluatePolicy` (an IPC to the authentication daemon) in `cellForItem`. | First open 617 → 132 ms (warm 88 ms). |
| #2126 (part) | Every feed cell built its own `CIContext` for person segmentation. | Gone from the pin and grid open's hot frames (it was about 20 ms cold). |
| #2125 (part) | The first bio with a link loaded the data detectors in the profile header's render. | Moved to a utility queue at launch. |

### Left, with their issues

| Issue | Group | Measured | Where the time goes | Can it go under 100 ms? |
|---|---|---|---|---|
| #2120 | The selector band is re-installed on every root appearance (tabs, pops) | 104–184 ms warm | `SelectorAccessory.install` about 15 ms, plus UIKit relaying out the whole tab container | Closer to the floor (54–64 ms). A design change to the band's lifetime. Size L. |
| #2121 | Thread push | 186–216 ms warm, 384–582 ms cold | First layout of the self-sizing transcript (forced by `syncBottomAnchor`), `init` about 70 ms cold, the band's settle | Likely, with cached row heights and a lazy composer. Size M. |
| #2122 | Wallet sheet | 145 ms warm, 521 ms cold | `buildCollection` (generic metadata about 96 ms cold), the detent measured from layout | Warm is near the sheet floor. Cold through a prewarm (#2123). |
| #2123 | First use after launch | 175–582 ms | UIKit's own first use (175–210 ms on empty screens), plus each screen's own cold cost | Only with an idle prewarm. **Owner's decision.** |
| #2124 | Profile card | 189 ms warm, 346 ms cold | Banner blur baked in place in the tap's turn (by design), `remeasure` about 32 ms | Yes, if the blur dissolves in after the rise. **Owner's decision** (visible during the rise). |
| #2125 | Profile push | 236–242 ms | Header render (`EmoteLabel`, `TextEntityScanner.linkRanges` about 22 ms, probably cold), gallery cells | Partly. Size M. |
| #2126 | Hero post open from a grid, or from a media pin | 200–216 ms warm, 346–404 ms cold | `ZoomAnimator.interruptibleAnimator` 54–92 ms: the flight lays the destination feed out on purpose (`container.layoutIfNeeded()`, for hydration and the chrome replica), so its cost is the feed's first layout; then the flight build and chrome | Partly: a cheaper first layout of the snap feed. Size M. |
| #2129 | A step that focuses its field as it is pushed (sign-in email, search) | 453–1067 ms first, 230 ms warm (search) | The keyboard's first appearance is committed with the push, so the push's first frame waits for it. UIKit's own work. | Focus a turn later: the keyboard would rise after the page instead of with it. **Owner's decision.** |

### System floor, and the owner's call

- **The first use of any UIKit component:** 175–210 ms on empty screens.
- **A medium sheet, warm:** 98–129 ms on empty screens. Every sheet in the app starts there: comments, share, wallet, profile card, the composer. Getting under 100 ms would mean custom presentations instead of system sheets. That is a product decision, asked on #2116.
- **The "+" menu's first open:** 207 ms, against 209 ms for an empty menu on the bench (system floor). Warm menus are 67–83 ms.

## 7. Regression guard, and the settled screens

- **`UITests/InteractionLatencyUITests.swift`** reads the harness's probe for one route per fixed group: tab → Messages, tab → Profile, Messages → thread, Settings → Security. Each route has a ratchet calibrated under XCUITest (best warm run, about ×2 head-room). It runs on demand: `hero-uitests` with `suite: InteractionLatencyUITests`.
- **Settled screens, before (develop at 68a0fe6b) and after this PR,** captured in light and dark after 9 s:
  - Settings and Security and Login are identical to the pixel.
  - The profile and the inbox differ only in live content: animated emoji, an animated avatar's frame, a video tile's frame, the Dynamic Island's capture.

## 8. On a device

Run the app with `-interaction-latency -interaction-latency-hud`. Any action over 100 ms shows a red badge under the status bar naming its response ("appear ConversationThread 186 ms"), and an action from 60 ms an amber one.

The simulator's floors above are the reference: a number on the device near its floor is UIKit's. The at-risk list (60–100 ms on the simulator) is decided on the device.
