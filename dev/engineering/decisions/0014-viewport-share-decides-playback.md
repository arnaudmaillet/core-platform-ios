# 0014. A clip plays while its screen holds half of the display

Date: 2026-10-30, covers 2026-11-01 · Status: Accepted · Issues: #1914, #1970

## Context
Each screen started and stopped its clips on its own appearance callbacks. During a push, a grab or a sheet, two screens played at once, or neither did, and a sheet over a feed left the feed playing under it. The player cannot see what slides over its view, and the same post plays under different rules in Shots, a grid and a place page.

## Decision
The owner set the rule, and [`dev/VIEWPORT_PLAYBACK.md`](../../VIEWPORT_PLAYBACK.md) specifies it:
- **A clip plays while its screen holds at least half of the display and nothing covers it.** Where a screen fades its sound, the sound follows the share.
- **The rule belongs to the screen**, measured by one `ViewportShare` per screen (CoreNavigation) against the window. A covered screen follows its cover's measure and takes the exact complement, so two shares always add up to 1 and two screens never play together.
- **Covers are read from the window** (`ScreenCovers`). An app sheet with several detents declares when it covers (`ScreenCovering`).

## Consequences
- A new screen that plays media adopts `ViewportShare` rather than wiring play and pause to its appearance.
- Held by `ScreenCoveringGuardTests` for app sheets that do not declare.
- One asset plays through one player, so a surface that pauses while another plays the same post holds its last frame.
