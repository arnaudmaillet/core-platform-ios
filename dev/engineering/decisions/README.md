# Decision records

One short file per architecturally significant decision: why the code is the way it is, so a later change can tell a reason from an accident. The format is Michael Nygard's ([Architecture Decision Record](https://www.martinfowler.com/bliki/ArchitectureDecisionRecord.html)): context, decision, consequences.

- **When to write one:** a change to the architecture (a layer, a boundary, a core service's design, a build or CI shape), a design doc's approved decision, or an owner's ruling that code will keep running into.
- **Never edit a decision to reverse it.** Write a new record that supersedes it, and set the old one's status to `Superseded by NNNN`.
- **Numbering:** the next free four-digit number. The file name is `NNNN-short-title.md`.

Records 0001 to 0011, and 0013 to 0015, were written on 2026-11-21 from decisions already in force; their dates are those of the decisions.

| # | Decision | Status |
|---|---|---|
| [0001](0001-uikit-programmatic-mvvm-c.md) | UIKit, programmatic, MVVM with coordinators | Accepted |
| [0002](0002-package-layers-and-feature-interfaces.md) | Package layers; features reach each other through interfaces | Accepted |
| [0003](0003-connect-bff-and-pinned-contracts.md) | Protobuf contracts pinned, Connect to the BFF, a hand-rolled realtime client | Accepted |
| [0004](0004-mock-backend-in-debug-and-demo-only.md) | The mock backend is linked into Debug and Demo only | Accepted |
| [0005](0005-native-chrome-belongs-to-uikit.md) | Native chrome is shown, hidden and animated by UIKit only | Accepted |
| [0006](0006-screens-close-the-way-they-open.md) | A screen closes the way it opened, through its stack's contract | Accepted |
| [0007](0007-one-implementation-per-concept.md) | One shared implementation per concept, at every layer, held by a guard where it can be | Accepted |
| [0008](0008-viewer-state-injected-and-scoped.md) | Per-viewer state is injected and cleared on a viewer change | Accepted |
| [0009](0009-repo-guards-as-fitness-functions.md) | Repository rules run as tests on every pull request | Accepted |
| [0010](0010-compilation-cache-in-ci-only.md) | Compilation caching in CI only | Accepted |
| [0011](0011-large-controllers-split-into-collaborators.md) | Large controllers split into collaborators behind host protocols | Accepted |
| [0012](0012-rules-before-code.md) | Engineering rules and a checklist before any code | Accepted |
| [0013](0013-a-sound-belongs-to-the-post.md) | A sound belongs to the post, never to one of its media | Accepted |
| [0014](0014-viewport-share-decides-playback.md) | A clip plays while its screen holds half of the display | Accepted |
| [0015](0015-map-clustering-computed-by-the-app.md) | Map clustering is computed by the app, not by MapKit | Accepted |

## Template

```markdown
# NNNN. <Decision, as a statement>

Date: YYYY-MM-DD · Status: Proposed | Accepted | Superseded by NNNN · Issues: #n

## Context
The forces at play: the problem, the constraints, what was measured.

## Decision
What we do, in the active voice.

## Consequences
What becomes easier, what becomes harder, what now has to be held (and by which guard).
```
