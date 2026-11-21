---
paths:
  - "Packages/Features/**"
---
# Working in a feature package

- **Never import another feature.** Reach it through its `…Interface` package. A view another feature owns crosses as a protocol in its interface, a maker in the feature, and a `make…` closure on your builder wired by `App/Composition/AppContainer+<Feature>.swift` ([Architecture](../../dev/engineering/ARCHITECTURE.md#a-features-view-worn-by-another-feature)).
- **Folders**: `<Feature>FeatureBuilder.swift`, `Data/`, `DisplayModels/`, `ViewModels/`, `Views/`, or a large surface's own folder.
- **The builder names what it needs**: no capability casts, no `= nil` defaults (`BuilderDependenciesGuardTests`).
- **Before writing a pager, a cache, a store, a loader or a view** that another feature might have, look in [Components § Shared building blocks](../../dev/engineering/COMPONENTS.md#shared-building-blocks). Code that two features need moves down to Core.
- **View models** call repositories or services through protocols, never a generated client.
- **No file past 1,000 lines may grow.** Split by responsibility, with collaborators behind `…Host` protocols ([Components](../../dev/engineering/COMPONENTS.md#splitting-a-large-controller-collaborators-with-a-host)).
