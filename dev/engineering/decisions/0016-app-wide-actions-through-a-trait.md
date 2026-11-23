# 0016. An app-wide service a view uses only when touched reaches it through a UIKit trait

Date: 2026-11-23 · Status: Accepted · Issues: #2506, #2376

## Context
The channel card (`PostEmbedView`, PostGrid) needs Chat's actions (Join, Request to join, Open) when its button is tapped. Feed, Maps and PostGrid cannot depend on Chat, so the app used to write the actions into a static at launch, and the tests saved and restored it. The card is built at eight sites, deep in cells: grid and history rows, tiles, the post preview, the comments' caption row, the composer's attachment and the map's text bubble. Handing the actions down through each cell's configuration would have touched about 50 files: the pages, their factories and four feature builders. Yet the value is one instance for the whole app, and no page ever passes a different one.

## Decision
- **The composition root builds the service once** (`ChannelEmbedActionsSource`, Chat's actions made on the first tap) **and sets it on the app's window as a custom trait** (`ChannelEmbedActionsTrait`, through `window.traitOverrides`). Every view under the window inherits it.
- **The view reads the trait when it is used**, at tap time, never to lay out or draw. A missing trait is a wiring fault: the tap does nothing, and DEBUG stops on an assertion. Release never crashes for it.
- **A test, a catalogue or a preview sets its own** on the view it hosts. Nothing global is left to reset.
- **A consumer that is not a view** (a view model) still receives the service explicitly, from its builder's dependencies (`ProfileFeatureBuilder.Dependencies.channelActions`).

A trait environment is right only when **all** of these hold:
- the dependency is **one app-wide service**: one instance for the whole app;
- views read it only **at interaction time**: a tap, a menu, an accessibility action;
- it **never varies per page**.

It is **not** right for anything else, which stays explicit (initializer, builder dependencies, cell configuration):
- anything a view needs to **lay out or render**: an image pipeline, a player pool, a display model, a style;
- anything **per page or per screen**: a page's staking, its saved pile, its router;
- any **viewer state** ([ADR 0008](0008-viewer-state-injected-and-scoped.md)).

## Consequences
- Adding a host of the card costs nothing: it inherits the trait.
- The dependency is no longer visible at the card's construction site. Its doc comment and this record say where it comes from.
- Trait propagation follows the window and its presentations. A card in another window (the app's lock or screen-time windows show none today) would need the trait set there too.
