# 0017. Every stake control spends through one stake session

Date: 2026-11-24 · Status: Accepted · Issues: #2532, #2529, #1375, #957

## Context
Staking likes with an undo toast was written three times: the post detail's composer (`PostDetailComposerBoost`), the Snap page (`SnapBoostController` and `SnapBoostDrive`) and the post cards (`PostCardStaking`). The three followed one rule in different words and drifted in five places that showed on screen: the Snap page kept a burst's tally after its toast had gone (a stale "Undo stakes (N)" that did nothing), counted the next toast from the page's first tap, and never played the "−N" once the viewer had paged on. Two defects were in all three: Undo after a ×100 shot gave nothing back, since the outbox seals a shot at once, and the "−N" said the tally that was asked rather than what came back. The [design doc](../../design/2532-stake-session.md) has the inventory.

## Decision
- **One `@MainActor final class StakeSession`, in PostGrid** (`Staking/`), owns the member gate, the wallet's verdict, the haptics, the receipts on the control, the undo toast and its burst, the undo, the commit and the wallet's observation. PostGrid is the lowest package that sees the wallet, `StakeMenu` and the member gate.
- **A control takes part through `StakeControl`** (the total, the menu's state and the three receipts) and a readout through `StakeTotalShowing`. The session never sees a controller.
- **Configured by values, not by callers.** A host says what varies through which posts it binds, the `lands` check it passes with a stake, the source a stake comes from and when it calls `end()`. There is no `isSnap` and no `isCard`.
- **One rule for every host.** A burst is what the viewer staked on one post since it opened. It ends with its toast's end (which commits it), an undo, or a silent take-back. It is undoable exactly while its toast is up, through the toast or the menu, wherever the viewer has gone (#1375). A shot is final: it never joins the undoable tally, and a shot alone shows its toast without Undo. An undo says what came back: the post's total before minus after.
- **A host holds a `StakeSession?`**, built only when a wallet exists. A Snap page shares its session with the comments panels it embeds, so one post on one screen has one burst and one toast.

## Consequences
- A fix to the rule reaches the post detail, the Snap page and every card at once.
- `SharedHelperGuardTests` fails on `.undoBoost(`, `.commitStakes(`, `StakeMenu.undoToast(` or `StakeMenu.Burst(` anywhere outside `StakeSession.swift` (CoreStorage's definitions aside).
- A change to the session reaches PostGrid's closure of lanes (13 at the time).
- The empty-wallet affordance stays each control's own (the rail and the bar disable, the card chip shakes); the session only pushes the state. *Amended 2026-11-24 (#2554), which the decision left open: every control now behaves as the card chip did. On an empty wallet or a full post it stays live, a refused tap plays `StakeReceipt`'s shake, and the long press keeps the menu with its Shop row.*
