# Architecture

How the app is put together, and the rules that keep it modular. The reasons behind each rule are in the [decision records](decisions/README.md).

## The stack

- **UIKit, programmatic.** No storyboards, no layout library. Views are laid out with native anchors and DesignSystem's helpers ([ADR 0001](decisions/0001-uikit-programmatic-mvvm-c.md)).
- **MVVM with coordinators.** A screen is a view controller with a view model. Coordinators and the router move between screens.
- **Swift 6 language mode.** The app target isolates to the main actor by default.
- **Local Swift packages** hold almost all the code. The app target holds the composition only.

## Packages and layers

```
Kit  ←  Core  ←  FeatureInterfaces  ←  Features  ←  App
                         Tools (TestSupport, RepoGuards): anyone may use them
```

| Layer | Holds | Examples |
|---|---|---|
| **Kit** | Models, contracts, small value helpers. No UIKit. | `CoreModels`, `CoreContracts`, `LaunchArguments` |
| **Core** | Services and UI shared by several features | `DesignSystem`, `MediaCore`, `CacheKit`, `CoreNetworking`, `ThreadKit`, `PostGrid` |
| **FeatureInterfaces** | What one feature offers the others: value types, builder protocols, routes | `ProfileInterface`, `FeedInterface`, `WalletInterface` |
| **Features** | One product area each: its screens, view models and data | `Feed`, `Profile`, `Chat`, `Maps`, `Wallet` |
| **App** | The composition root, the scene, the shell | `App/Composition/AppContainer+*.swift` |

Rules ([ADR 0002](decisions/0002-package-layers-and-feature-interfaces.md)):

- **A package depends only on its own layer or the layers to its left.** `LayeringGuardTests` reads every `Package.swift`. Its list of allowed exceptions names an issue for each and may only shrink.
- **A feature never depends on another feature.** It reaches the other one through that feature's interface.
- **Code that two features need goes down to Core**, never into one feature that the other reaches.
- **Every module a target imports is declared in its own `Package.swift`.** A clean build resolves only declared modules.
- **Inside one package**, `package` access lets its targets see each other without making anything `public`.
- **Code moved from the app into a package keeps the app's isolation.** The app target isolates to the main actor by default with approachable concurrency; packages are nonisolated by default, so moved code fails to compile or, worse, compiles with another meaning. The receiving target uses `swift-tools-version: 6.2` with `.defaultIsolation(MainActor.self)`, `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` (as `DebugTools` and `Wallet` do). A new package the app links is added to both app targets ([ADR 0004](decisions/0004-mock-backend-in-debug-and-demo-only.md)).

### What goes in a feature interface

Value types, builder protocols and routes. No views, and no dependency heavier than the values need.

### A feature's folders

```
Sources/<Feature>/
  <Feature>FeatureBuilder.swift     the one entry: builds screens for the router
  Data/                             repositories, stores, caches, wire mapping
  DisplayModels/                    what a row or a header shows, built from models
  ViewModels/                       one per screen, @MainActor, UIKit-free when possible
  Views/                            view controllers, cells, views
  <Surface>/                        a large surface may group its own Data/Views (Chat/Inbox, Feed/Snap)
```

### A feature's view worn by another feature

When feature B must show a view that feature A owns (the profile shows the feed's post grid):

1. A protocol for the view in **A's interface** (`FeedInterface`).
2. A public maker in **A** (`Feed`).
3. A `make…` closure on **B's builder**, which the composition root wires in `App/Composition/AppContainer+<B>.swift`.

B never imports A.

## The composition root

`App/Composition/` builds everything: `AppContainer` and one `AppContainer+<Domain>.swift` per domain. Nothing else in the app creates services.

- **Outside the composition root, the app imports feature interfaces only** (`CompositionRootGuardTests`).
- **A feature's builder names what it needs.** No capability casts and no `= nil` defaults on its dependencies (`BuilderDependenciesGuardTests`). A dependency that is optional is optional in the protocol, on purpose.
- **The backend is chosen once**, by `AppEnvironment`: the mock backend in mock builds, the configured backend otherwise. Mock code compiles only under `MOCK_BACKEND` ([ADR 0004](decisions/0004-mock-backend-in-debug-and-demo-only.md)).

## Dependency injection

- **Inject through the initializer.** A type receives what it uses; it does not reach for it.
- **Depend on a protocol at every boundary**: between modules, toward a service (network, storage, cache, media playback, clock), and wherever a test needs a stand-in. Inside one module, a concrete type is fine until a second implementation or a test needs the seam. See [Components § Interfaces](COMPONENTS.md#interfaces).
- **No new `shared` instance for anything that holds state a viewer or a test cares about.** A store that holds the viewer's data is built once by the composition root and handed to whoever needs it (`ViewerStoreGuardTests`).
  - A process-wide resource with no viewer state may stay shared: a render context, a hardware-bound player, a log. Its declaration says why.
  - 49 `shared` instances predate this rule (EmoteKit, VoiceKit, DesignSystem…). They are not a pattern to copy. `SharedInstanceGuardTests` keeps them in a baseline that may only shrink, and fails on a new one unless it is listed as process-wide with its reason. Inject the instance instead when you touch one.
- **Launch arguments** are read through a declared `LaunchArgument` (Kit/LaunchArguments), never a raw string (`LaunchArgumentReadGuardTests`).

## State

- **Per-viewer state is injected and scoped.** Every cache that holds the viewer's data conforms to `ViewerScoped` and is listed in `AppContainer.observeViewerTransitions`, which clears it when the viewer changes (`ViewerScopedGuardTests`, [ADR 0008](decisions/0008-viewer-state-injected-and-scoped.md)).
- **Changes are observed on the instance that changed**, through typed APIs (`StoreChanges`, `observeChanges`), not through `NotificationCenter` names (`NotificationNameGuardTests`).
- **One cache for each kind of content.** Images live in `ImagePipeline` on `CacheKit`, never in a cache of a screen's own (`ImageCachesOutsidePipelineGuardTests`).

## Navigation

- **A screen asks the router to go somewhere**: `router.route(to:)`. Only the router and the stack coordinators push, present or pop.
- **A route lands on the surface it was fired from.** `RouteResolver` resolves the active stack through the presented chain (`MainTabCoordinator.activeNavigationController`), so a route from a presented sheet or feed pushes on that surface, not under it on the covered tab.
- **Every pushed screen states how it is left**: it is a `StackScreen` (`StackScreenGuardTests`). It closes through `closeScreen()` or `closePresentation()`, never a raw `popViewController(` or `dismiss(animated:` (`StackCloseGuardTests`).
- **A screen closes the way it opened**: a native push gets a native pop, and a custom opening gets its custom close ([ADR 0006](decisions/0006-screens-close-the-way-they-open.md)).
- **Native chrome belongs to UIKit**: the navigation bar, the tab bar, the toolbars and system sheets are shown, hidden and animated by UIKit's own API, never by hand ([ADR 0005](decisions/0005-native-chrome-belongs-to-uikit.md)).

## Backend

- The server's API is the protobuf contracts, generated into `Kit/CoreContracts` by `Scripts/generate-contracts.sh` and pinned by `.contracts-pin` ([ADR 0003](decisions/0003-connect-bff-and-pinned-contracts.md)).
- A feature reaches the backend through a repository or service protocol in its `Data/` folder. A view model never calls a generated client itself.

## Guards

Each guard in `Packages/Tools/RepoGuards` holds one rule across the whole repository. A new rule that a scan can check reliably joins them.

| Area | Guards |
|---|---|
| Sizes and injection | `FileSizeGuardTests`, `SharedInstanceGuardTests` |
| Layers and composition | `LayeringGuardTests`, `CompositionRootGuardTests`, `BuilderDependenciesGuardTests`, `TargetParityGuardTests`, `MockBackendGuardTests`, `DebugToolsGuardTests` |
| State | `ViewerStoreGuardTests`, `ViewerScopedGuardTests`, `NotificationNameGuardTests`, `LaunchArgumentReadGuardTests` |
| Navigation | `StackScreenGuardTests`, `StackCloseGuardTests`, `ScreenCoveringGuardTests`, `AppWindowGuardTests`, `PersonOpeningGuardTests` |
| Shared components | `HandMadeAvatarGuardTests`, `HandMadeBannerGuardTests`, `CardContractGuardTests`, `BarContractGuardTests`, `HeroPageArithmeticGuardTests`, `TitledHeaderTopEdgeGuardTests`, `ToastGuardTests`, `SharedHelperGuardTests` |
| Images and media | `BareImageLoadGuardTests`, `DirectPipelineReadGuardTests`, `HandWrittenImageLoadGuardTests`, `ImageCachesOutsidePipelineGuardTests`, `UnsizedImageDecodesGuardTests`, `MediaGroundScanGuardTests` |
| Loading states | `StockSpinnerGuardTests`, `LoaderTimerGuardTests`, `LoadingTextGuardTests`, `SkeletonCrossfadeGuardTests`, `SkeletonGroundScanGuardTests` |
| Look and feel | `RawHueGuardTests`, `ScaledFontGuardTests`, `HapticsGuardTests`, `OwnedSymbolGuardTests`, `PlayPauseSymbolGuardTests`, `SymbolContractGuardTests`, `EmptyActionGuardTests` |

A guard that counts what is left to convert keeps a baseline. A file's count may only go down.
