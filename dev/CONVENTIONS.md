# Conventions

How code is laid out and written in this repository. Audit #2366, item #2390.

The rules that a scan can check reliably run in `Packages/Tools/RepoGuards`, which every pull request runs:
- `LayeringGuardTests` checks the layers;
- `SharedHelperGuardTests` holds one implementation per shared helper;
- `DebugToolsGuardTests` keeps the debug tools `#if DEBUG`.

The rest of this page is review, not a scan. The concurrency and error rules have too many legitimate exceptions for a count to judge, so a reviewer holds new code to them.

## Packages and layers

```
Kit  ←  Core  ←  FeatureInterfaces  ←  Features  ←  App
                         Tools (TestSupport, RepoGuards): anyone may use them
```

- **Who may depend on whom.** A package depends only on its own layer or the layers to its left. A feature never depends on another feature: it reaches the other feature through that feature's interface. `LayeringGuardTests` checks every `Package.swift`. Its list of allowed exceptions names an issue for each and may only shrink.
- **What goes in a feature interface.** Value types, builder protocols and routes. No views, and no dependency heavier than the values need.
- **Where shared code goes.** Code that two features draw belongs in Core (for example `ThreadKit`, `PostGrid`, `HeroPage`), never in one feature reached by the other.
- **Inside one package**, `package` access lets its targets see each other without making anything `public`. Profile's `ProfileSettings` target uses this.

## A feature's folders

```
Sources/<Feature>/
  <Feature>FeatureBuilder.swift     the one entry: builds screens for the router
  Data/                             repositories, stores, caches, wire mapping
  DisplayModels/                    what a row or a header shows, built from models
  ViewModels/                       one per screen, @MainActor, UIKit-free when possible
  Views/                            view controllers, cells, views
  <Surface>/                        a large surface may group its own Data/Views (Chat/Inbox, Feed/ForYou)
```

A file holds one main type, and its name is that type's name. Split a file once it passes about 1,500 lines. Split it by responsibility (an extension per protocol, a model file, a layout file), not into numbered parts.

## Navigation

- **Who pushes.** A screen asks the router to go somewhere: `router.route(to:)`. Only the router and the stack coordinators push, present or pop.
- **How a screen closes.** Every screen a stack holds conforms to `StackScreen` and says how it leaves (`leaving`). See `StackScreenGuardTests` and `StackCloseGuardTests`.
- **Matching the opening.** A screen closes the way it opened: a native push gets a native pop, and a custom opening gets its custom close.

## Concurrency

- **Stored tasks.** Store a `Task` you may need to cancel, or that outlives the call that starts it (`private var loadTask: Task<Void, Never>?`), and cancel it when its owner goes or starts again. A fire-and-forget `Task {}` is fine only for work that ends by itself and touches nothing once the owner has gone: capture `[weak self]`.
- **`MainActor.assumeIsolated`** is for callbacks that UIKit or Foundation documents as arriving on the main queue (a `NotificationCenter` block registered with `queue: .main`, a display link). Never use it to silence the compiler in other cases.
- **Deferred work.** Prefer a stored `Task` with `try await Task.sleep` over `DispatchQueue.main.asyncAfter`. The task can be cancelled, and tests can wait on it.
- **Notification observers.** Keep observer tokens in `NotificationTokens` (CoreModels). A `@MainActor` owner's `deinit` may not touch its own tokens, so don't hand-roll another box. `replace(with:)` unregisters the previous tokens.

## Errors

- **Network failures.** `try?` on a network call drops the failure silently. Use `do`/`catch`, and either show the failure (an error state, a toast, a retry) or log it with what was being done. Keep `try?` for failures that carry no information worth keeping: decoding an optional cache, removing a file that may not exist, a `Task.sleep` that was cancelled.
- **Errors the viewer sees.** Write the viewer-facing error in words the viewer understands, never the server's message.

## Comments

A comment says **why** the code is the way it is, and **the trap** it avoids. Mark a trap with ⚠️ and capitals on its first words, so it stands out on a skim.

History belongs in commits and pull requests, not in sources:

- **Issue numbers.** Use one in a comment only when the reader would need it to understand a rule (`#2145: tap opens the card, hold opens the profile`). Don't add one for every change.
- **Dates.** Write one only beside a measurement that may age, such as "measured on iOS 27, 2026-10-12".
- **Old behaviour.** Don't describe how the code used to work ("used to", "was", "before #…") unless the old way is a tempting trap.

## Shared helpers

Look for a helper before you write one:

| Need | Helper |
|---|---|
| A count in short form ("1.2k") | `CountFormatter` (DesignSystem) |
| A blur whose strength varies (0…1) | `ProgressBlurView` (DesignSystem) |
| Notification observer tokens | `NotificationTokens` (CoreModels) |
| Waiting in a test for main-actor work to settle | `settle(looks:isolation:until:)` (TestSupport) |
| Rewriting a media host | `HostRewrite` (CoreModels) |
| Who holds the sound | `AudioFocus` (CoreModels) |
