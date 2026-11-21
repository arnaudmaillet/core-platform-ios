# 0008. Per-viewer state is injected and cleared on a viewer change

Date: 2026-11-05 (scoped caches), 2026-11-20 (injected stores) · Status: Accepted · Issues: #2047, #2376

## Context
The app switches viewers: a member signs out to the guest, another account signs in. The feed's repository conformed to nothing that heard the change, so a member's posts were served to the guest (#2047). Stores reached through `shared` globals hid who depended on them, and one keyed by nothing read the previous viewer's data.

## Decision
- **A store that holds the viewer's data is built once by the composition root** and handed to whoever needs it, never reached through a global.
- **Every cache of the viewer's data conforms to `ViewerScoped`** and is listed in `AppContainer.observeViewerTransitions`, which clears it when the viewer changes.
- **Changes are observed on the instance that changed**, through typed APIs, not through `NotificationCenter` names.

## Consequences
- A viewer change clears every viewer's cache, by construction.
- A new store or cache must be wired by the composition root.
- Held by `ViewerStoreGuardTests`, `ViewerScopedGuardTests` and `NotificationNameGuardTests`.
