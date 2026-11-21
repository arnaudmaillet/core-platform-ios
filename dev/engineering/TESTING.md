# Testing

What each layer tests, and where. What runs locally and what runs in CI is in [`CLAUDE.md`](../../CLAUDE.md).

## Frameworks

- **Package tests use Swift Testing** (`import Testing`, `@Test`, `#expect`). Every package test does today; keep it that way.
- **UI tests** live in `UITests/` (the `core-platform-iosUITests` target) and use XCTest. They host on the mock app.

## What each layer tests

| Layer | Tests | Example |
|---|---|---|
| Models, display models, formatters | Pure functions: input → output, no UIKit | a count formats as "1.2k" |
| View models | State changes driven through their protocols' stand-ins | a failed load shows the error state and keeps the cached page |
| Data (repositories, stores, caches) | Behaviour against a stand-in transport or store: paging, merging, eviction, viewer change | a viewer change empties every `ViewerScoped` cache |
| Views and controllers | Layout and contracts that a regression would break silently, in a hosted window when UIKit needs one | the toolbar has one writer |
| Whole flows | UI tests, through the mock app | a guest signs up by code and their like lands |
| The repository's rules | RepoGuards scans | no hand-made avatar |

- **Test behaviour, not implementation.** A test names what the viewer or the caller sees. A refactor that keeps behaviour keeps the tests green.
- **A bug fix starts with a test that fails** without the fix, when the bug can be reproduced in a test.
- **A new rule that a scan can check** joins RepoGuards ([Architecture § Guards](ARCHITECTURE.md#guards)).

## Stand-ins and helpers

- **Stand-ins come through the protocols** the code depends on ([Components § Interfaces](COMPONENTS.md#interfaces)). Mocking a concrete type is a sign that the seam is missing.
- **Shared test helpers live in `Packages/Tools/TestSupport`**: `settle(looks:isolation:until:)` waits for main-actor work to settle instead of sleeping.
- **Fixtures** for the mock backend live in `CoreNetworkingMocks`. A test that needs its own data builds it in the test, not in a shared global.
- **No shared mutable global between tests.** A fake keyboard, a clock or a singleton left set by one suite turns another suite red only when CI is slow. Reset what you set, or inject it.

## Timing

- **Never wait a fixed time.** Wait for the condition (`settle`, an expectation on the state). A fixed sleep is slow when it is long and flaky when it is short.
- **A test that is flaky is a bug.** Open an issue with the run that failed, and fix it or quarantine it with the issue's number. Don't rerun it until it passes and move on.
