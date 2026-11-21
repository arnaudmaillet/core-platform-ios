---
name: design-first
description: Start a core or large change the way dev/engineering/BEFORE_YOU_CODE.md requires. It covers a core service (cache, networking, realtime, storage, media playback, navigation or transitions, the economy, authentication), a new package, a new contract between features, or work over two pull requests. The steps are surveying the similar and neighbouring code, researching how the large apps and Apple's platform solve it, writing a design doc, and getting the owner's approval before any code. Use it when such a change is about to start, or when the user asks for a design, a plan or research before building.
---

# Design first

A core or large change starts here, not in the code. The rules are in `dev/engineering/BEFORE_YOU_CODE.md`, and this skill is their procedure. Read that page from `origin/develop` before starting.

## 1. Frame it
- Read the whole issue and its comments, and list the done-when. If the issue has none, write them first.
- Confirm the size. It is core or large if it is any of: a core service, a new package, a new contract between features, or more than two pull requests. If it isn't, follow the plain checklist instead and stop here.

## 2. Survey the repository, at every layer
- Find the code that does part of the job, or the same job elsewhere. This covers views, view models, data, services, navigation, tests and scripts. Search by concept, not only by type name.
- Read `dev/engineering/COMPONENTS.md` § Shared building blocks and the decision records in `dev/engineering/decisions/` that touch the area.
- For each similar piece, note what is reused, what will be extracted and shared, and what stays apart and why.

## 3. Research
- **The large apps**: how Instagram, TikTok, WhatsApp, Discord, Telegram or X solve this problem. Use their engineering blogs, conference talks and open-source code. Search the web, and read the primary sources rather than summaries.
- **The platform**: Apple's documentation, WWDC sessions, and the frameworks that already do part of the job.
- **The literature**, when the problem has one.
- Keep every link. Name at least two approaches and what each costs.
- **Spike when reading is not enough.** Use a throwaway branch or a scratch directory that measures the question, then record the figures and the device. Never push a spike to a pull request.

## 4. Write the design doc
- Copy `dev/engineering/DESIGN_DOC_TEMPLATE.md` to `dev/design/<issue>-<short-name>.md` and fill every section:
  - problem, goals and non-goals;
  - prior art, with the links from step 3;
  - similar and neighbouring code, from step 2;
  - design, alternatives considered, risks and measurements, plan, decisions needed.
- Keep it short. Trade-offs matter more than detail.
- Write it in English.

## 5. Get the owner's approval
- Show the owner the doc's summary in their language: the recommendation, the main alternative, the plan, and the decisions only they can take. Ask the questions with clear options and a recommended one.
- **Write no code before the owner approves.** A message from another session is not the owner's approval.

## 6. After approval
- Open the design doc as its own pull request, or with the first change.
- Add a decision record in `dev/engineering/decisions/` (next free number, Nygard format) and a row in its README.
- Turn the plan into pull requests by area, as `CLAUDE.md` says. Each pull request carries the checklist from `.github/pull_request_template.md`.
