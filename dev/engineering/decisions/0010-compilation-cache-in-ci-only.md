# 0010. Compilation caching in CI only

Date: 2026-11-18 · Status: Accepted · Issues: #2369

## Context
A clean app Debug build takes about 127 s. Xcode's compilation cache keys hold absolute paths (the DerivedData and worktree paths), so a fresh DerivedData mostly misses: 286 misses against 43 hits. Prefix mapping makes the keys path-free, but crashed the build service on every build on Xcode 27.2. Each store costs 1.6–1.9 GB on a shared disk.

## Decision
- **CI's app Debug build caches**, since its paths are the same on every run: it restores and saves the store (develop saves only), with a fallback that rebuilds without the cache if the build service crashes.
- **No compilation caching in the project for local builds**, and no prefix mapping until a newer Xcode fixes the crash.

## Consequences
- Local builds stay as they were; CI's app build gets faster.
- Retest prefix mapping on each new Xcode: one cold build, then one in a fresh DerivedData.
