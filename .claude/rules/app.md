---
paths:
  - "App/**"
---
# Working in the app target

- **`App/Composition/` is the composition root**: `AppContainer` and one `AppContainer+<Domain>.swift` per domain build every service and feature. Outside it, the app imports feature interfaces only (`CompositionRootGuardTests`).
- **Mock code compiles only under `MOCK_BACKEND`** and lives in `App/Composition/MockBackend/` (`MockBackendGuardTests`). The production target links no mock ([ADR 0004](../../dev/engineering/decisions/0004-mock-backend-in-debug-and-demo-only.md)).
- **A new package is added to both app targets**, `core-platform-ios` and `core-platform-ios-production`, unless it is one of the mock-only three (`TargetParityGuardTests`).
- **A viewer's cache** conforms to `ViewerScoped` and joins `observeViewerTransitions`' list (`ViewerScopedGuardTests`).
