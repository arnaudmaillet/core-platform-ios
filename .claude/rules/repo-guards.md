---
paths:
  - "Packages/Tools/RepoGuards/**"
---
# Writing a repository guard

- **One guard per rule**, in its own file, with a doc comment that states the rule and the issue behind it ([ADR 0009](../../dev/engineering/decisions/0009-repo-guards-as-fitness-functions.md)).
- **A guard that tracks a migration keeps a baseline** that may only go down, and says so in its failure message.
- **Strip comments before matching** (and string literals where the shape could appear in one), so a comment that quotes the forbidden shape cannot fail the scan.
- **Add the guard to the table** in [Architecture § Guards](../../dev/engineering/ARCHITECTURE.md#guards).
