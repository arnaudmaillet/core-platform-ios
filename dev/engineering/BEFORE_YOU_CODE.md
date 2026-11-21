# Before you code

Every change goes through these steps before its first line of code. Steps 1 to 4 apply to every change. Steps 5 and 6 depend on the change's size, which step 3 decides.

## 1. Read the whole issue

- Read the body **and every comment**. A later comment often changes the scope or carries the owner's decision.
- Find the **done-when** (acceptance criteria). If the issue has none, write them in the issue before you start.
- Note the issues it links: an epic, a predecessor, a decision it depends on.
- A pull request writes `Closes #n` only when every item of the done-when is met. Otherwise it writes `Part of #n`.

## 2. Find what exists

Before writing a type, a helper or a view, look for one that already does the job:

- [Swift style § Shared helpers](SWIFT_STYLE.md#shared-helpers) lists the helpers each need has.
- [Components § Shared components](COMPONENTS.md#shared-components) lists the components each concept has (avatar, banner, loader, toast, card, media slot…).
- Search the code by **concept**, not only by type name: `rg -i "avatar|face|portrait" Packages App`.
- Read the [decisions](decisions/README.md) that touch the area. They say why the code is shaped the way it is, and which shapes were already rejected.

## 3. Look at the similar and the neighbouring components

**A new component, screen or service starts with a survey of the components that look like it or sit next to it.**

1. **List the similar ones.** These draw the same concept, hold the same kind of state or answer the same need somewhere else. A new profile header that shows a face is similar to every row, bubble and card that shows a face.
2. **List the neighbours.** These are the components the new one will sit beside, talk to or be shown with: the screen that hosts it, the cells around it, the service it reads.
3. **Compare.** For each similar component, decide what the new one shares with it:
   - **The same concept with the same rules** (a person's face: the picture, its skeleton, the initials without one). **Factor it**: extract one component, or reuse the one that exists, and inject it into both places. Do the extraction in the same pull request, or in a pull request just before it.
   - **The same look by coincidence** (two lists that happen to have the same row height). **Don't factor.** Two things that change for different reasons stay two things. See [Components § When to make a component shared](COMPONENTS.md#when-to-make-a-component-shared).
4. **Write it down.** The pull request's **Similar components** section names what you looked at and what you decided: factored, reused, or kept apart and why.

Example: the message bubble draws an avatar inline, and the profile page now needs one too. Don't draw a second avatar in the profile. Move the bubble's avatar into the shared `AvatarView` (MediaCore's `MediaUI`), or use it where it exists already, and have both the bubble and the profile use it. `HandMadeAvatarGuardTests` fails on an avatar drawn by hand.

## 4. Size the change

| Size | What it is | What it needs before code |
|---|---|---|
| **Small** | A fix, a tweak, one screen's change within one package | Steps 1–3 |
| **Feature** | A new screen or flow over existing services, at most two pull requests | Steps 1–3 and a short plan in the issue (step 6) |
| **Core or large** | Any of: a core service (cache, networking, realtime, storage, media playback, navigation and transitions, the economy, authentication), a new package, a new contract between features, more than two pull requests | Steps 1–3, research (step 5), a [design doc](DESIGN_DOC_TEMPLATE.md) approved by the owner, then the plan |

When unsure between two sizes, take the larger.

## 5. Research before a core or large change

A core service is a problem others have solved at scale. Find out how before designing one.

- **Look at how the large apps do it**: the social networks and messaging apps whose scale is ahead of ours (Instagram, TikTok, WhatsApp, Discord, Telegram, X), through their engineering blogs, conference talks and open-source code.
- **Look at the platform**: Apple's documentation, WWDC sessions, the frameworks that already do part of the job.
- **Look at the literature** when the problem has one (cache eviction, feed ranking, sync protocols).
- **Write what you found** in the design doc's *Prior art* section, with links. Name at least two approaches and why the chosen one fits this app.
- **Spike when reading is not enough.** A throwaway branch that measures the question (a build time, a decode cost, a memory peak) beats a guess. Record the figures and the device in the design doc.

Example: the device cache (epic #890, `Packages/Core/CacheKit`) was designed in the style of large social apps, after looking at how they cache. Almost everything is cached, every screen opens on its last known content, and content is released by priorities and byte budgets. `dev/CACHE_AUDIT.md` then measured the budgets instead of guessing them.

## 6. Plan the change

- **Pull requests by area.** Group a large piece of work into a few pull requests, one commit per issue, and keep the riskiest piece in a pull request of its own (see `CLAUDE.md`).
- **Name the packages each pull request touches.** CI tests only the packages a pull request reaches.
- **Name the verification**: which suites the change reaches, and whether simulator captures are needed (a visible change, or a structural move that must show no visible change).
- **Name the decisions you need from the owner** and ask them before coding, not in the pull request.

## Checklist

Copy into the pull request description:

```
- [ ] Read the whole issue and its comments; done-when listed
- [ ] Looked for an existing helper or component
- [ ] Similar components: <what I looked at> → <factored / reused / kept apart, why>
- [ ] Size: small / feature / core-or-large (design doc: <link>)
- [ ] Packages touched: <list>
```
