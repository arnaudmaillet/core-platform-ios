# 0007. One shared component per visual concept, held by a guard

Date: 2026-10-26 (avatars) onward · Status: Accepted · Issues: #1750, #1752, #1497, #1505

## Context
Concepts the app draws everywhere (a person's face, a banner, a card, a remote picture, a loader, a toast) were drawn by hand in each screen. Each copy got its own skeleton, its own corner radius, its own loading timer; an audit counted seven loader timers with seven delays. A fix in one copy never reached the others.

## Decision
- **Each such concept has one component**, in the lowest layer its users can see: `AvatarView`, `HeroBannerView`, `Surface.dressCard`, `MediaSlot`, `AppLoaderView`, `Feedback` (the full list is in [Components § Shared components](../COMPONENTS.md#shared-components)).
- **A screen injects the component** and configures it with values; it never draws the concept itself.
- **A guard fails on a hand-made copy** wherever one is easy to write (`HandMadeAvatarGuardTests`, `HandMadeBannerGuardTests`, `CardContractGuardTests`, `BareImageLoadGuardTests`, `StockSpinnerGuardTests`…).
- **A new component starts with a survey of the similar ones** ([Before you code § 3](../BEFORE_YOU_CODE.md#3-look-at-the-similar-and-the-neighbouring-components)); a second use of a concept extracts it.

## Consequences
- One fix reaches every screen; the look stays consistent.
- A shared component must be configured by what varies, not by its callers' names, or it turns into a pile of flags.
- Concepts that only look alike by coincidence stay apart.
