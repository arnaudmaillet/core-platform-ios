# 0001. UIKit, programmatic, MVVM with coordinators

Date: 2026-07-06 · Status: Accepted

## Context
The app is a media-heavy social client: paging feeds of video, custom zoom transitions between screens, glass chrome on iOS 26 and later, interactive gestures that must hand over to UIKit's own (the edge pop, sheets). Those need precise control of view lifecycles, layout passes and transitions.

## Decision
- The UI is **UIKit, written in code**: no storyboards, no layout library. Views are laid out with native anchors and DesignSystem's helpers.
- A screen is a **view controller with a view model** (MVVM). Coordinators and the router move between screens.
- **Swift 6 language mode**; the app target isolates to the main actor by default.
- SwiftUI is not used for screens. One file uses it, for a rendering effect only.

## Consequences
- Transitions, gestures and chrome can be driven exactly, with UIKit's own API.
- More code per screen than SwiftUI would need. The shared components ([0007](0007-one-implementation-per-concept.md)) and DesignSystem's helpers keep it in check.
- View models stay free of UIKit where they can, so they test without a window.
