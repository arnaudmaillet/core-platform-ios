# Swift style

How code reads. This page builds on two references and does not repeat them:

- Apple's [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): **clarity at the point of use** comes first, and clarity beats brevity.
- The [Airbnb Swift Style Guide](https://swift.airbnb.tech/) for what the guidelines leave open.

Formatting is the formatter's (`swiftformat`) and the linter's (`swiftlint`, `.swiftlint.yml`). `Scripts/lint.sh` runs both.

## Naming

- **Types and protocols are UpperCamelCase; everything else is lowerCamelCase.** Acronyms follow the case of the word's position: `urlString`, `profileURL`, `HTTPClient`.
- **Name for the role, not the type.** `let author: Profile`, not `let profile: Profile` when the profile is the author. `retryDelay`, not `timeInterval`.
- **Judge a name at its call site.** `pipeline.image(for: url, size: .thumbnail)` reads as a sentence; `pipeline.getImage(url, 1)` does not. Omit words the types already say.
- **Booleans read as assertions**: `isMuted`, `hasUnread`, `canReply`, `shouldAutoplay`.
- **Functions with side effects are verbs** (`load()`, `follow(_:)`); functions that return a value without side effects are nouns or read as one (`displayModel(for:)`, `distance(to:)`).
- **No vague suffixes.** `Manager`, `Helper`, `Utils`, `Handler` and `Controller` (outside view controllers) say nothing about the job. Name the job: `FollowStateStore`, `CountFormatter`, `ProfileRouter`.
- **Protocols** are named for a capability (`-ing`, `-able`: `FeedRealtimeSubscribing`) or a role (a noun: `ProfileItemAccess`). Never `…Protocol` or an `I` prefix.
- **A collaborator's host protocol** is `<Collaborator>Host` (`SnapPagerDriveHost`).
- **A feature's entry** is `<Feature>FeatureBuilder`; its interface's builder protocol is `<Feature>FeatureBuilding`.
- **Launch arguments** start with the feature's name: `-profile-open-post`, `-maps-wide-region`.
- **Tests** read as a sentence about behaviour: `aCutToastsTapOpensTheSheetNotTheAction()`, not `testToast3()`.

## Access control

- **Start `private`, widen when needed.** `internal` for the module, `package` for the package's other targets, `public` only for what another package uses.
- **A `public` declaration is a promise** to every package that imports it. Keep public surfaces small, and give each public type a doc comment.
- **`final` by default** for classes no one subclasses.

## Values and types

- **Prefer value types** (`struct`, `enum`) for models, display models and configurations. Use a class for identity and shared mutable state.
- **Make illegal states unrepresentable**: an enum with associated values beats three optionals that must agree.
- **Typed identifiers** (`TypedID`) instead of bare `String` ids, so a post id can't be passed as a profile id.
- **No force unwraps or `try!`** outside tests, except on a value the code just proved (a literal URL); say why in a comment.

## Concurrency

- **Stored tasks.** Store a `Task` you may need to cancel, or that outlives the call that starts it (`private var loadTask: Task<Void, Never>?`), and cancel it when its owner goes or starts again. A fire-and-forget `Task {}` is fine only for work that ends by itself and touches nothing once the owner has gone: capture `[weak self]`.
- **`MainActor.assumeIsolated`** is for callbacks that UIKit or Foundation documents as arriving on the main queue (a `NotificationCenter` block registered with `queue: .main`, a display link). Never use it to silence the compiler in other cases.
- **Deferred work.** Prefer a stored `Task` with `try await Task.sleep` over `DispatchQueue.main.asyncAfter`. The task can be cancelled, and tests can wait on it.
- **Notification observers.** Keep observer tokens in `NotificationTokens` (CoreModels). A `@MainActor` owner's `deinit` may not touch its own tokens, so don't hand-roll another box. `replace(with:)` unregisters the previous tokens.
- **Nested types that cross tasks** inside a `@MainActor` class are marked `nonisolated` and `Sendable` explicitly.
- **A superseded load publishes nothing.** Cancelling a task does not stop it from publishing: cancelled network calls can fail rather than throw `CancellationError`. Check a load generation after every `await`, the failure branch included.
- **Order-sensitive calls run in the task itself**, not in `async let`, whose child tasks may start in either order.
- **Closures handed to an Objective-C framework** that calls back on its own queue (PhotoKit, MediaPlayer, KVO) are `@Sendable` or built in a `nonisolated` function. Treat an `#ActorIsolatedCall` warning as an error. More in [Platform traps § Swift concurrency](PLATFORM_TRAPS.md#swift-concurrency).

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

Look for a helper before you write one. A second copy of these fails `SharedHelperGuardTests`.

| Need | Helper |
|---|---|
| A count in short form ("1.2k") | `CountFormatter` (DesignSystem) |
| A blur whose strength varies (0…1) | `ProgressBlurView` (DesignSystem) |
| A control shaking its head | `StakeReceipt` for a stake's refusal, `AppControl.fail()` for a failed action (DesignSystem) |
| Notification observer tokens | `NotificationTokens` (CoreModels) |
| Waiting in a test for main-actor work to settle | `settle(looks:isolation:until:)` (TestSupport) |
| Rewriting a media host | `HostRewrite` (CoreModels) |
| Who holds the sound | `AudioFocus` (CoreModels) |

Every shared building block, from data and services to views, is listed in [Components § Shared building blocks](COMPONENTS.md#shared-building-blocks).
