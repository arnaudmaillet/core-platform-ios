# Engineering rules

The rules every change to this repository follows, whoever writes it: a developer or an agent. **Read [Before you code](BEFORE_YOU_CODE.md) before you start any change.** It says which of the other pages your change needs.

| Page | What it rules |
|---|---|
| [Before you code](BEFORE_YOU_CODE.md) | The checklist before the first line: the issue, what exists already, the similar and neighbouring code at every layer, research, the plan |
| [Architecture](ARCHITECTURE.md) | Packages and layers, feature interfaces, the composition root, dependency injection, state, navigation |
| [Components](COMPONENTS.md) | How code is cut: one responsibility per type, sizes, when a component becomes shared, how a large controller is split |
| [Swift style](SWIFT_STYLE.md) | Naming, API shape, access control, concurrency, errors, comments |
| [Testing](TESTING.md) | What each layer tests, where test helpers live, what runs where |
| [Design doc template](DESIGN_DOC_TEMPLATE.md) | The document a core or large feature starts from |
| [Decisions](decisions/README.md) | Architecture decision records: why the code is the way it is |

The process rules (merging, CI, pushing) are in [`CLAUDE.md`](../../CLAUDE.md) at the root.

## Where agents meet these rules

| Entry point | Read by | What it does |
|---|---|---|
| [`AGENTS.md`](../../AGENTS.md) | every coding agent (Codex, Cursor, Copilot…) | points here and to `CLAUDE.md`, with the rules in short |
| [`CLAUDE.md`](../../CLAUDE.md) | Claude Code, every session | imports `AGENTS.md`, opens with *Before you code*, then the process rules |
| `.claude/rules/*.md` | Claude Code, when it reads or edits a matching file | the rules of the layer being edited: Kit, Core, interfaces, features, app, tests, guards, CI |
| `.claude/skills/design-first/` | Claude Code, for a core or large change | the research → design doc → owner's approval procedure |
| `.github/pull_request_template.md` | every pull request | the checklist, including the *Similar code* line |

When a rule here changes, update the entry point that repeats it.

## How the rules are held

A rule that a machine can check runs as a test. The rest is held in review.

- **`Packages/Tools/RepoGuards`** runs on every pull request. Each guard scans the sources for one rule. The guards are listed in [Architecture § Guards](ARCHITECTURE.md#guards).
- **Package boundaries** are held by the compiler: a target can only import what its `Package.swift` declares, and `LayeringGuardTests` checks the declarations.
- **Review** holds what a scan cannot judge: naming, the size of an abstraction, whether the similar code was looked for.

When a review comment repeats, write the rule into a guard.

## Strength of a rule

- **Must** / **never**: no exception without a written reason in the pull request, and an issue when the exception should go away.
- **Should** / **prefer**: the default. Depart from it when the reason is stated in the code or the pull request.

## Changing a rule

A rule changes by a pull request to these pages. A change in architecture also adds a [decision record](decisions/README.md). The owner approves both.
