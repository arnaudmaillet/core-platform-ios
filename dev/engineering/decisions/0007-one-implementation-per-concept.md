# 0007. One shared implementation per concept, at every layer

Date: 2026-10-26 (avatars) onward, widened 2026-11-21 · Status: Accepted · Issues: #1750, #1752, #1497, #1505, #890, #2519

## Context
The same concepts were written again in each place that needed them.
- **On screen:** a person's face, a banner, a card, a remote picture and a loader were drawn by hand in each screen. Each copy got its own skeleton, its own corner radius, its own loading timer. An audit counted seven loader timers with seven delays.
- **Below the screen:** the app cached content in about 25 places, each with its own rules (#890). Screens disagreed after a like or a delete because no store was shared.

A fix in one copy never reached the others.

## Decision
- **Each concept has one implementation**, in the lowest layer its users can see. This applies at every layer:
  - data and logic: `TokenPager`, `TypedID`, `EntityStore`, `CacheKit`, `ImagePipeline`, `StoreChanges`;
  - navigation: `StackArbiter`;
  - views: `AvatarView`, `HeroBannerView`, `Surface.dressCard`, `MediaSlot`, `AppLoaderView`, `Feedback`;
  - tests: `settle`.
  
  The full list is in [Components § Shared building blocks](../COMPONENTS.md#shared-building-blocks).
- **Users inject it**, through an interface when it crosses a module or does side effects, and configure it with values. They never write the concept again themselves.
- **A guard fails on a hand-made copy** wherever one is easy to write (`HandMadeAvatarGuardTests`, `ImageCachesOutsidePipelineGuardTests`, `LaunchArgumentReadGuardTests`, `SharedHelperGuardTests`…).
- **New code starts with a survey of the similar and neighbouring code** ([Before you code § 3](../BEFORE_YOU_CODE.md#3-look-at-the-similar-and-the-neighbouring-code)). A second use of a concept extracts it.

## Consequences
- One fix reaches every user, and behaviour stays consistent.
- A shared implementation must be configured by what varies, not by its callers' names, or it turns into a pile of flags.
- Pieces that only look alike by coincidence stay apart.
