# Design doc: one stake session (#2532)

Issue: #2532 · Status: **approved** (the decisions are at the end) · Follows #2523 and #2529 (PR #2552) · Part of the #2519 follow-ups · Decision record: [ADR 0017](../engineering/decisions/0017-one-stake-session.md)

Read at `develop` `d6e84e54d`, together with the diff of PR #2552. Line numbers are those of `d6e84e54d`.

## Summary

- Staking likes with an undo toast is written three times: `PostDetailComposerBoost` (post detail), `SnapBoostController` and `SnapBoostDrive` (Snap page), and `PostCardStaking` (post cards). `StakeMenu`, `StakeMenu.Burst`, `StakeMenu.undoToast` and `WalletStaking` are already shared. #2552 shares the receipts.
- The three copies follow one rule, but in different words. They have drifted in five places that show on screen. Two of the drifts are bugs on the Snap page, and one bug is in all three copies: the Undo of a ×100 shot gives nothing back.
- Proposal: one `@MainActor final class StakeSession` in **PostGrid**, next to `PostCardStaking`, which becomes its first user. It owns the gate, the wallet verdict, the haptics, the receipts on the control, the undo toast and its burst, the undo, the commit and the wallet observation. A control takes part through a small `StakeControl` protocol.
- **Two pull requests**, both based on `develop` after #2552 has merged:
  - A: the session, the cards and the post detail. 13 lanes.
  - B: the Snap page, the riskiest piece, alone. Feed and RepoGuards only. It also adds the guard and closes the issue.
- Three questions for the owner, listed at the end.

## 1. Inventory

### 1.1 Where the stake session lives today

| Piece | File:line | What it does |
|---|---|---|
| **Post detail** (the comments panel's composer: embedded in every Snap page, the comments sheet, the text post's draft panel) | `Feed/PostDetail/PostDetailComposerBoost.swift:30` | One post per screen. Tally `sessionBoostAmount` (:45), one `Burst` for the screen (:81). |
| | `PostDetailComposerBoost.swift:108-156` | `composeBar.onBoost`: gate `MemberGates.perform(.like)` (:111), re-check `showsPostActions` (:114), draft notice (:117-119), `wallet.stake` (:120), haptic `.commit`, receipt on the bar, toast `StakeMenu.undoToast` (:135-149), refusal `.error` + `playBoostDenied` (:150-153). |
| | `:56-69`, `:75-78`, `:86-99`, `:167` | Undo (menu and toast), commit unless the toast is up, the bar's context, the wallet observation. |
| | `PostDetailViewController.swift:324, 368, 592, 648` | Lazy collaborator; commits on **every** `viewDidDisappear`; refreshes on publish; installs. |
| **Snap page**, arithmetic and tally | `Feed/Snap/SnapBoostController.swift:19` | One post at a time: `sessionID` + `sessionAmount` (:68-69). `stake` maps the wallet outcome to a `Verdict` (:78-98); `undo` (:104-112); `anchorContext` (:126-131); `pageResigned` and `finalize` commit unless `toastHolds` (:137-159). |
| **Snap page**, on screen | `Feed/Snap/SnapBoostDrive.swift:40` | Gate (:54-58), re-check `unavailablePostIDs` (:63), haptic, receipt on the cell, toast (:78-110), refusal and DEBUG `-wallet-log` lines (:116-131), undo (:137-144), silent take-back (:155-167), `closeStakeToastIfSettled` (:172-179), one `Burst` per post (:184), refresh of every visible cell (:186-197). |
| | `SnapFeedViewController.swift:97, 334, 421` | Owns both. |
| | `SnapFeedViewController.swift:1306-1325` | Cell wiring: `onRequestBoost`, `onRequestBoostUndo`, total and context on configure. |
| | `SnapFeedViewController.swift:1090-1091, 2108-2109, 1726` | Finalize on pop or dismiss, on page resign, and the take-back when a post turns unavailable. |
| | `SnapNavigationBarComposer.swift:295-299` | Second wallet observation: the badge, then `refreshVisibleBoostControls`. |
| | `SnapToolbarComposer.swift:413-415` | The text page's footer like: a fourth door to the same spend. |
| | `SnapZoomDestination.swift:652`, `SnapToolbarComposer.swift:375` | Read the total. |
| **Post cards** | `Core/PostGrid/Cells/PostCardStaking.swift:37` | One object per surface, many posts: `session: [String: Int]` (:52), one `Burst` per post (:320), a weak map of bound rows (:47). |
| | `PostCardStaking.swift:86-121, 223-242` | `bind` (tap and menu) and `stakeMenu(for:from:)`, the post's "…" menu (`PostSurfaces/Grid/PostMenuRows.swift:53`). |
| | `:244-270`, `:272-285`, `:290-317`, `:323-330` | Gate, `wallet.stake`, haptics, receipt on the bound row, undo, toast from the cell's nearest view controller (`screen(of:)`, :338), commit clears the tally. |
| | `:76-78`, `:196-200` | Wallet observation (redraws bound rows). `endSession` commits except the live toast's post. |
| | `PostCardStaking.swift:79`, `:149-184` | **Not staking:** the live counts (`EntityStore`) and the save glyph. They stay where they are. |
| Card owners | `Feed/PostGridsAssembly.swift:126` → `PostSetSurfaceViewController.swift:648` (ends on `viewDidDisappear`) | |
| | `App/Composition/AppContainer+Profile.swift:189` → `ProfileViewController.swift:619` (ends on `viewDidDisappear`) | |
| | `Place/PlaceFeatureBuilder.swift:228`: **one** instance shared by the pushed list and the gallery; `PlaceProfileViewController.swift:754` | Never call `endSession`. |
| **Already shared** | `DesignSystem/Components/StakeMenu.swift`: `State` (:13), `Burst` (:186), `undoToast` (:212, id `stake-<source VC>-<post>` at :224), `closeUndoToast` (:231) | |
| | `CoreStorage/WalletReading.swift:35`, `WalletStaking`; `WalletStore.swift:1111` `stake`, `:1145` `commitStakes` (seals the outbox batch), `:1219` `undoBoost` (cancels unsealed taps only) | |
| | `CoreStorage/LikeOutbox.swift:117` | A shot is a batch **sealed at once**. |
| | `LikeOutbox.swift:129` | `cancel` skips sealed batches and shots. |
| | After #2552: DesignSystem `StakeReceipt` | Played through each control's pass-throughs: `SnapFeedCell.playBoost*`, `CommentsInputBar.playBoost*`, `PostGridListRowCell.playStake*`. |

### 1.2 Drift between the three copies

| Concern | Post detail | Snap page | Post cards |
|---|---|---|---|
| Tally scope | One post, the screen's life | One post, the active page | Every post, the surface's life |
| Wallet nil | Inert | Inert | No `PostCardStaking` (host passes nil) |
| Re-check after the gate | `showsPostActions` | `!unavailablePostIDs.contains` | Row still bound (receipt only; the stake lands anyway) |
| Haptics, receipt order, refusal | `.commit` / `.error`, total then "+N", no toast on refusal | same | same |
| **Tally after the toast ends (commit)** | Cleared | **Kept until the page resigns** | Cleared |
| **Next tap after the toast ended** | New toast counts from 0 | **Toast counts every tap since the page became active**, including likes already sent | New toast counts from 0 |
| **Menu Undo after the toast ended** | None | **"Undo stakes (N)" stays, does nothing** (the outbox is sealed), and keeps the rail's button enabled on an empty wallet | None |
| **Menu Undo while the toast is still up, after leaving and coming back** | None (a new controller each visit) | None (`finalize` clears the tally) | Kept (`endSession` keeps the live toast's post) |
| "−N" when undone from the toast after moving on | Played if the controller is alive | **Not played** (total only) | Played on the bound row |
| Commit when leaving | Every `viewDidDisappear`, a push on top included | Pop or dismiss, and page resign | `viewDidDisappear` (Profile, post sets); **never** (Place, its pushed list and gallery) |
| Toast identity | `stake-<panel VC>-<post>` | `stake-<Snap VC>-<post>` | `stake-<cell's nearest VC>-<post>` |
| Silent take-back (post unavailable) | No | Yes (:1726) | No |
| DEBUG `-wallet-log` | No | Yes | No |

The "commit when leaving" row shows no visible difference. Every burst has a toast, and the toast's end commits it. The outbox's 10 s idle commit covers the rest (`LikeOutbox.idleCommitDelay`).

A text page shows the panel's bar and the Snap page's rail or footer like for **one** post (`PostDetailComposerBoost.swift:36-39`). Today that is two tallies and two toasts, and each toast settles the other.

### 1.3 Defects in all three copies (found by reading the code; to be confirmed by a test and a capture)

1. **A shot cannot be undone, yet all three copies offer Undo for it.** `stake(.shot)` records a batch sealed at once (`LikeOutbox.swift:117`), and `undoBoost` takes back only unsealed taps (`WalletStore.swift:1219`, `LikeOutbox.swift:129`). For a member, Undo after a shot returns nil:
   - the toast closes and nothing comes back;
   - the menu keeps "Undo stakes (100)".
   
   `undoBoost` also never gives the shot back to the pack. The tests miss this because their wallets have no outbox (`CardStakeTests.swift:226-241`).
2. **The "−N" says the request, not what came back.** All three play the whole tally as the refund (`PostDetailComposerBoost.swift:60`, `SnapBoostController.swift:108`, `PostCardStaking.swift:283`). After taps plus a shot, Undo returns the taps but shows "−(taps+100)" and clears the tally.

## 2. The proposed single owner

### 2.1 Prior art and where it fits

- **A deferred commit with an undo window.** Gmail's Undo Send holds the action for a window chosen by the user, and sends it only when the window ends ([help](https://support.google.com/mail/answer/2819488)). Our outbox does the same: a batch is sealed when the toast ends.
- **One action in a snackbar.** Material's snackbar allows one action, such as Undo, and shows one snackbar at a time ([guidelines](https://m3.material.io/components/snackbar/guidelines)). `Feedback`'s single undo slot already follows this.
- **An undo scope object.** Apple's `UndoManager` keeps one undo stack per scope and groups registered inverse actions ([docs](https://developer.apple.com/documentation/foundation/undomanager)). The session plays the same role: one per surface, with one group (a burst) per post. `UndoManager` itself is not used. It is built for undo and redo stacks driven by menus and gestures. We want no redo, and our window is a toast that must outlive the surface.

The app combines the two models. The local debit is optimistic and instant: `WalletStore` debits under its lock before any pixel moves. The server commit is deferred to the end of the toast. Nothing here changes `WalletStore` or the outbox.

### 2.2 Where it lives

`Packages/Core/PostGrid/Sources/PostGrid/Staking/`, in two files: `StakeSession.swift` (about 250 lines) and `StakeControl.swift`.

PostGrid is the lowest existing package that sees all three things the session needs:
- the wallet (`CoreStorage`);
- the toast, `StakeMenu` and `StakeReceipt` (`DesignSystem`);
- the member gate (`CoreNavigation`).

ThreadKit (`CommentsInputBar`) and Feed already depend on PostGrid. This respects Kit ← Core ← FeatureInterfaces ← Features ← App, and adds no edge.

| Alternative | Why not |
|---|---|
| A new Core package (`StakeKit`) | PostGrid would depend on it, so every change to it still runs PostGrid's closure, plus one more lane. It is a new package for no lane saving. Worth it only if the cards' staking leaves PostGrid one day. |
| DesignSystem | It sits below the wallet (`StakeMenu.swift:7-9`). |
| CoreStorage, logic only | It leaves the gate, the toast, the receipts and the refresh in three copies, which is the issue itself. |
| Feed | PostGrid's cards cannot see Feed. |
| Do nothing | The drifts and bugs in § 1.2 and § 1.3 stay, and a fix in one copy keeps missing the others. |

### 2.3 The rule it enforces (one rule for every host)

- **A burst** is what the viewer staked on one post since the burst opened. It opens with the first spend, holds the undoable likes, and owns the post's undo toast.
- A burst ends with **exactly one** of these:
  - **the toast's end** (time, a swipe, the background, or another undoable toast), which commits it (`commitStakes`);
  - **an undo**, from the menu or the toast;
  - **a silent take-back**, when the post turns unavailable.
- **A burst is undoable exactly while its toast is up**, through the toast or the menu, wherever the viewer has gone (#1375). The next tap after a burst ended opens a new burst from 0.
- **`end()`**: the surface left. A burst that has no toast (no screen was found to show it) is committed now. Bursts with a toast are left to their toast.
- The **undo** takes back what the outbox still holds. The "−N" and the new total say **what came back**: the target's total before the undo minus the total after it.
- **Shots:** see open question 1.

### 2.4 API (sketch)

```swift
/// A control that wears one post's stake: the rail's like pill, the bar's
/// boost bubble, a card's like chip. The receipts are #2552's StakeReceipt.
@MainActor
public protocol StakeControl: AnyObject {
    func showStake(total: Int, state: StakeMenu.State, animated: Bool)
    func playStakeSpend(_ amount: Int)
    func playStakeRefund(_ amount: Int)
    func playStakeRefusal()
}

/// A readout that only wears the total (For You's compact cards, a tile).
@MainActor
public protocol StakeTotalShowing: AnyObject { func showStakeTotal(_ total: Int) }

@MainActor
public final class StakeSession {
    public init(wallet: any WalletStaking)

    // Controls: weakly held and keyed by the control, as PostCardStaking does today,
    // so a recycled cell is simply bound again. Every wallet change redraws them all.
    public func bind(_ control: any StakeControl, to post: PostID)
    public func bind(_ readout: any StakeTotalShowing, to post: PostID)
    public func unbind(_ control: AnyObject)

    // Spending: gate → lands() → wallet → haptic → receipt on the bound control → toast.
    public func stake(_ spend: WalletStakeSpend, on post: PostID, from source: UIResponder,
                      lands: @escaping @MainActor () -> Bool = { true })
    public func undo(on post: PostID)                 // the menu's Undo
    public func takeBack(_ post: PostID)              // silent: the post turned unavailable
    public func end()                                 // the surface left

    // Reading
    public func total(on post: PostID) -> Int
    public func menuState(for post: PostID) -> StakeMenu.State
    public func menu(for post: PostID, from source: UIResponder) -> UIMenu?   // nil for a guest (#1146)
    /// Extra things a host redraws on a wallet change (the Snap footer like).
    public var onChange: (@MainActor () -> Void)?
}
```

- **Configured by values, not by callers.** It has no `isSnap` and no `isCard`. What varies between hosts goes in through the arguments:
  - **the scope**, given by which posts the host binds and when it calls `end()`;
  - **the availability re-check**, given by `lands`;
  - **the source** of the toast.
- **The toast's identity** stays `StakeMenu.undoToast`'s (`stake-<source VC>-<post>`). The session raises every toast of a burst from the screen of the burst's **first** spend, as long as that screen lives. A burst shared by two controls then updates one toast in place. DesignSystem is not touched. Even when the screen has gone and a new id appears, the replaced toast's commit is skipped: it shares the burst's `StakeMenu.Burst` generation.
- **The DEBUG `-wallet-log` lines** move into the session, so they cover every surface. The declaration moves from `LaunchArgument+Feed.swift:71` to `LaunchArgument+PostGrid.swift`.

### 2.5 Dependencies

| Dependency | How |
|---|---|
| **Wallet** | `any WalletStaking` is injected. The session is built only when a wallet exists, so hosts hold a `StakeSession?`, and `nil` keeps today's inert controls. It makes one `changes.observeOnMain` observation. This replaces the three today, and Snap's second one in `SnapNavigationBarComposer` keeps only the badge. |
| **Toast** | `StakeMenu.undoToast` → `Feedback.undoable` (ToastGuard stays green). The screen is found up `source`'s responder chain, as the cards do today. |
| **Gate** | `MemberGates.perform(.like, from: source)`. For a guest, the body runs in a `Task` after sign-up, which is why `lands()` is asked again. |
| **Menu** | `StakeMenu.menu(for: menuState…)`. The rail and the bar keep building their own `StakeMenu.elements` from the `State` the session pushes through `showStake`, which is unchanged for them. |

### 2.6 Swift 6 isolation

- `StakeSession`, `StakeControl` and `StakeTotalShowing` are `@MainActor`. `WalletStaking` is `Sendable` and synchronous, guarded by `WalletStore`'s `NSLock`, so the main actor calls it directly in the tap's turn. "Wallet first, before any pixel moves" holds.
- Each burst is a small internal `@MainActor final class` that holds the wallet, the post, the amount and its `StakeMenu.Burst` generation.
  - The toast's `@MainActor` closures capture the burst **strongly** and the session **weakly**. An undo or a commit after the surface is gone goes through the wallet directly, as all three copies do today.
  - A live session redraws its controls through its wallet observation.
- The `deinit` is nonisolated and only drops the `StoreObservation`, which cancels in its own `deinit`. There is nothing to undo, because the toasts own their bursts.
- The design needs no `@unchecked Sendable`, no `nonisolated(unsafe)`, no `assumeIsolated` and no isolated `deinit`. It uses nothing newer than what Xcode 26 compiles today.

### 2.7 How each host adopts it (ADR 0011)

The session is a Core service that a host owns, not a collaborator of one controller. It never sees a controller:
- a control reaches it through `StakeControl`;
- an availability check reaches it through `lands`.

Where a controller already has a collaborator for the boost, that collaborator shrinks to wiring.

**Cards (PostGrid):**
- `PostCardStaking` keeps its public API. Its stake half becomes calls to an owned `StakeSession`: about 200 of its 375 lines go. **No host source changes**: Profile, Place, Chat, Feed and App are untouched.
- `PostGridListRowCell` conforms to `StakeControl`, and the readouts to `StakeTotalShowing`, each in a `+StakeControl.swift` file.
- `endSession()` forwards to `end()`.

**Post detail (Feed):**
- `PostDetailViewController` takes a `stakes: StakeSession?` instead of its `wallet`, which only the boost reads (`:320-341`). The file stays at or under its 1,122-line baseline.
- `PostDetailComposerBoost` shrinks to the wiring:
  - `bind(composeBar, to: postID)` once published;
  - `onBoost` → `stakes.stake(…, lands: { host.showsPostActions })`;
  - `onBoostUndo` → `undo`;
  - the draft notice stays here.
- `viewDidDisappear` calls `end()` only when the panel owns its session.
- `CommentsInputBar` conforms to `StakeControl` in a new `CommentsInputBar+StakeControl.swift` (ThreadKit), so its 1,000+ line file does not grow.

**Snap page (Feed):**
- `SnapBoostController` and `SnapBoostDrive` are deleted.
- `SnapFeedViewController` holds `let stakes: StakeSession?`:
  - configure binds the cell;
  - `onRequestBoost` → `stake(…, lands: { !unavailable.contains(id) })`;
  - `markPostUnavailable` → `takeBack`;
  - pop or dismiss → `end()`;
  - **page resign calls nothing** (see § 3, row 4).
- `SnapFeedCell` conforms to `StakeControl` in its own file. `refreshVisibleBoostControls` goes: bound cells redraw on wallet changes, and `onChange` refreshes the footer like.
- `SnapToolbarComposerHost` and `SnapZoomDestinationHost` swap `var boost: SnapBoostController` for `var stakes: StakeSession?`.
- **The Snap page hands its session to the comments panels it embeds**: the panel factory in `PostCommentsAssembly.makePanelFactory` takes it. The text post's draft panel and other standalone panels build their own.

## 3. Behaviour each host would see

The aim is captures that match the current ones, apart from the fixes below, each listed for approval.

| # | Change | Post detail | Snap page | Post cards | Recommendation and reason |
|---|---|---|---|---|---|
| 1 | The tally ends with the toast | no change | **Fixed:** no stale "Undo stakes (N)" after the toast; the next toast counts from 0; on an empty wallet the rail disables once the toast has gone | no change | **Adopt.** It is today's rule in two of the three, and the Snap version shows wrong numbers. |
| 2 | "−N" and the total say what came back | Differs only after a shot | same | same | **Adopt.** A receipt must not promise what the wallet didn't do. That is the rule #2552 states for spends. |
| 3 | Shots | see Q1 | see Q1 | see Q1 | Q1 |
| 4 | Menu Undo while the toast is up, after leaving or paging and coming back | n/a, or one session with the page (row 6) | **New:** the Undo entry stays while the post's toast is up | no change | **Adopt the cards' rule** (Q2). #1375 made the toast the undo window, and the menu agreeing with the visible toast is the plainer rule. |
| 5 | "−N" when undone from the toast after moving on | no change | **New:** played if a cell still shows the post | no change | **Adopt.** It is the same receipt everywhere, and `StakeReceipt` drops it off screen anyway. |
| 6 | One session for the Snap page and its embedded panels | **New:** the bar and the rail or footer share one tally and one toast on a text page | same | — | **Adopt** (Q3). It is one post on one screen, and today each control's toast settles the other's burst. |
| 7 | A burst's toasts rise from the screen of its first spend | (row 6) | (row 6) | Place's pushed list and gallery share one instance: one toast per post across them | **Adopt.** It follows from row 6, and DesignSystem stays untouched. |
| 8 | Commit on leaving | no visible change (`end()` commits only a toastless burst) | same | same | **Adopt.** No timing changes in practice, since every burst has a toast. Place keeps not calling `end()`: a toastless burst there falls back to the outbox's 10 s idle commit, as today. |
| 9 | Silent take-back API | not used (one session with the page) | no change | not used | Offer it. Adopt it elsewhere only when a host learns unavailability. |
| 10 | Empty-wallet affordance (rail and bar disable when they have nothing to offer; the card chip stays live and shakes) | no change | no change | no change | **Out of scope:** it is each control's own choice, and the captures must match. It is worth a follow-up issue, because the disabled button also hides the menu's Shop row. |
| 11 | DEBUG `-wallet-log` | **New** | no change | **New** | Adopt (DEBUG only). |

## 4. Pull request plan

Both pull requests are **based on `develop` after #2552 has merged**, not stacked on it. The conformances call #2552's receipt pass-throughs and touch the same three files (`SnapFeedCell`, `CommentsInputBar`, `PostGridListRowCell+Actions`). There is one commit per pull request, for #2532.

| PR | Contents | Packages | Lanes (`select_packages.py` closure) | Risk |
|---|---|---|---|---|
| **A**. Stake session (#2532, 1/2): `StakeSession` in PostGrid; the post cards and the post detail move onto it | `Staking/StakeSession.swift`, `StakeControl.swift`; `PostCardStaking` slimmed; row and readout conformances; `CommentsInputBar+StakeControl.swift`; `PostDetailComposerBoost` → wiring; `PostDetailViewController` takes `stakes`; the Feed builders that make a panel pass a session. COMPONENTS row; this doc as `dev/design/2532-stake-session.md`; ADR 0017 "One stake session". | PostGrid, ThreadKit, Feed, RepoGuards (baselines), docs. No DesignSystem change. | **13**: Chat, DebugTools, Feed (2 shards), HeroPage, Maps, Place, PostGrid, Profile, ProfileData, Settings, ThreadKit, Wallet, plus RepoGuards. Feed costs no extra lane. | Breadth of lanes: every card host recompiles. The public API stays, so the risk is low. |
| **B**. Stake session (#2532, 2/2): the Snap page moves onto it, its panels share it, the guard | Deletes `SnapBoostController`, `SnapBoostDrive` and `SnapBoostControllerTests`; `SnapFeedCell+StakeControl.swift`; `SnapFeedViewController`, `SnapNavigationBarComposer`, `SnapToolbarComposer`, `SnapZoomDestination`, `PostCommentsAssembly`; removes Feed's `walletLog`; the new SharedHelperGuard test; baselines. | Feed, RepoGuards | Feed (2 shards) + RepoGuards | **The riskiest piece, alone:** paging, a toast that outlives a page, unavailable posts, and a panel embedded in a page. `Closes #2532`. |

- B waits for A to merge, then branches from a fresh `develop`. It is stacked on A only if the owner prefers speed to a second rebase.
- After approval, ADR 0017 and the design doc file land with A, following the `design-first` skill.

## 5. Tests, captures and guards

### Tests

All tests stay in their own lanes. Locally, per CLAUDE.md: one Debug app build plus `build-for-testing` of the touched packages, and no suites.

- **`StakeSessionTests` (PostGrid, new)** uses a member wallet with a `LikeOutbox`, so undo behaves as it does on a device. It takes over `SnapBoostControllerTests`' cases (clamp, refusals, nil wallet) and the burst cases of `CardStakeTests`:
  - a toast updated in place;
  - the toast's end commits and clears;
  - leaving keeps the toast's Undo;
  - an undo through the toast after the session is released;
  - the menu Undo while the toast is up.
  
  It adds:
  - row 1 (no stale tally);
  - row 2 (refund equals what came back, with a mixed tap and shot burst);
  - Q1's shot rule;
  - one session with two controls (one toast);
  - `takeBack`;
  - `end()` with a toastless burst.
  
  It uses a fake `StakeControl` that records calls. The suites that raise toasts take the `.ownsToastClock` trait (TEST_TRAPS).
- **`CardStakeTests`** keeps its public-API tests. `aShotFromACardStakesAHundredAndUsesOneShot` follows Q1.
- **ThreadKit:** one test that `showStake` maps onto `setBoostTotal` and `setBoostContext`.
- **Feed:**
  - `BoostControlTests` is unchanged (the controls).
  - `SnapUnavailablePostTests` and `UnavailablePostActionsTests` move to `takeBack`.
  - A forwarding test (ADR 0011) checks that the cell's boost request and the footer like reach the session (`debugTapBoost`).
  - A test checks that an embedded panel uses its page's session: one toast id.

### Captures (done-when)

- **What:** before is `develop` after #2552; after is each pull request's head. On each of the three surfaces:
  - a stake;
  - the undo toast;
  - undo from the toast after leaving the screen;
  - a wallet that runs out.
  
  Plus the changed states:
  - Snap: the long-press menu after the toast has ended, and a second burst's toast;
  - cards: Undo after a shot (Q1);
  - text page: one toast for the bar and the footer.
- **How:** #2552's recipe.
  - Launch: `-open-feed -snap-start-index 3 -snap-start-paused -mock-likes-still`; `-open-create text -text-post-send "Boost me"` for the bar; `-open-profile prof-13` for a card.
  - An empty wallet comes from writing `mock.wallet.accounts`.
  - Taps are injected touches.
  - Images are pushed to the `assets/2532-screenshots` branch.
- **Which pull request:** A shows cards and post detail, B shows the Snap page and the text page.

### Guards

| Guard | Change |
|---|---|
| **SharedHelperGuardTests** (PR B, once the copies are gone) | New test: `wallet.undoBoost(`, `.commitStakes(on:`, `StakeMenu.undoToast(` and `StakeMenu.Burst(` appear in no source outside `PostGrid/Staking/StakeSession.swift`. CoreStorage's own definitions are excepted. Comments and strings are stripped before matching. The test gets a row in Architecture § Guards. |
| **FileSizeGuardTests** | Files past 1,000 lines that are touched may only shrink, and each baseline is lowered in the same pull request: `SnapFeedViewController.swift` (3,050), `SnapFeedCell.swift` (1,485), `PostDetailViewController.swift` (1,122), `CommentsInputBar.swift` (3,142 after #2552). New conformances go in their own files. `StakeSession.swift` stays under 500 lines. |
| BarContractGuardTests | Not touched. No bar item is built or replaced: the footer like keeps `SnapToolbarComposer.refreshFooterLike`. |
| ToastGuard, LayeringGuard, SharedInstanceGuard, BuilderDependenciesGuard | Stay green. Toasts go through `Feedback`. No new package or edge. No `shared` instance: each host builds its session. Builder dependencies are unchanged, because `wallet` already reaches every builder that will make a session. |

## 6. Open questions for the owner

1. **Shots in the undo window.** A ×100 shot is sealed and sent at once (`LikeOutbox.swift:117`), and `undoBoost` never returns it, nor the shot to the pack. Yet the toast and the menu offer Undo for it, and that Undo does nothing.
   - **(A) A shot is final (recommended).** It is not added to the undoable tally. A shot alone shows a stake toast **without** Undo ("Staked 100 likes"). In a mixed burst, the Undo takes back the taps and says so.
   - (B) A shot can be undone during its toast. This changes CoreStorage: the shot batch is sealed only when the toast ends, and `undoBoost` refunds the shot to the pack. It reaches CoreStorage's 16 package lanes and changes the wallet's semantics.
   - (C) Keep today's behaviour. Not recommended: it is an Undo that lies.
2. **The menu's Undo while the toast is still up, after leaving or paging away and coming back.**
   - **Keep it, as the cards do (recommended):** the toast is the undo window (#1375), and the menu should agree with it.
   - Drop it, as the Snap page does: "undo until you move on", from before #1375.
3. **One session for the Snap page and the comments panels it embeds.**
   - **Share it (recommended):** one tally and one toast for one post on one screen.
   - Keep one session per panel: two toasts that settle each other, as today.

Not questions, but follow-ups to file after approval:
- the empty-wallet affordance (§ 3, row 10);
- `PostCardStaking` keeps two jobs that are not staking (live counts, save glyph) and could be renamed or split later.

## Decisions (recorded on #2532)

The doc's recommendation was taken each time:

1. **Shots: (A), a shot is final.** It stays out of the undoable tally. A shot alone shows a stake toast without Undo. In a mixed burst, Undo takes back the taps only. CoreStorage is not touched.
2. **The menu's Undo while the toast is up, after leaving or paging away and back: kept**, as the cards already did. The toast is the undo window (#1375).
3. **One session for the Snap page and the comments panels it embeds: shared.**

The pull request plan is § 4's: A (the session, the cards, the post detail), then B (the Snap page), stacked on A.

