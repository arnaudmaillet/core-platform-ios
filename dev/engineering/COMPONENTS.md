# Components

How code is cut into pieces. **More files, each small and with one job, beat one large file welded to its feature.**

## One responsibility per type

- **A type does one thing**, and its name says which. If the honest description needs "and", it is two types.
- **A file holds one main type**, and its name is that type's name. Small private helpers of that type may stay in its file.
- **Split by responsibility, never into numbered parts**: one extension per protocol conformance in its own file, the layout in its own file, the data mapping in its own file. `ProfileViewController+Layout.swift` is a split; `ProfileViewController2.swift` is not.
- **A view draws, a view model decides.** A view model holds the screen's state and logic and stays free of UIKit when it can. A display model is what a row or a header shows, built from models outside the view.
- **Prefer composition to inheritance.** Build behaviour from small parts a type holds, not from a base class. Subclass UIKit's classes and the app's few base contracts (`StackScreen`), and nothing deeper.

## Sizes

| What | Should stay under | Must not pass |
|---|---|---|
| A source file | 500 lines | 1,000 lines |
| A type's body | 300 lines | |
| A function | 60 lines | |

- These are signals, not targets: a 400-line file with three jobs still needs a split.
- SwiftLint warns at 500 lines a file and 300 lines a type body (`.swiftlint.yml`). CI runs it on the changed files: an error on a line a pull request adds or modifies fails `build-test`, warnings don't (#2543).
- **On 2026-11-21, 64 source files pass 1,000 lines** (generated contracts aside). The largest is `SnapFeedViewController` at 5,382. None of them may grow. A change that touches one leaves it smaller or the same size, and moves what it adds into a new type. `FileSizeGuardTests` holds this: a new file past 1,000 lines fails, and so does a baseline file that grew. A file that got shorter lowers its baseline number in the same change.

## Splitting a large controller: collaborators with a host

A view controller that has grown to thousands of lines is split into **collaborators**, one per responsibility. The Snap feed's split (#2387) set the pattern: `SnapPagerDrive`, `SnapSoundPlayback`, `SnapCommentsCoordinator`, `SnapZoomDestination`, `SnapToolbarComposer`, `SnapAuthorBar`.

- **Each collaborator owns one responsibility** and the state that goes with it. A piece of state has one writer: `SnapToolbarComposer` is the only code that sets `toolbarItems`.
- **It sees its controller through a narrow protocol**, `<Collaborator>Host`, which lists only what it reads or calls. It never sees the whole controller.
- **It holds its host `unowned`**, since the controller owns it and outlives it. Closures it hands out capture `[weak self]`.
- **The controller creates it lazily** (`private(set) lazy var`) and forwards to it in one line where an outside protocol requires the controller itself to answer.
- **A test pins the forwarding** when the controller must answer for the collaborator (`SnapZoomForwardingTests` checks that every requirement is forwarded).

## Interfaces

A protocol is the seam that lets one side change without the other.

**A protocol is required:**
- at every boundary between modules (a feature's interface, a Core service seen by a feature);
- toward every service with side effects: the network, storage, caches, media playback, the clock, the system (permissions, haptics, audio session);
- wherever a test needs a stand-in;
- wherever two implementations exist or are planned (mock and real backend, two layouts of one surface).

**A protocol is not needed** for a value type, a private helper, or a concrete type used inside one module by one caller with nothing to replace in tests. Add the protocol the day a second implementation or a test needs it. A protocol with one conformer and no test double costs indirection for nothing.

**Shape:**
- **Small and named for the role**: `ProfileItemAccess`, `FeedRealtimeSubscribing`, `ToastAnchoring`. A capability reads as `-ing` or `-able`, a role as a noun. Never `…Protocol` or `I…`.
- **The consumer owns the protocol** when it is a seam for one consumer: the protocol lists what that consumer needs, and the provider conforms (`extension RealtimeClient: FeedRealtimeSubscribing {}`).
- **Compose small protocols** (`A & B`) rather than growing one large one.

## When to share code

This applies to all code, at every layer: views, view models, data, services, navigation, tests and scripts. Before writing a new piece, survey the similar and the neighbouring code ([Before you code § 3](BEFORE_YOU_CODE.md#3-look-at-the-similar-and-the-neighbouring-code)). Then:

- **The same concept under the same rules → one shared implementation.** Some examples:
  - A person's face in a bubble, a header and a row: one picture, one skeleton, the initials without a picture. One `AvatarView`.
  - Paging a list with a server token, in the inbox, the followers and the comments. One `TokenPager`.
  - Keeping fetched content within a budget and releasing it under pressure. One `CacheKit`.
  - A post liked on one screen and shown on another. One `EntityStore`.

  **A second use is the moment to extract.** Don't copy the first one.
- **A resemblance by coincidence → two implementations.** Two rows that share a height today, or two loaders that both retry three times, but that answer to different needs will change for different reasons. Factoring them welds those reasons together. Duplication is cheaper than the wrong abstraction.
- **A single use stays where it is used**, unless it is designed as a core service from the start (a design doc says so).
- **When unsure**, ask the question "if one changes, must the other change too?". Yes: share. No: keep apart.

**How to extract:**
1. **Put it in the lowest layer both users can see.**
   - Kit for models and pure logic (`TokenPager`, `TypedID`).
   - A Core package for a service or a shared domain surface (`CacheKit`, `EntityStore`, `ThreadKit`, `PostGrid`).
   - DesignSystem for a pure visual; MediaCore's `MediaUI` for anything that loads media.
   - TestSupport for a test helper.
2. **Put an interface in front of it** when it crosses a module boundary or does side effects ([Interfaces](#interfaces)). Its users depend on the interface, and the composition root injects the implementation.
3. **Configure it with values, not with its callers' names.** A `Configuration` or a style enum says what varies. A flag named for a caller (`isProfile`, `inChat`) is a leak: replace it with the property it actually changes (`size`, `pageSize`, `showsRing`).
4. **Inject behaviour.** What it works on comes in as a value. What it does goes out through a delegate, a closure or a protocol. The shared piece never imports a feature.
5. **Move the existing use onto it in the same pull request**, so there is never a period with two implementations.
6. **Guard it** when a hand-made copy is easy to write. A RepoGuards scan fails on the copy (`HandMadeAvatarGuardTests`, `ImageCachesOutsidePipelineGuardTests`, `LaunchArgumentReadGuardTests`).

## Shared building blocks

Look here before writing any of these. Add a row when you create a shared piece.

### Data, services and logic

| Concept | Shared piece | Where | Guard |
|---|---|---|---|
| Paging with a server token | `TokenPager` | CoreModels | |
| An entity's identifier | `TypedID` | CoreModels | |
| A post or profile shown on several screens | `EntityStore` | EntityStore | |
| A cache with budgets, trims and release rules | `ManagedCache`, `CacheCoordinator`, `CacheBudgets` | CacheKit | |
| A fetched image | `ImagePipeline` | MediaCore | `ImageCachesOutsidePipelineGuardTests`, `UnsizedImageDecodesGuardTests` |
| Observing a store's changes | `StoreChanges` | CoreStorage | `NotificationNameGuardTests` |
| A cache of the viewer's data | `ViewerScoped` | AuthInterface | `ViewerScopedGuardTests` |
| A handoff of a just-composed post | `ComposedPostChannel` | CoreModels | |
| Who holds the sound | `AudioFocus` | CoreModels | |
| Rewriting a media host | `HostRewrite` | CoreModels | `SharedHelperGuardTests` |
| Notification observer tokens | `NotificationTokens` | CoreModels | `SharedHelperGuardTests` |
| A launch argument | `LaunchArgument` | LaunchArguments | `LaunchArgumentReadGuardTests` |
| Closing a screen | `StackArbiter`, `closeScreen()` | CoreNavigation, DesignSystem | `StackCloseGuardTests` |
| Loader timing | `LoaderGate` | DesignSystem | `LoaderTimerGuardTests` |
| A short count ("1.2k") | `CountFormatter` | DesignSystem | `SharedHelperGuardTests` |
| Waiting in a test for main-actor work | `settle(looks:isolation:until:)` | TestSupport | `SharedHelperGuardTests` |

### Views

| Concept | Component | Where | Guard |
|---|---|---|---|
| A person's face | `AvatarView` | MediaCore / `MediaUI` | `HandMadeAvatarGuardTests` |
| A person in a list | `PersonRowContent`, `PersonListCell` | DesignSystem | |
| Opening a person (card or profile) | `PersonOpening` | MediaCore / `MediaUI` | `PersonOpeningGuardTests` |
| A remote picture | `MediaSlot`, `CoverSlot`, `ImageContentView` | MediaCore / `MediaUI` | `BareImageLoadGuardTests`, `DirectPipelineReadGuardTests` |
| A banner | `HeroBannerView` through `HeroHeaderView` | HeroPage | `HandMadeBannerGuardTests` |
| A page with a hero header | HeroPage | HeroPage | `HeroPageArithmeticGuardTests` |
| A card | `Surface.dressCard` | DesignSystem | `CardContractGuardTests` |
| A toast | `Feedback` | DesignSystem | `ToastGuardTests` |
| A loading state | `AppLoaderView`, `AppRefreshControl`, skeleton rows | DesignSystem | `StockSpinnerGuardTests`, `LoadingTextGuardTests` |
| A button | `AppButton`, `AppIconButton` | DesignSystem | |
| A glyph the app owns | `AppSymbol`, `LikesSymbol`, `SaveStar` | DesignSystem | `OwnedSymbolGuardTests`, `SymbolContractGuardTests` |
| A colour | `Palette` | DesignSystem | `RawHueGuardTests` |
| A font | the scaled type scale | DesignSystem | `ScaledFontGuardTests` |
| A haptic | the haptic roles | DesignSystem | `HapticsGuardTests` |
| A comment or message input | `CommentsInputBar` | ThreadKit | |
| Recording a voice take in a composer, and the microphone's Settings alert | `VoiceComposer`, `offersMicrophoneSettings(from:message:)` | ThreadKit | |

