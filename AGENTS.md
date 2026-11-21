# Agents working in this repository

This file is for any coding agent (Codex, Cursor, Copilot, Claude Code…). Read these before you change anything:

1. **[`dev/engineering/BEFORE_YOU_CODE.md`](dev/engineering/BEFORE_YOU_CODE.md)**: the checklist every change follows before its first line of code.
   - Read the whole issue.
   - Find what exists.
   - Survey the similar and neighbouring code at every layer, and factor what it shares.
   - Size the change.
   - For a core or large change: research, then a design doc the owner approves.
2. **[`dev/engineering/README.md`](dev/engineering/README.md)**: the index of the rules (architecture, components, Swift style, testing, decision records).
3. **[`CLAUDE.md`](CLAUDE.md)**: how changes land. Rebase on a fresh `origin/develop`, build locally, open a pull request and stop: one coordinator merges, in queue order, never you. CI and pushing rules are there too.

## In short
- iOS app, UIKit written in code, MVVM with coordinators, Swift 6, local Swift packages in layers: Kit ← Core ← FeatureInterfaces ← Features ← App. A feature never imports another feature.
- Inject dependencies through initializers. Put a protocol at every module boundary and every service. Add no new `shared` instance for viewer state.
- One shared implementation per concept, at every layer. Look in [Components § Shared building blocks](dev/engineering/COMPONENTS.md#shared-building-blocks) before writing a pager, a cache, a store, an avatar, a loader…
- No file past 1,000 lines may grow. Split by responsibility.
- `Packages/Tools/RepoGuards` scans the repository on every pull request. A failing guard names the rule you broke.
