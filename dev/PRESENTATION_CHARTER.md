# The presentation charter

What every screen owes the transition that brings it on, and what it may cost.
Every clause is numbered so a review, a test or a trace can cite it, and every
clause is written so that it can FAIL — "feels snappy" is not a clause.

This charter grew out of an audit of the 29 user-facing screens (24 September
2026). Most of them already obey it; the point of writing it down is that the
next screen obeys it too, and that the handful that do not have a name and a
fix. The audit's findings are at the end, cut into pull requests.

---

## The one invariant

⚠️ **P0 — A SCREEN IS PRESENTABLE AT FRAME 0 WITHOUT A SINGLE `await`.** The
push, the sheet, the hero flight or the cross-dissolve starts in the same
run-loop turn the screen is built in. Anything awaited before that turn ends
delays the animation; anything awaited that then lands during it rebuilds the
screen mid-flight (the measured "flash", `FeedRepository.swift` on `peekPost`).
So at frame 0 the screen shows:

1. **What it already has.** A model handed to its init, or a synchronous read of
   a warm in-memory cache. Both are legitimate and PREFERRED over a placeholder:
   a skeleton replaced one frame later is a flicker, not a loading state.
2. **A skeleton for everything else.** Never a spinner over an empty view,
   never a blank page, never the previous screen's data.

What it does NOT do at frame 0 is fetch, decode, enumerate, measure text for a
whole corpus, or run CoreImage. All of that starts in `viewDidLoad` and lands
whenever it lands, over a skeleton that was already there.

This is deliberately NOT "every screen opens in a loading state". A loading
state is the default the screen falls back to, not the first frame it is
obliged to show. The wording was argued and settled with the author: the aim is
zero wait at presentation, and a forced skeleton on a warm cache is a wait
dressed up as one.

---

## Clauses

### Construction

- **P1 — Init stores dependencies and builds views. It fetches nothing.** No
  `Task` in an init, no synchronous store read that touches disk, no
  `loadViewIfNeeded` on a child.
- **P2 — `viewDidLoad` + the first `layoutSubviews` cost under 8 ms on the
  slowest supported device** (iPhone SE 2nd gen). That is half a frame at 60 Hz,
  the budget left once UIKit's own transition setup is paid. A screen that needs
  more defers the excess to after the first frame, never to before it.
- **P3 — A container loads its children lazily.** A paged or tabbed screen
  loads the view of the page it opens on; every other page's view is loaded on
  first scroll-to or select. `pages.map(\.view)` in an init violates this.
- **P4 — Disk and PhotoKit are never read on the main actor at presentation.**
  A store backed by a file or UserDefaults is built ONCE and injected, not
  constructed per presentation. A PhotoKit enumeration runs off the main actor
  and its result is delivered to the screen as a value.

### Seeding

- **P5 — A synchronous seed is a lock-protected in-memory read, bounded, under
  1 ms, and nil on a miss.** `peekPost`, `cachedTopComments`,
  `ConversationDirectory.title(for:)`, `ProfileIdentityStub` and
  `InboxCatalog.snapshot` are the model. A seed never fetches, never decodes,
  never falls through to disk.
- **P6 — A seed is additive.** A real render replaces it; a seed arriving after
  a real render is ignored. Two seeds never truncate a corpus (a partial seed is
  refused as a whole, `FeedFeatureBuilder.swift` on the pin path).
- **P7 — A screen opened from a screen that already holds its data reads that
  data first.** Edit Profile from Profile, Post Detail from a feed, Profile
  from a previous visit: each tries the cache before it fetches, and the fetch
  then refreshes rather than reveals.

### Loading state

- **P8 — The loading state is a skeleton laid out like the content it stands
  for.** Same row heights, same grid, same header bones, so the swap to content
  moves nothing. A `UIActivityIndicatorView` is allowed only for a SECOND load
  (paging footer, a search re-query over existing results, a render in
  progress) — never as the first frame of a screen.
- **P9 — Skeleton and content are the same view hierarchy, not two.** The
  skeleton is the content view rendered with redaction (`setRedacted(true)` on
  a header, skeleton cells in the same collection view), so nav chrome, bars,
  insets and hero anchors are final at frame 0. The messages screens and the
  profile header are the reference implementations.
- **P10 — Leaving the loading state is a cross-fade, never a pop.** One
  shared helper does it; a screen that reimplements it is a review comment.
- **P11 — Every phase enum spells the same four states.** `.loading`,
  `.content`, `.empty`, `.failed`. A screen without an empty and a failed
  rendering is unfinished.

### Presentation timing

- **P12 — Nothing awaits before `push`/`present` is called.** A builder is
  synchronous. If a screen needs a value the builder does not have, the screen
  fetches it itself after `viewDidLoad`, over its skeleton.
- **P13 — Heavy per-item work is off the main actor and per item, not per
  screen.** Thumbnails, text measurement for display models, film-strip
  sampling, QR rendering and CoreImage all run in a detached task or an actor,
  and the screen shows the item as soon as its own work is done, not when all
  of them are.
- **P14 — The transition coordinator is for chrome, not for data.** It keeps
  the nav bar and accessories in step with the animation. It is never used to
  hold a fetch until the animation ends: that trades a mid-flight flash for a
  delay the user still sees.
- **P15 — The first layout never runs inside someone else's animation block.**
  Already enforced (PR #189, `-first-layout-trace`): a screen "unfolding from
  the top-left" is this clause failing.

---

## How it is measured

A clause that nobody measures is a preference. Three instruments:

| Instrument | Catches | Status |
|---|---|---|
| `-first-layout-trace` | P15 | shipped (`App/Shell/FirstLayoutTrace.swift`) |
| Hero and profile transition verification (`.claude/skills/verify`) | P9 for hero destinations | shipped |
| `-presentation-budget` | P1, P2, P4, P13 | shipped (`App/Shell/PresentationBudget.swift`, PR 1 below) |

`-presentation-budget` is a DEBUG harness in the same shape as the layout
trace. **Its unit is the main-thread run-loop turn**, not a method: timing
`viewDidLoad` alone misses the init (a Swift init cannot be hooked), the
`loadView`, the first layout of the whole subtree (children lay out after
their parent's `layoutSubviews` returns) and the builder work before the
push, and all of it runs in the one turn the push starts in. A run-loop
observer brackets each turn (`afterWaiting` → `beforeWaiting` after Core
Animation's commit, nested loops ignored), and every `viewDidLoad` and every
controller root view's first `layoutSubviews` inside it is that turn's screen
event. A turn with screen events over the budget is a P2 failure, logged with:

- the events (`load:ProfileViewController, layout:ProfileViewController, …`);
- every `viewDidLoad` override in the app's own images timed by class (the
  overrides are wrapped once at install through their IMPs);
- **the app's own frames that were hottest** while the turn ran past the
  budget — a watchdog thread suspends the main thread every 2 ms, walks its
  frame pointers, resumes it, and the report counts symbols across samples.
  This is what names a culprit rather than a screen.

The launch is exempt: the turn that builds the tab shell and every screen
turn back to back after it (the tab roots, a `-select-tab`), up to the first
quiet turn. Arguments: `-presentation-budget-ms N` (default 8),
`-presentation-budget-trap` (a screen turn over budget traps),
`-presentation-budget-grace N`. The log is `Documents/presentation-budget.log`
and a probe on the key window (`budget;turns=…;screens=…;over=…;worst=…;hot=…`)
gives a UI test the denominator.

**The sweep** (`UITests/PresentationBudgetUITests.swift`) opens eight routes
(a For You tile, a conversation, a profile tile, relationships, the share
sheet, a map pin, the "+" menu's Text Post and Upload Media) and reads the
probe after each. Two numbers per route: the simulator **budget** every route
must come down to, and a per-route **ceiling** — a ratchet set at the last
measurement with head-room, that a route may not get worse than, and that
the PR fixing the route lowers or removes. That is how the sweep is green on
every merge and still refuses a regression. Like the hero suites it runs on
demand (`hero-uitests.yml`), not in the required checks.

⚠️ **The sweep's numbers move with the host.** The same route read 313 ms on a
quiet host and 737 ms with three builds running beside the sweep. A ceiling
is for a regression of the code, so the routes the fix PRs have not reached
carry ~2.5x head-room, and a red sweep on a loaded host is re-run quiet
before it is believed.

⚠️ **The sweep's numbers are not the charter's 8 ms.** It runs a DEBUG build
on a simulator under XCUITest: no optimizer, an accessibility runtime that
roughly doubles a turn, and an Apple-silicon host that is faster than the SE
on some paths and slower on others. The 8 ms is measured on the SE with the
harness alone, for the screens the sweep flags; the sweep's budget is
calibrated on the same runner as its ceilings.

### What the instrument found on day one (24 September 2026)

Debug build, iPhone 18 Pro simulator, harness alone (no XCUITest), the
turn that brought the screen on and the frames the sampler blamed:

| Route | Turn | Blamed |
|---|---|---|
| Map pin → snap feed | 151 ms + 111 ms | `MapsViewController.openAnnotation` → the zoom flight's setup; then `SnapFeedViewController.installCommentsPanel` / `prewarmComments` and `PostDetailViewController.viewDidLoad` inside the feed's first idle |
| For You tile → snap feed | 376 ms (under XCUITest) | `RevealPresentAnimator.animateTransition` running the feed's first layout: `SnapFeedCell.configure`, `SnapShortcutRailView.setSymbols` (one `UIImage(systemName:)` per bubble), a `Collection.map` |
| Profile → relationships | 205 ms | `ProfileRelationshipListViewController.render/apply` for three pages at once (P3), flushed by `SelectorAccessory.settlePendingLayout` |
| Profile → share sheet | 38 ms + 105 ms | `ProfileShareViewController.viewDidLoad` (31 ms in `configureViews`), then `fittedContentHeight` re-laying the sheet for its detent |
| "+" → Text Post | 327 ms (under XCUITest) | `CreateTabItem.presentMenu`: the `UIMenu`'s own controller, before the composer |
| "+" → Upload Media | 514 ms (under XCUITest) | `MediaPickerViewController` (P4, PR 2) |
| Messages → thread | 602 ms (under XCUITest) | `ConversationThreadViewController` first layout |

Two of these were not in the audit: the snap feed's first layout is the
largest cost in the app whatever opens it (the shortcut rail's symbol images
and the cell configure), and the "+" menu pays for its `UIMenu` before any
composer exists. Both join the list below.

---

## The audit, cut into pull requests

Each PR is one clause made true for one set of screens, verifiable on its own,
and mergeable on green. Order is by user-visible cost, not by size.

### PR 1 — The budget instrument (P2) — shipped (#191)

`-presentation-budget` and `-presentation-budget-trap` as above, plus the
sweep test. Ships FIRST so every later PR can cite a before/after number
instead of a feeling. No production code changes.

### PR 2 — Media picker off the main actor (P4, P8) — shipped (#192)

`PhotosMediaLibrary.albums()` and `items(in:)` walk every asset of every album
on the main actor (`PhotosMediaLibrary.swift`), and `MediaLibraryReading` is
`@MainActor` by declaration (`MediaLibrary.swift`). The sheet is the "+" menu's
most-used destination and the largest library is the slowest.

- Move enumeration to a `nonisolated` path that returns value types; keep
  `PHAsset` handles in a lock-protected map. ⚠️ Every PhotoKit handler written
  in a `@MainActor` type traps at runtime, not compile time — see the two
  instances already fixed in this file.
- Replace the large spinner with a grid of `PostGridSkeletonTileCell`s sized to
  the sheet, so the album strip and the grid frame are final at frame 0.
- Before/after on the simulator with `-seed-photo-albums` and on a device.

### PR 3 — Containers load lazily (P1, P3) — shipped (#193)

- `ProfileRelationshipsViewController` builds both list pages' views in its
  init (`pages.map(\.view)`); load the opening page only.
- `MessagesInboxViewController.viewDidLoad` calls `loadViewIfNeeded` on every
  surface and on the search results; load the visible one, the rest on first
  select. ⚠️ The unread watermark and the section pill read the catalog, not
  the surfaces, so nothing else observes a page that is not loaded yet —
  verify that claim, do not assume it.

### PR 4 — Stores built once (P4) — shipped (#194)

`TextPostComposerViewController` receives `postDrafts ?? PostDraftStore()` and
the app never injects it, so every "+" → Text Post reads and decodes the
drafts file synchronously at presentation. Build the store once in the app's
composition root and inject it; the drafts screen shares the instance.

### PR 5 — Pin-opened feed builds its models off the main actor (P13) — RE-SCOPED after measurement

The audit's premise was that `FeedDisplayModelBuilder().build(cached, …)` on
the pin path ran text measurement on the main actor before the push. Measured
on 24 September 2026 with `-presentation-budget`: it does not. The builder
formats strings only (`FeedItemDisplayModel.swift`), and the sampler never
put it among the hottest frames. The pin route's turn (155–392 ms, debug
sim) is spent in `ZoomAnimator.present` / `ZoomFlightInterruptor.startInteractiveTransition`
running the snap feed's first layout, which is PR 5b. The second turn on that
route (`PostDetailViewController` inside `installCommentsPanel`) is the
comments warm, already held back until `zoomTransitionDidEnd` + 0.6 s by
design — it is after the flight, not in it. Nothing to do here; the work is
5b's.

A symbol-image cache for `SnapShortcutRailView` (one `UIImage(systemName:)`
per bubble per configure, which the sampler had listed) was tried the same
day and measured at 182 / 176 ms against 155 / 392 ms before — no gain
outside the noise. On 25 September it was tried again, properly: a quiet
host, three runs per route, the cache PLUS a prewarm of the whole pool off
the main thread at feature build (so the process's first resolution — the
IPC the sampler was really seeing — happened before any tile was tapped),
and bubble reuse instead of rebuild. For You tile: 269–276 ms before,
272–276 ms after. Map pin: 152–160 before, 155–256 after. The symbol frames
vanished from the samples and the turn did not move: what the sampler
attributes to a frame that is BLOCKED (an IPC, a lock) is wall time the turn
would have spent anyway on whatever ran next. Not shipped, twice. The feed's
first-layout cost is not the symbols.

⚠️ **THE SAMPLER'S LESSON, WRITTEN DOWN.** A hottest-frames list is a list
of where the main thread WAS, not of what would be saved by removing it: a
frame that waits (an IPC to a daemon, a lock) collects samples for its whole
wait and removing it saves nothing if the wait overlapped work that had to
happen anyway. Before acting on a frame, remove it and measure the turn on
a quiet host, three runs; only a turn that moves is a cause.

### PR 6 — Editor thumbnails render off the main actor (P13) — #198

A reopened draft with edits renders every cell's thumbnail through
`MediaEdits.applied(to:)` on the main actor as the picture arrives
(`MediaEditorViewController.swift`). Run it inside the same detached task the
thumbnail comes from.

### PR 7 — Spinners become skeletons (P8) — shipped (#196), `PostDetail` `.full` left

Notifications (large spinner, table hidden), Post Detail in `.full` mode,
Search's People results, and the share sheet's target search. Each gets
skeleton rows from the existing components (`PersonSkeletonCell`,
`CommentSkeletonRowView`, `RelationshipSkeletonCell`) laid out at the content's
size. The Maps tab is exempt: the map IS its content, and its clusters arrive
over a drawn map.

### PR 8 — Screens read what the previous screen had (P7) — shipped (#197)

- Edit Profile refetches `currentUserProfile()` though Profile just rendered
  it; seed from `ProfileCache` and refresh.
- Post Detail calls `loadPost` without trying `peekPost`.
- Profile's first load never reads `ProfileCache` (only account switching
  does); a revisit should render the cached profile at frame 0 and refresh.

### PR 5b — The snap feed's first layout (P13) — behind `-defer-resting-comments`

Found by the instrument: whatever opens the snap feed (a For You tile, a
profile tile, a map pin), its first layout inside the hero's setup is the
largest screen turn in the app. On a TEXT page the caption lives inside the
comments panel, so the page mounted a whole `PostDetailViewController` in
`willDisplay`, inside the turn that sets the flight up.

Built 25 September 2026, behind a DEBUG flag, after the author chose the
deferral: a `RestingCommentsPlaceholderView` (the caption as the same
`CommentRowView` the panel's first row is, the comment rows as the same bones
the panel draws while its comments load, at the stream's own insets) is
installed in the cell's comments container for the flight's duration, and
the real panel is mounted once the flight has landed — on the NEXT turn, so
the landing frame commits first, except when the page was opened on its
comments, where it is mounted before the pending comments are applied.

⚠️ **THE TEXT REVEAL IS A PUSH, NOT A ZOOM.** It never reaches
`zoomTransitionWillBegin` / `zoomTransitionDidEnd`; the installer's pre-push
staging (`TextRevealInstaller.geometry`) is the feed's only notice, and
`viewDidAppear` is its landing. Both flights raise the same
`isAwaitingAnyFlight`. ⚠️ And a cell marked engaged by the placeholder
skipped the real panel's reveal (`setCommentsEngaged` guards on the flag):
the placeholder makes the container visible without marking the cell.

Measured, For You text tile (`-foryou-open 0`), harness alone, three runs:

| | Flight turn | Mount turn (after landing) |
|---|---|---|
| Flag off | 271 / 261 / 253 ms | — (inside the flight turn) |
| Flag on | 178 / 182 / 180 ms | 153 / 136 / 157 ms |

A third off the flight, and the panel's own cost moved to a turn after the
landing frame, over a placeholder that already shows the caption and the
rows. Filmed both, frame by frame: the flagged page arrives with its caption
and bones, lands, and the real comments land into it with the bones fading
under them. A media card opened on its comments still lands engaged.

Watched on a device the same morning, two defects, both fixed: the settle
could land mid-flight and mount the real panel over the placeholder's bones
(`reconcileRestingInterface` now leaves a page alone while its placeholder
stands), and the cross-fade let bones show through under real rows (the
placeholder is removed the instant any path mounts the panel, in
`installRestingPanel`). The placeholder also wears the whole engaged look
(`setCommentsEngagementProgress(0)`), or the page flew in with its reaction
rail showing.

The flag stays off until the author has watched the film on a device again.
What remains in the flight turn is the cell's own configure and UIKit's
layout of it, which no single frame owns.

### PR 5c — The "+" menu (P2) — measured, closed

Measured 25 September 2026 with `-open-create-menu` (the tap's own path,
`shouldSelectTab` → `performPrimaryAction`), harness alone, quiet host:
the turn that presents the menu is 179 / 202 / 243 ms with the three symbol
images and 174 / 188 / 302 ms without them. Same number. Three quarters of
its samples carry NO app frame at all; the rest are the synchronous
`performPrimaryAction` call. The menu is already built once at init; what
the tap pays is UIKit's context-menu presentation (`_UIContextMenuActionsOnlyViewController`,
its platter and its snapshot), which every context menu in iOS pays and
which a release build on a device pays far less of. Nothing of ours to move.
The only lever would be to stop using a `UIMenu` for the "+" — a design
change, not an optimisation — so this is closed unless the menu itself is
redesigned.

### PR 9 — One `Loadable` and one cross-fade (P10, P11) — #200

Sixteen `enum Phase` declarations spell the same four states, and at least
four screens reimplement "fade the skeleton out and the content in". A
`Loadable<Content>` in DesignSystem with the four cases, and a
`UIView.crossfade(from:to:)` helper with the settled duration, adopted screen
by screen as they are touched. This PR is last on purpose: it is the one with
no user-visible change, and it must not block the eight that have one.

---

## What was decided against

- **"Every screen starts in `.loading`."** Rejected for the reason in P0: on a
  warm cache it is a one-frame flicker, and on the hero paths it is the flash
  that `peekPost` and the identity stub were written to remove.
- **Deferring fetches to `transitionCoordinator.animate(completion:)`.**
  Rejected (P14): the fetch is not what janks the transition, and starting it
  350 ms later is a delay the user pays every time.
- **Making every cache read async "for uniformity".** Rejected (P5): an actor
  hop cannot serve frame 0, which is why `ProfileCache` is `@MainActor` and
  `peekPost` is `nonisolated` — both files say so in their headers.
