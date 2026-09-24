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

A clause that nobody measures is a preference. Three instruments, two of which
exist:

| Instrument | Catches | Status |
|---|---|---|
| `-first-layout-trace` | P15 | shipped (`App/Shell/FirstLayoutTrace.swift`) |
| Hero and profile transition verification (`.claude/skills/verify`) | P9 for hero destinations | shipped |
| **`-presentation-budget`** | P1, P2, P4 | to build (PR 1 below) |

`-presentation-budget` is a DEBUG harness in the same shape as the layout
trace. It swizzles `viewDidLoad` and the first `viewDidLayoutSubviews` of every
`UIViewController` in the app's modules, times them on the main thread, and
logs one line per screen: class, `viewDidLoad` ms, first-layout ms, and the
sum. Over the P2 budget it logs at fault level with a stack sample of the
longest call under the budgeted method, so the report names the culprit rather
than the screen. Under `-presentation-budget-trap` it traps instead, which is
what a UI test runs with. The number is reported in wall-clock ms on the
simulator with a 2.5x factor noted, and verified on the SE for the screens that
fail on the simulator.

The budget test is the same sweep the hero suite already runs (open every
screen from every route), with the trap flag on.

---

## The audit, cut into pull requests

Each PR is one clause made true for one set of screens, verifiable on its own,
and mergeable on green. Order is by user-visible cost, not by size.

### PR 1 — The budget instrument (P2)

`-presentation-budget` and `-presentation-budget-trap` as above, plus the
sweep test. Ships FIRST so every later PR can cite a before/after number
instead of a feeling. No production code changes.

### PR 2 — Media picker off the main actor (P4, P8)

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

### PR 3 — Containers load lazily (P1, P3)

- `ProfileRelationshipsViewController` builds both list pages' views in its
  init (`pages.map(\.view)`); load the opening page only.
- `MessagesInboxViewController.viewDidLoad` calls `loadViewIfNeeded` on every
  surface and on the search results; load the visible one, the rest on first
  select. ⚠️ The unread watermark and the section pill read the catalog, not
  the surfaces, so nothing else observes a page that is not loaded yet —
  verify that claim, do not assume it.

### PR 4 — Stores built once (P4)

`TextPostComposerViewController` receives `postDrafts ?? PostDraftStore()` and
the app never injects it, so every "+" → Text Post reads and decodes the
drafts file synchronously at presentation. Build the store once in the app's
composition root and inject it; the drafts screen shares the instance.

### PR 5 — Pin-opened feed builds its models off the main actor (P13)

The pin path runs `FeedDisplayModelBuilder().build(cached, …)` synchronously
before the push (`FeedFeatureBuilder.swift`), the same text measurement the
feed itself runs in `Task.detached` "by design". Either the seed is prebuilt
when the pin is prewarmed (the prewarm already happens on viewport settle, so
the display models can be warmed with it and peeked like the entries), or the
seed carries entries and the feed measures them off-main after frame 0 over
its skeleton page. The first keeps the measured no-flash arrival, so it is the
one to try first.

### PR 6 — Editor thumbnails render off the main actor (P13)

A reopened draft with edits renders every cell's thumbnail through
`MediaEdits.applied(to:)` on the main actor as the picture arrives
(`MediaEditorViewController.swift`). Run it inside the same detached task the
thumbnail comes from.

### PR 7 — Spinners become skeletons (P8)

Notifications (large spinner, table hidden), Post Detail in `.full` mode,
Search's People results, and the share sheet's target search. Each gets
skeleton rows from the existing components (`PersonSkeletonCell`,
`CommentSkeletonRowView`, `RelationshipSkeletonCell`) laid out at the content's
size. The Maps tab is exempt: the map IS its content, and its clusters arrive
over a drawn map.

### PR 8 — Screens read what the previous screen had (P7)

- Edit Profile refetches `currentUserProfile()` though Profile just rendered
  it; seed from `ProfileCache` and refresh.
- Post Detail calls `loadPost` without trying `peekPost`.
- Profile's first load never reads `ProfileCache` (only account switching
  does); a revisit should render the cached profile at frame 0 and refresh.

### PR 9 — One `Loadable` and one cross-fade (P10, P11)

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
