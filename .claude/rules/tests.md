---
paths:
  - "**/Tests/**"
  - "UITests/**"
---
# Writing tests

- **Package tests use Swift Testing** (`@Test`, `#expect`). UI tests in `UITests/` use XCTest and host on the mock app.
- **Never wait a fixed time.** Wait on the condition: `settle(looks:isolation:until:)` (TestSupport) or the state itself.
- **No shared mutable global between tests**: reset what you set, or inject it. A leaked fake turns another suite red only when CI is slow.
- **Name a test as a sentence about behaviour.**
- ⚠️ **CI NEVER COMPILES `UITests/`.** After editing a UI test, run `xcrun swiftc -parse` on the file at least, and dispatch `hero-uitests.yml` on the branch before opening the pull request.
- Details: [Testing](../../dev/engineering/TESTING.md).
