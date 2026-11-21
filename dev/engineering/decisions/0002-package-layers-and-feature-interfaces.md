# 0002. Package layers; features reach each other through interfaces

Date: 2026-07-06, guarded since 2026-11-18 · Status: Accepted · Issues: #2366, #2371, #2375

## Context
A single app target grows into one module where everything can see everything: every change recompiles everything, and any screen can reach into any other. Large iOS codebases solve this with feature modules that cannot see each other and talk through thin interface modules (Airbnb's feature interfaces, Tuist's modular architecture).

## Decision
- Code lives in **local Swift packages in five layers**: Kit ← Core ← FeatureInterfaces ← Features ← App. A package depends only on its own layer or the layers to its left. Tools (TestSupport, RepoGuards) may be used by anyone.
- **A feature never imports another feature.** It reaches it through the other feature's interface package: value types, builder protocols and routes. A feature's view worn by another crosses as a protocol in the interface, a maker in the feature, and a `make…` closure wired by the app.
- **The app is the composition root.** Outside `App/Composition/`, it imports feature interfaces only.

## Consequences
- Features build and test alone; a change in one does not recompile the others.
- Code two features need must move down to Core, which takes a deliberate step.
- Held by `LayeringGuardTests` (every `Package.swift`; exceptions name an issue and may only shrink), `CompositionRootGuardTests` and `BuilderDependenciesGuardTests`.
