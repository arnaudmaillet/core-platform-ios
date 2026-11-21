# 0006. A screen closes the way it opened, through its stack's contract

Date: 2026-11-01 (rule), 2026-11-04 (contract) · Status: Accepted · Issues: #1144, #2015

## Context
Screens were closed from many places by raw `popViewController` and `dismiss` calls, and one gesture could close two screens. The post feed is a pager, so the page on screen at the close is often another kind than the one that opened it, and the code chose the close from the content: a natively pushed feed paged onto a photo could close with a zoom flight.

## Decision
- **Every pushed screen is a `StackScreen`** and states how it is left. It closes through `closeScreen()` (its stack's arbiter) or `closePresentation()`, never a raw pop or dismiss.
- **A screen closes the way it opened**: a native push gets a native pop, whatever the content has become; a custom opening (a zoom flight, the text window) gets a custom close. The fallback slide when the landing is lost is the only exception.

## Consequences
- One arbiter per stack decides every close; gestures and calls cannot race.
- A transition issue states its opening family and adds an acceptance case for a page paged onto the other kind.
- Held by `StackScreenGuardTests` and `StackCloseGuardTests`.
