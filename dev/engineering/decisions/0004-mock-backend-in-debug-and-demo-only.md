# 0004. The mock backend is linked into Debug and Demo only

Date: 2026-11-21 · Status: Accepted · Issues: #2391, PRs #2517, #2518

## Context
The app runs on an in-process mock backend by design: deterministic data for development, UI tests and demos. `CoreNetworkingMocks` is 13,000 lines and 378 MB of clips and photos, and it was linked into every build, Release included. Xcode links a Swift package product into every configuration of a target, as one whole object whose Swift metadata survives dead-stripping, so `#if` alone left 200 mock symbols in Release.

## Decision
The owner chose "Debug and Demo only":
- **`core-platform-ios`** is the mock target. Debug as before; its Release is **Demo** (`DEMO MOCK_BACKEND`, bundle ID `cn.wynn.core-platform-ios.demo`, "Yuyu Demo").
- **`core-platform-ios-production`** is the shipping target (product `YuyuProduction`, the shipping bundle ID). It links the same packages minus `CoreNetworkingMocks`, `CoreRealtimeMocks`, the mock media fixtures (`MediaCoreFixtures`, `MediaPlaybackFixtures`, since #2516) and `DebugTools`, compiles without `MOCK_BACKEND`, and builds in Release only.
- **`AppEnvironment`** chooses the backend once: the mock in mock builds, otherwise the endpoint from the `BFF_HOST` and `REALTIME_URL` build settings.

## Consequences
- The production app is 144 MB with no mock symbol; Demo is 525 MB.
- Every mock name sits behind `MOCK_BACKEND` (`MockBackendGuardTests`); the two targets link the same packages but those five (`TargetParityGuardTests`); CI's `build app` checks the production app carries no mock.
- A new package must be added to both targets.
- The production endpoints still default to localhost and must be set before a store build.
