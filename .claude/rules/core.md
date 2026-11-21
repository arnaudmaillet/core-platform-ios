---
paths:
  - "Packages/Core/**"
---
# Working in a Core package

Core holds what several features share: services and shared building blocks.

- **Never import a feature or name one.** A shared piece is configured by values (`Configuration`, a style enum), never by a flag named for a caller (`isProfile`, `inChat`). Its behaviour comes in through a delegate, a closure or a protocol ([Components § When to share code](../../dev/engineering/COMPONENTS.md#when-to-share-code)).
- **A service with side effects sits behind a protocol**, so features and tests can inject a stand-in.
- **No new `shared` instance for anything holding viewer state.** The composition root builds it once and injects it (`ViewerStoreGuardTests`).
- **A new shared piece gets a row** in [Components § Shared building blocks](../../dev/engineering/COMPONENTS.md#shared-building-blocks), and a RepoGuards scan when a hand-made copy would be easy to write.
