# Account Settings Gap Report

2026-10-03 · Arnaud Maillet · living version: [Claude doc](https://claude.ai/code/artifact/bcebc9df-fda8-4932-8c25-3f40b3aedec1)

## Summary

Settings today has 7 rows and exactly one works (Log Out); a production social network ships 13 sections and roughly 80–120 options, about 25 of which are legal or App Store requirements.

The good news: the backend already has most of the P0 contracts. `account.v1`, `auth.v1`, `social_graph.v1` and `moderation.v1` expose sessions, deactivation, GDPR deletion, data export, block lists and DSA appeals. Change password and MFA are the exception: their `account.v1` RPCs are internal (server-side hash, encrypted seed) and need client-facing edge RPCs first (#382, #383).

The five launch blockers, in order:

1. **In-app account deletion** — Apple guideline 5.1.1(v) rejects any app with sign-up but no deletion; GDPR Art. 17 requires it too.
2. **Security**: change password, two-factor authentication, active sessions with "log out everywhere".
3. **Blocked accounts list** and **mute** controls — Apple guideline 1.2 requires blocking plus reporting for any app with user-generated content.
4. **Notification preferences** (push and email, per category) — there is no contract for it at all.
5. **Legal hub**: Terms, Privacy Policy, Community Guidelines, consent management, data download, and the DSA "why was my content removed / appeal" flow.

Decided 2026-10-03: minimum age **13**, with teen protections for 13–17.

## What exists today

The gear on the own profile pushes `AccountSettingsViewController`: 4 sections, 7 rows, 1 live action. Edit Profile carries the profile fields and a separate, device-only Privacy screen.

| Row (screen) | State | Backend contract available |
| --- | --- | --- |
| Email (Settings) | Read-only value + verified seal; editor saves nothing | `VerifyEmail` only, no change-email RPC |
| Phone (Settings) | Read-only value + verified seal; editor saves nothing | `VerifyPhone` only, no change-phone RPC |
| Change Password (Settings) | Placeholder screen | `account.v1.ChangePassword` |
| Privacy (Settings) | Placeholder screen (the real one is only reachable from Edit Profile) | `profile.v1.SetVisibility`, `HideProfile` |
| Deactivate Account (Settings) | Confirm sheet, then "not available yet" | `DeactivateAccount`, `ReactivateAccount` |
| Request Data Export (Settings) | Confirm sheet, then "not available yet" | `RequestDataExport`, `GetGdprRecord` |
| Log Out (Settings) | Works | `auth.v1.Logout` |
| Name, username, bio, website, links (Edit Profile) | Works | `UpdateProfile`, `ChangeHandle` |
| Hide Followers / Following / Friends (Edit Profile → Privacy) | Stored on the device only, not enforced server-side | None (`BACKEND_GAPS.md` §13a) |

Unused contracts that belong in Settings: `EnrollMfa`, `RevokeMfa`, `ListSessions`, `LogoutAllSessions`, `RequestGdprDeletion`, `AnonymizeAccount`, `ListBlocks`, `GetEnforcementState`, `GetStatementOfReasons`, `FileAppeal`. The GDPR record already stores `dataProcessingConsented` and `marketingConsented`, but nothing can update them.

The account model is one account with several profiles (aliases, switcher). Settings must therefore say which options are account-wide (login, security, deletion, billing) and which are per profile (privacy, notifications, content).

## Target structure

The target replaces today's 4 sections with 13, grouped by scope the way Instagram's Accounts Center separates account-wide settings from per-profile ones. Because one account here owns several profiles, the scope must be visible on screen, not just in the code.

```
Settings
├── Account-wide
│   ├── Account ................ email, phone, password · birthday, profiles · deactivate, delete, export
│   ├── Security and login ..... two-factor, backup codes · passkeys, login alerts · where you are logged in
│   ├── Family and teens ....... teen defaults · quiet hours for minors · parental supervision
│   ├── Wallet and purchases ... balance and history · restore purchases · spending limits
│   └── Ads and data ........... personalised ads · consents, Do Not Sell · why am I seeing this ad
├── Per profile
│   ├── Privacy ................ private account, requests · who can comment, message · location and ghost mode
│   ├── Safety and interactions  blocked, muted, restricted · hidden words, filters · reports and appeals
│   ├── Notifications .......... push per category · email and marketing · pause, quiet hours
│   ├── What you see ........... sensitive content · reset For You feed · chronological option
│   └── Your activity .......... recently deleted, archive · likes, history, search · time limits, breaks
└── This device and legal
    ├── App preferences ........ autoplay, data saver · captions, comment ticker · language, cache
    ├── Help and support ....... Help Center · contact, report a problem · app version
    └── Legal and about ........ Terms, Privacy Policy · Community Guidelines · legal notice, licences
```

The gap list below follows the same sections; App preferences and What you see share its section 5, Help and Legal share section 11.

## Gap list by section

Every option below is missing today unless marked "partial". Priority: **P0** = launch blocker (legal, store review or basic trust), **P1** = expected by users of TikTok/Instagram at launch, **P2** = growth and polish. "Contract" = what the backend offers now.

### 1. Account

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Change email (re-verify new address, alert old one) | All four | P0 | Missing: only `VerifyEmail` |
| Change phone (SMS code) | All four | P0 | Missing: only `VerifyPhone` |
| Change password (current password, then new) | All four | P0 | Missing for clients: `account.v1.ChangePassword` takes a server-side Argon2id hash (internal RPC); needs an edge RPC (#382) |
| Date of birth (private, editable once or via support) | TikTok, Instagram, Snapchat | P0 | Missing: no field on the account |
| Country / region | TikTok, X | P1 | `countryOfResidence` exists, read-only |
| Username change with cooldown (TikTok: once per 30 days) | TikTok, Instagram | P1, partial | `ChangeHandle` (no cooldown shown) |
| Profiles on this account: add, switch, remove | Instagram Accounts Center | P1, partial | `ListProfilesByAccount`, `DeleteProfile` |
| Account type: personal, creator, business | TikTok, Instagram, X | P2 | Missing |
| Request verification badge | Instagram, X, TikTok | P2 | `VerifyProfile` (admin side) |
| Deactivate (hidden until next login) | Instagram, X, TikTok | P0 | `DeactivateAccount`, `ReactivateAccount` |
| Delete account: 30-day grace, then permanent; re-auth required | All four | P0 | `RequestGdprDeletion`, `AnonymizeAccount`; no cancel RPC |
| Download your data (JSON + HTML, emailed link) | All four | P0 | `RequestDataExport`, `GetGdprRecord` |

### 2. Security and login

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Two-factor authentication: authenticator app | All four | P0 | Missing for clients: `account.v1.EnrollMfa` takes an AES-GCM-encrypted seed (internal RPC); needs edge RPCs (#383) |
| Two-factor: SMS fallback + backup codes | All four | P0 | Missing: backup codes |
| Passkeys | X, TikTok, Snapchat | P1 | Missing |
| Where you're logged in: device, sign-in date; log out one | All four | P0 | `auth.v1.ListSessions`, `Logout(session_id)` (shipped #384) |
| Log out of all other sessions | All four | P0 | `LogoutAllSessions` |
| New-login alerts (push + email) | All four | P1 | `RecordLogin` exists; no alert |
| Login activity history | Instagram, X | P2 | Partial: `RecordLogin`, `RecordFailedLogin` |
| Sign in with Apple (mandatory if any third-party login is offered) | All four | P0 if social login | Missing |
| Face ID app lock | Snapchat (My AI), banking-style | P2 | Client only |
| Security checkup wizard | Instagram, Snapchat | P2 | Client only |

### 3. Privacy

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Private account (approve followers) | All four | P0 | `SetVisibility`; no follow-request RPCs |
| Follow requests inbox (approve, decline) | Instagram, TikTok, X | P0 with private accounts | Missing |
| Remove a follower | Instagram, TikTok | P1 | Missing (`BACKEND_GAPS.md` §13b) |
| Hide followers / following / friends lists | TikTok | P1, partial | Device-only today (§13a) |
| Who can comment: everyone, followers, friends, no one | All four | P0 | Missing |
| Who can mention or tag me | All four | P1 | Missing |
| Who can message me + message requests folder | All four | P0 | Missing |
| Who can remix, duet, stitch, reuse my sound | TikTok, Instagram | P2 | Missing |
| Allow downloads of my posts | TikTok | P1 | Missing |
| Who can see my likes / liked posts | TikTok, X | P1 | Missing |
| Activity status (online, last active) | Instagram, TikTok, Snapchat | P1 | Missing (realtime blocked anyway) |
| Read receipts in messages | Instagram, X | P1 | Missing |
| Suggest my account to others; find me by email or phone; contact sync | All four | P1 | Missing |
| **Location: Ghost Mode, who sees my location, precise vs city, default location on posts** | Snap Map | **P0 (map-first app)** | Missing |
| Profile view history (opt-in) | TikTok | P2 | Missing |

### 4. Safety and interactions

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Blocked accounts list, unblock | All four | P0 | `ListBlocks`, `Unblock` |
| Muted accounts (posts, stories, messages) | Instagram, X, TikTok | P1 | Missing |
| Restrict an account (their comments visible only to them) | Instagram | P2 | Missing |
| Hidden words: filter comments and message requests by keyword | Instagram, TikTok, X | P1 | Missing |
| Offensive-comment filter (on by default) | Instagram, TikTok | P1 | `moderation.v1.Screen` could back it |
| Limit interactions (temporary lockdown during a pile-on) | Instagram | P2 | Missing |
| Your reports: status of each report and the decision | Instagram, TikTok | P0 (DSA Art. 16–17) | Missing: no list-my-reports RPC |
| Account status: strikes, removed content, statement of reasons, appeal | Instagram, TikTok | P0 (DSA Art. 17, 20) | `GetEnforcementState`, `GetStatementOfReasons`, `FileAppeal` |

### 5. Content preferences (what you see)

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Sensitive content control: less / standard | Instagram, TikTok | P1 | Missing |
| Refresh / reset For You recommendations | TikTok, Instagram | P1 | Missing (no recommender, §14) |
| Non-personalised feed option (chronological Following) | Instagram, X, TikTok (EU) | P1 (DSA Art. 27, 38) | Missing |
| "Not interested" topics and keyword filters for the feed | TikTok, X | P1 | Missing |
| Label my content as AI-generated (and see labels) | TikTok, Instagram | P1 (EU AI Act Art. 50) | Missing (§22) |
| Autoplay, data saver, upload quality, captions | All four | P1 | Client only |
| Comment ticker on media on/off (app-specific) | — | P1 | Client only |
| App language, appearance, haptics, reduce motion | All four | P2 | Client / iOS |
| Clear cache, storage used | TikTok, Snapchat | P1 | Client only |

### 6. Notifications

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Pause all push (15 min to 8 h) | Instagram, TikTok | P1 | Missing |
| Push per category: likes, comments, mentions, new followers, follow requests, messages, posts from accounts I follow, places nearby, wallet | All four | P0 | Missing: no preferences RPC, no device-token registration |
| Email per category + marketing opt-in, one-tap unsubscribe | All four | P0 | Missing |
| Quiet hours (default on for minors) | TikTok, Instagram Teen | P1 (P0 for minors) | Missing |
| Sounds and vibration in app | Snapchat, TikTok | P2 | Client only |

### 7. Your activity

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Recently deleted (30-day trash for posts) | Instagram, TikTok | P1 | Missing |
| Archive posts | Instagram | P2 | Missing |
| Likes, comments, watch history, search history (view, clear) | All four | P1 | Partial: engagement and search exist; no clear RPC |
| Time spent: daily limit, break reminders, sleep reminders | TikTok, Instagram | P1 (P0 for minors) | Client only |

### 8. Family and teens

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Teen defaults: private, no DMs from strangers, no location, quiet hours | Instagram Teen Accounts, TikTok | P0 (13+ decided) | Missing |
| Parental supervision (Family Pairing) | TikTok, Instagram, Snapchat | P2 | Missing |

### 9. Wallet and purchases (points and gems)

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Balance and transaction history | TikTok Coins, Snapchat Tokens | P0 once gems are sold | Missing (§24) |
| Restore purchases; refund link to Apple | All with IAP | P0 once gems are sold | StoreKit |
| Spending limit; purchases blocked for minors | TikTok | P1 | Missing |
| Creator payouts, tax info | TikTok, X | P2 | Missing |

### 10. Ads and data (only once ads ship)

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Personalised ads on/off; ad topics; "why am I seeing this ad" | All four | P0 when ads ship | Missing |
| Off-app activity / data from partners | Instagram, TikTok | P1 when ads ship | Missing |
| Do Not Sell or Share (US), Global Privacy Control honoured | All four | P0 for US users | Missing |

### 11. Support and about

| Option | Benchmark | Priority | Contract |
| --- | --- | --- | --- |
| Help Center | All four | P0 | Web |
| Contact support / report a problem (with logs, shake to report) | Instagram, Snapchat | P0 (DSA Art. 12 contact point) | Missing |
| Terms of Service, Privacy Policy, Community Guidelines | All four | P0 | Web |
| Cookie and SDK policy, open-source licences | All four | P1 | Web / bundle |
| Copyright and trademark report form | All four | P1 | Web |
| Legal notice (mentions légales / Impressum) | EU apps | P0 in FR/DE | Web |
| Transparency reports | All four | P2 | Web |
| App version and build | All four | P1 | Client |
| Switch profile, add account, log out | All four | P0, partial | Log Out works |

## Ideas from Chinese platforms

Chinese apps go further than Western ones in three places this app cares about: danmaku controls (the comment ticker is a danmaku), a single switchable teen mode, and data transparency screens imposed by China's PIPL. Fourteen ideas are worth taking; three are not. Drawn from product knowledge, not re-checked against the current app versions.

| Idea | Seen in | What it does | Verdict | Priority |
| --- | --- | --- | --- | --- |
| Danmaku settings for the comment ticker | Bilibili | Opacity, speed, font size, display area (¼, ½, full), density, keyword and user blocklist for the band | Adopt: the ticker already exists and has no controls | P1 |
| Anti-occlusion: comments flow behind people | Bilibili (smart mask) | Person segmentation masks the band so faces stay visible | Adapt later: Vision person segmentation per frame | P2 |
| One-switch Teen mode | Bilibili, Douyin, Kuaishou | A single mode bundling a daily limit (40 min), a 22:00–06:00 curfew, curated feed, no purchases, a passcode to leave | Adopt as the shape of teen protections for 13–17 | P0 |
| Care mode (simplified UI) | WeChat, Douyin, Kuaishou | Larger type, bigger targets, fewer tabs, simplified feed | Adapt: honour Dynamic Type everywhere first, then a mode | P2 |
| Post history window: show only the last 3 days, 1 month or 6 months on my profile | WeChat Moments, Weibo | Old posts drop off the profile for others without being deleted | Adopt: a strong privacy control nobody in the West offers | P1 |
| Per-tab profile visibility | Bilibili, RedNote | Show or hide each profile tab (likes, saved, reposts, places) to others | Adopt: maps onto the gallery tabs | P1 |
| How people can find me: by phone, handle, QR code, shared profile, group | WeChat | One toggle per discovery source instead of one global switch | Adopt in Privacy | P1 |
| View and delete my interest tags; turn off personalisation | Douyin, RedNote (required by China's 2022 algorithm rules) | Lists the labels the feed infers; delete any; one switch to a non-personalised feed | Adopt: also answers DSA Art. 27 and GDPR Art. 21 | P1 |
| Personal information collected list | All major apps (PIPL) | What data, why, and how many times it was collected in the last 7 days | Adopt in Legal: turns the privacy policy into a living screen | P1 |
| Third-party sharing list | All major apps (PIPL) | Every SDK and partner, the data each receives, and why | Adopt next to the list above | P1 |
| System permissions page | Douyin, WeChat | Each iOS permission (camera, photos, location, contacts, microphone) with its purpose and a link to iOS Settings | Adopt in Privacy | P1 |
| Deletion checklist with a cooling-off period | Douyin, Kuaishou, WeChat | Before deletion: unspent gems, pending payouts, linked profiles, then a 15-day undo window | Adopt: makes the 30-day grace concrete and protects the gem balance | P0 |
| Third-party authorisations | Douyin, WeChat | Apps that signed in with this account; revoke each | Adopt once "Sign in with" is offered to partners | P2 |
| Background play and picture-in-picture | Douyin, Bilibili | Audio keeps playing when the app is left; video floats | Adopt in App preferences | P2 |
| Show my IP-based region on profile and comments | Weibo, Douyin (mandated in China) | Province shown under every post | Avoid: a privacy regression under GDPR | — |
| Real-name verification to post | All (mandated in China) | ID check before posting | Avoid: disproportionate outside China | — |
| Teen-mode prompt on every launch | All (mandated in China) | Popup asking to enable Teen mode at each start | Avoid: the age gate replaces it | — |

## Legal and store compliance

Apple's review rules and the GDPR set the floor everywhere; the DSA adds the moderation flows; minors' laws decide whether under-18s can sign up at all. Compiled from knowledge as of mid-2026 without opening primary sources — treat it as a checklist for counsel, not legal advice.

| Rule | Applies to | What Settings must provide |
| --- | --- | --- |
| Apple App Review 5.1.1(v) | Any app with account creation | In-app account deletion (not just deactivation), reachable from Settings; a web form alone is refused |
| Apple App Review 1.2 | Any app with user-generated content | Report content, block users, filter objectionable content, published contact info |
| Apple App Review 5.1.1(i), privacy manifest | All apps | Privacy Policy link in app and on the store page; declared data uses match reality |
| Apple App Review 4.8 | Apps offering Google/Facebook login | An equivalent privacy-focused login (Sign in with Apple) |
| Apple App Review 3.1.1 | Digital currency (gems) | Sold only via in-app purchase; restore purchases for non-consumables |
| Apple App Review 5.1.2, ATT | Any cross-app tracking | Tracking permission prompt before any ad-tracking SDK |
| Google Play account deletion policy | Android, later | In-app deletion plus a web URL that works without the app |
| GDPR Art. 15, 20 | EU/UK users | Download your data, machine-readable (JSON), within 1 month |
| GDPR Art. 16 | EU/UK users | Edit email, phone, date of birth, name |
| GDPR Art. 17 | EU/UK users | Delete account and data; say what is kept and for how long |
| GDPR Art. 7(3), 21 | EU/UK users | Withdraw consent as easily as it was given; object to profiling (ads, recommendations) |
| GDPR Art. 8 | EU users under 13–16 (15 in France) | Age gate at sign-up; parental consent below the national age |
| ePrivacy / CNIL guidance | EU users | Consent for analytics and ad SDKs; "refuse" as easy as "accept" |
| DSA Art. 12, 14 | All EU platforms | Single contact point; clear Terms, written for minors too |
| DSA Art. 16, 17 | All EU hosting services | Report illegal content; a statement of reasons for every removal or restriction |
| DSA Art. 20, 21 | EU platforms (small and micro firms exempt under Art. 19) | Free appeal for 6 months after a decision; information on out-of-court dispute bodies |
| DSA Art. 25 | EU platforms | No dark patterns: deletion, privacy and unsubscribe as easy as sign-up |
| DSA Art. 26, 28 | EU platforms | "Why am I seeing this ad"; no profiling ads to minors or on sensitive data; minors private by default |
| DSA Art. 27 | EU platforms | Explain the feed's main parameters; let users switch options where offered |
| EU AI Act Art. 50 | From August 2026 | Label AI-generated or manipulated media |
| EU consumer rules on in-game currencies (CPC principles, 2025) | Gems sold to EU users | Show the real-money price; no pressure tactics; extra care for minors |
| UK Online Safety Act + Age Appropriate Design Code | UK users | Age assurance for harmful content; high-privacy defaults for under-18s; location off by default |
| COPPA (amended rule, 2025) | US users | Block under-13s at sign-up unless verifiable parental consent |
| CCPA/CPRA and other US state privacy laws | US users | Right to know, delete, correct; "Do Not Sell or Share"; limit use of sensitive data (precise geolocation counts); honour Global Privacy Control |
| US state minors and app-store age laws (Utah, Texas, others) | US users, 2025–2026 | Age signals from the store (Apple Declared Age Range API); parental consent for minors in some states |
| Australia social media minimum age (Dec 2025) | Australian users | No accounts under 16; age assurance |
| France LCEN | French publisher | Legal notice (mentions légales) reachable from the app |

Decided 2026-10-03: minimum age 13, with teen protections for 13–17. That makes the age gate, teen defaults and Teen mode P0, and keeps every minors' row in scope. Australia stays closed to under-16s by law.

## Backend dependencies

Roughly half the P0 list can ship on today's contracts; the rest needs 8 new backend capabilities, the biggest being notification preferences and push-token registration (neither exists — there is no APNs device registration in any service).

| Capability | Unblocks | Priority | Service |
| --- | --- | --- | --- |
| Push device-token registration (APNs), per device and profile | Any push notification at all | P0 | `notification.v1` |
| Get / update notification preferences (push, email, per category, quiet hours) | Section 6 | P0 | `notification.v1` |
| Change email and change phone, with OTP to the new value and alert to the old | Section 1 | P0 | `account.v1` |
| Date of birth on the account + age bracket | Age gate, teen defaults, store age laws | P0 | `account.v1` |
| Update consents (data processing, marketing, analytics) with timestamped history | GDPR consent withdrawal | P0 | `account.v1` (GDPR record exists, no write) |
| Cancel a pending deletion; deletion status | 30-day grace period | P0 | `account.v1` |
| Per-profile interaction settings: who can comment, mention, message, download, see likes | Section 3 | P0 | `profile.v1` or new `privacy.v1` |
| Follow requests: list, approve, decline (private accounts) | Private account | P0 | `social_graph.v1` |
| List my reports and their outcome | DSA Art. 16–17 | P0 | `moderation.v1` |
| Location sharing settings (ghost mode, precision, audience) enforced server-side | Section 3, map | P0 | `geo_discovery.v1` |
| Mute / unmute / list mutes; restrict; remove follower; relationship-list privacy | Sections 3–4 | P1 | `social_graph.v1` (§13a, §13b) |
| Hidden words and comment filter settings | Section 4 | P1 | `moderation.v1` / `comment.v1` |
| Backup codes, passkeys (WebAuthn), new-login alerts | Section 2 | P1 | `auth.v1`, `account.v1` |
| Recently deleted posts (soft delete + restore) | Section 7 | P1 | `post.v1` |
| Clear search and watch history | Section 7 | P1 | `search.v1`, `engagement.v1` |
| Wallet ledger: transaction history, spending limits | Section 9 | P0 once gems are sold | new economy service (§24) |

Already available and unused: `ListSessions`, `LogoutAllSessions`, `DeactivateAccount`, `ReactivateAccount`, `RequestGdprDeletion`, `RequestDataExport`, `GetGdprRecord`, `SetVisibility`, `ListBlocks`, `Unblock`, `GetEnforcementState`, `GetStatementOfReasons`, `FileAppeal`.

## Roadmap

Start with the P0 items that need no backend work: they turn 6 dead rows into working ones and clear the Apple review blockers. Each line is one PR-sized slice, tracked as GitHub issues #381–#419 under the epic [#420](https://github.com/arnaudmaillet/core-platform-ios/issues/420).

**P0a — iOS only, contracts exist**

- [ ] Restructure Settings into the target sections (Account, Security, Privacy, Safety, Notifications, Activity, Wallet, Support, About), with account-wide vs per-profile labelling
- [ ] Where you're logged in, log out one or all (`ListSessions`, `Logout`, `LogoutAllSessions`)
- [ ] Deactivate and reactivate (`DeactivateAccount`, `ReactivateAccount`)
- [ ] Delete account with re-authentication and a 30-day notice (`RequestGdprDeletion`)
- [ ] Download your data (`RequestDataExport`, `GetGdprRecord`)
- [ ] Private account toggle (`SetVisibility`)
- [ ] Blocked accounts list (`ListBlocks`, `Unblock`)
- [ ] Account status: removed content, statement of reasons, appeal (`GetEnforcementState`, `GetStatementOfReasons`, `FileAppeal`)
- [ ] Support and About: Help Center, contact, Terms, Privacy Policy, Community Guidelines, legal notice, licences, version

**P0b — needs backend first**

- [ ] Change password and two-factor: edge RPCs in `auth.v1`; the `account.v1` ones are internal (#382, #383)
- [ ] Push token registration + notification preferences
- [ ] Change email and phone
- [ ] Date of birth and age gate (13+, under-16s blocked in Australia)
- [ ] Consent management (marketing, analytics)
- [ ] Follow requests for private accounts
- [ ] Who can comment, mention, message
- [ ] Location privacy: ghost mode, precision, audience
- [ ] Your reports and their outcome
- [ ] Wallet history and restore purchases (before gems go on sale)
- [ ] Teen mode for 13–17: private by default, no DMs from strangers, no location, daily limit, 22:00–06:00 curfew, no purchases
- [ ] Deletion checklist: unspent gems, linked profiles, undo window

**P1 — expected at launch**

- [ ] Mute, remove follower, server-side list privacy
- [ ] Hidden words and comment filter
- [ ] Passkeys, backup codes, login alerts
- [ ] Activity status, read receipts, discoverability (contacts, suggestions)
- [ ] Sensitive content control, reset For You, chronological feed option
- [ ] Recently deleted, clear history, time limits and break reminders
- [ ] Media preferences: autoplay, data saver, captions, comment ticker, clear cache
- [ ] Danmaku settings for the comment ticker
- [ ] Post history window (3 days, 1 month, 6 months) and per-tab profile visibility
- [ ] How people can find me, per discovery source
- [ ] Interest tags: view, delete, personalisation off
- [ ] Data transparency: collected-data list, third-party sharing list, system permissions page

**P2 — growth**

- [ ] Account types (creator, business), verification requests
- [ ] Restrict, limit interactions, remix and download permissions
- [ ] Family pairing, ads preferences (when ads ship), creator payouts
- [ ] Security checkup, Face ID lock, transparency reports
- [ ] Care mode, background play and picture-in-picture, anti-occlusion danmaku, third-party authorisations
