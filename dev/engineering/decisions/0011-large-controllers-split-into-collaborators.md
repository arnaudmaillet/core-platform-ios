# 0011. Large controllers split into collaborators behind host protocols

Date: 2026-11-20 · Status: Accepted · Issues: #2387, #2514

## Context
`SnapFeedViewController` had grown to 8,539 lines: paging, sound, comments, the zoom transition, the toolbar and the author bar in one type. Every change risked another responsibility, and several pieces of state had many writers.

## Decision
- **A large controller is split into collaborators, one per responsibility**, each owning its state. A piece of state has one writer.
- **A collaborator sees its controller through a narrow protocol**, `<Collaborator>Host`, that lists only what it uses. It holds the host `unowned`; the controller creates it lazily and forwards to it in one line where an outside protocol requires the controller to answer.
- **A test pins the forwarding** where it matters (`SnapZoomForwardingTests`).

## Consequences
- `SnapFeedViewController` went from 8,539 lines to 5,382 in staged pull requests; the rest of the split is #2514.
- The pattern applies to the other controllers past 1,000 lines ([Components § Sizes](../COMPONENTS.md#sizes)).
