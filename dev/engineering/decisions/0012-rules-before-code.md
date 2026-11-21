# 0012. Engineering rules and a checklist before any code

Date: 2026-11-21 · Status: Accepted

## Context
The architecture audit (#2366) closed its 23 issues. Its rules lived in `dev/CONVENTIONS.md`, in `CLAUDE.md` (process only), in RepoGuards, and in an agent's private notes that no other developer or agent could read. Several developers and agents work on the repository at once, and a component written without looking at its neighbours had to be refactored later (a hand-drawn avatar per screen, an 8,500-line controller).

## Decision
The owner asked for rules every change follows before its first line of code, for developers and agents alike:
- **The rules live in the repository**, in `dev/engineering/`: before you code, architecture, components, Swift style, testing, a design doc template, and these decision records.
- **Every change starts with the checklist** in [Before you code](../BEFORE_YOU_CODE.md): read the whole issue, find what exists, **survey the similar and neighbouring code, at every layer, and factor what it shares**, size the change.
- **A core or large change starts with research and a design doc** approved by the owner: how the large apps and the platform solve the problem, and the alternatives considered.
- **Decouple by default**: a protocol at every boundary and every service; a shared component at a concept's second use; small files with one responsibility over large ones welded to a feature. Abstractions that only one caller uses and no test needs are not added ahead of need.
- **Rules a scan can check run as guards**; agents' instruction files (`CLAUDE.md`, `AGENTS.md`, path-scoped rules) point to these pages instead of repeating them.

## Consequences
- A developer or agent new to the repository reads one index and one checklist before coding.
- Each pull request carries the checklist, including what similar code was looked at.
- Next steps: the agents' entry points, SwiftLint in CI and new guards (file size, new `shared` instances), then the private notes' durable rules moved here.
