# Account Settings Gap Report

Updated 2026-10-04 (first version 2026-10-03) · Arnaud Maillet · this file is the current version; the [Claude doc](https://claude.ai/code/artifact/bcebc9df-fda8-4932-8c25-3f40b3aedec1) still holds the 2026-10-03 text.

## Summary

Two days ago Settings had 7 rows and one working action (Log Out). It now has 17 sections in 4 groups, and every section the app can build without a backend change is live. A production social network ships roughly 80–120 options, about 25 of them legal or App Store requirements.

What remains is mostly blocked on the backend. Change password, two-factor, notification preferences, date of birth, consents, follow requests, interaction settings, location privacy and the wallet ledger each need a client-facing contract that does not exist yet. They are tracked as issues in [arnaudmaillet/core-platform](https://github.com/arnaudmaillet/core-platform), epic #666.

The five launch blockers, where they stand:

1. **In-app account deletion** (Apple 5.1.1(v), GDPR Art. 17): **shipped**, with a 30-day notice (#386). The deletion checklist and undo window still need a cancel RPC (#402).
2. **Security**:
   - sessions and "log out everywhere": **shipped** (#384);
   - Security Checkup and App Lock: **shipped** (#418);
   - change password and two-factor: **blocked** on backend (#382, #383 → core-platform#648, #649).
3. **Blocked accounts list**: **shipped** (#389). Mute and restrict are **blocked** on backend (#403, #416 → core-platform#659).
4. **Notification preferences**: **blocked**. No push-token registration and no preferences contract exist (#392 → core-platform#654).
5. **Legal hub**:
   - **shipped**: the help and legal pages (#391), the data transparency screens (#414), data download (#387), and transparency reports (#418);
   - **waiting on final URLs**: every link is a provisional "Coming Soon" until the pages exist (#424, yours to provide);
   - **partial**: account status and appeal, which need decision ids on enforcements (#390 → core-platform#658);
   - **blocked**: consent management (#395 → core-platform#653).

Decided 2026-10-03: minimum age **13**, with teen protections for 13–17.

## What shipped (2026-10-03 → 2026-10-04)

| Area | What the viewer gets | Issue → PR |
| --- | --- | --- |
| Structure | 17 sections in 4 groups (Account-wide, Profile · @handle, App and Device, Support and Legal), the scope said on screen; guests see App and Device plus Support and Legal | #381 → #426; #468 → #469; #472, #479 |
| Security and login | Where you're logged in, log out one device or all | #384 → #428 |
| | Security Checkup (email, phone, devices, App Lock; password and 2FA shown as not available yet) | #418 → #481 |
| | App Lock: Face ID / Touch ID / passcode to open the app, Lock After immediately / 1 min / 15 min, hidden in the app switcher | #418 → #481 |
| Account | Delete account with a 30-day notice | #386 → #430 |
| | Download your data | #387 → #431 |
| Privacy | Private account | #388 → #432 |
| | Collected-data list, third-party sharing list, system permissions page; privacy manifest | #414 → #436 |
| Safety | Blocked accounts list, unblock | #389 → #433 |
| | Account status (partial: statement of reasons waits on decision ids) | #390 → #434 |
| Your activity | Time Management: daily limit, break reminders, today's time and a 7-day chart, all on this iPhone | #489 → #491 |
| Playback and sound | Autoplay always / Wi-Fi / never, start with sound, data saver | #409 → #465 |
| | Interface sounds on/off; haptics on/off through one set of wrappers | #471 → #477, #470 → #478 |
| Display | Appearance system / light / dark with icons; Reduce Motion (adds to the iOS setting) | #468 → #469, #487 → #488 |
| | Care Mode: at least Extra Large text, bold text, reaction band off while on | #482 → #492 |
| Comments on media | Reaction band on/off, opacity, speed; subtitles on/off; muted words and accounts (both overlays) | #410 → #464 |
| | Background opacity for the band (a progressive wash that follows the scrub), the subtitle pill and the comments screen | #487 → #488 |
| Storage | Media cache size, Clear Cache | #409 → #465 |
| Support and legal | Help Center, contact, report a problem; Terms, Privacy Policy, Community Guidelines, legal notice, copyright, cookie and SDK policy, transparency reports, version (URLs provisional, #424) | #391 → #435, #418 → #481 |
| Text size, app-wide | Dynamic Type everywhere (two double-scaling bugs fixed); text capped at XXXL | #482 → #490 (merged), #495 (in review) |
| Look | UIKit's soft top-edge blur under the bar on every Settings screen | #493 (in review) |

## Target structure

The 17 sections, grouped by scope the way Instagram's Accounts Center separates account-wide settings from per-profile ones. One account owns several profiles here, so the scope is visible on screen, not just in the code. ✅ = live, ◐ = partly live, ○ = waiting on backend.

```
Settings
├── Account-wide
│   ├── Account ................ ◐ delete ✅, download ✅ · email, phone, password ○ · birthday ○ · deactivate ○
│   ├── Security and login ..... ◐ Security Checkup ✅, App Lock ✅, where you're logged in ✅ · two-factor, backup codes, passkeys ○
│   ├── Family and teens ....... ○ teen defaults · quiet hours for minors · parental supervision
│   ├── Wallet and purchases ... ○ balance and history · restore purchases · spending limits
│   └── Ads and data ........... ○ personalised ads · consents · why am I seeing this ad
├── Profile · @handle
│   ├── Privacy ................ ◐ private account ✅, data transparency ✅ · follow requests ○ · who can comment, message ○ · location ○
│   ├── Safety and interactions  ◐ blocked ✅, account status ◐ · muted, restricted ○ · hidden words ○ · your reports ○
│   ├── Notifications .......... ○ push per category · email and marketing · pause, quiet hours
│   ├── What you see ........... ○ sensitive content · reset For You · chronological option
│   └── Your activity .......... ◐ daily limit, break reminders, screen time ✅ · recently deleted, history ○
├── App and Device (follows the iPhone)
│   ├── Playback and sound ..... ✅ autoplay · start with sound · data saver · interface sounds · haptics
│   ├── Display ................ ✅ appearance · Care Mode · reduce motion
│   ├── Comments on media ...... ✅ reaction band (on/off, opacity, background, speed) · subtitles (on/off, background) · comments screen background · muted words and accounts
│   ├── Language ............... ✅ app language (English only for now)
│   └── Storage ................ ✅ media cache size · clear cache
└── Support and legal
    ├── Help and support ....... ✅ Help Center · contact · report a problem (URLs provisional, #424)
    └── Legal and about ........ ✅ Terms, Privacy Policy · Community Guidelines · legal notice · transparency reports · version (URLs provisional)
```

Decisions recorded with the user (2026-10-03/04):
- App and Device settings are device-scoped, stored on the iPhone, never per profile. So are App Lock and Time Management, although they sit in Security and Your activity.
- Comments on media:
  - no text size, lane count or display area (they don't fit the fixed band);
  - muted words and accounts hide comments in **both** the reaction band and the subtitles;
  - the band's background rests at 0 and darkens progressively while scrubbing; the subtitle pill (0.45) and the comments screen (0.8) keep today's look by default.
- Autoplay and data saver govern the full-screen feed only; For You tiles and map previews keep their muted live previews.
- Reduce Motion: the app switch adds to the iOS setting (`MotionPreference.reducesMotion`), read by every animation that honoured the iOS one.
- Text size: the app never draws above **XXXL** (body 23 pt); AX1 was considered and set aside. Care Mode raises the size to Extra Large under that ceiling.
- Settings screens wear UIKit's soft top-edge blur under the bar; the rest of the app keeps no blur under headers.

## Gap list by section

Priority: **P0** = launch blocker (legal, store review or basic trust), **P1** = expected by users of TikTok/Instagram at launch, **P2** = growth and polish. "Status / contract" says what is live, or what the backend offers now.

### 1. Account

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Change email (re-verify new address, alert old one) | All four | P0 | Blocked: only `VerifyEmail` (#393 → core-platform#651) |
| Change phone (SMS code) | All four | P0 | Blocked: only `VerifyPhone` (#393 → core-platform#651) |
| Change password (current password, then new) | All four | P0 | Blocked: `account.v1.ChangePassword` is internal (server-side hash) (#382 → core-platform#648) |
| Date of birth (private, editable once or via support) | TikTok, Instagram, Snapchat | P0 | Blocked: no field on the account (#394 → core-platform#652) |
| Country / region | TikTok, X | P1 | `countryOfResidence` exists, read-only |
| Username change with cooldown | TikTok, Instagram | P1, partial | `ChangeHandle` (no cooldown shown) |
| Profiles on this account: add, switch, remove | Instagram Accounts Center | P1, partial | Switch profile works; `ListProfilesByAccount`, `DeleteProfile` |
| Account type: personal, creator, business | TikTok, Instagram, X | P2 | Blocked (#415 → core-platform#668) |
| Request verification badge | Instagram, X, TikTok | P2 | Blocked: `VerifyProfile` is admin-only (#415 → core-platform#668) |
| Deactivate (hidden until next login) | Instagram, X, TikTok | P0 | Blocked: a deactivated account can't log back in (#385 → core-platform#650) |
| Delete account: 30-day grace, then permanent | All four | P0 | ✅ Shipped (#386); no cancel RPC yet (#402 → core-platform#653) |
| Download your data | All four | P0 | ✅ Shipped (#387) |

### 2. Security and login

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Two-factor authentication: authenticator app | All four | P0 | Blocked: `EnrollMfa` takes an encrypted seed (internal) (#383 → core-platform#649) |
| Two-factor: SMS fallback + backup codes | All four | P0 | Blocked (#405 → core-platform#649) |
| Passkeys | X, TikTok, Snapchat | P1 | Blocked (#405 → core-platform#649) |
| Where you're logged in; log out one | All four | P0 | ✅ Shipped (#384) |
| Log out of all other sessions | All four | P0 | ✅ Shipped (#384) |
| New-login alerts (push + email) | All four | P1 | Blocked (#405 → core-platform#649) |
| Login activity history | Instagram, X | P2 | Partial contract: `RecordLogin`, `RecordFailedLogin` |
| Sign in with Apple (mandatory if any third-party login is offered) | All four | P0 if social login | Missing |
| Face ID app lock | Snapchat, banking-style | P2 | ✅ Shipped: App Lock (#418) |
| Security checkup | Instagram, Snapchat | P2 | ✅ Shipped (#418) |
| Apps and websites (third-party authorisations) | WeChat, Douyin | P2 | Blocked (#485 → core-platform#667) |

### 3. Privacy

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Private account (approve followers) | All four | P0 | ✅ Toggle shipped (#388); follow requests blocked (#396 → core-platform#655) |
| Follow requests inbox (approve, decline) | Instagram, TikTok, X | P0 with private accounts | Blocked (#396 → core-platform#655) |
| Remove a follower | Instagram, TikTok | P1 | Blocked (#403 → core-platform#659) |
| Hide followers / following / friends lists | TikTok | P1, partial | Device-only today (#403 → core-platform#659) |
| Who can comment: everyone, followers, friends, no one | All four | P0 | Blocked (#397 → core-platform#656) |
| Who can mention or tag me | All four | P1 | Blocked (#397 → core-platform#656) |
| Who can message me + message requests folder | All four | P0 | Blocked (#397 → core-platform#656) |
| Who can remix or reuse my sound | TikTok, Instagram | P2 | Blocked (#416 → core-platform#669) |
| Allow downloads of my posts | TikTok | P1 | Blocked (#416 → core-platform#656) |
| Who can see my likes | TikTok, X | P1 | Blocked (#397 → core-platform#656) |
| Activity status, read receipts | Instagram, TikTok, Snapchat | P1 | Blocked (#406 → core-platform#661) |
| Suggest my account; find me by email or phone; contact sync | All four | P1 | Blocked (#406, #412 → core-platform#661) |
| **Location: Ghost Mode, audience, precise vs city** | Snap Map | **P0 (map-first app)** | Blocked (#398 → core-platform#657) |
| Collected-data list, third-party sharing list, system permissions | PIPL-style | P1 | ✅ Shipped (#414) |
| Post history window; per-tab profile visibility | WeChat, Weibo, Bilibili | P1 | Blocked (#411 → core-platform#664) |

### 4. Safety and interactions

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Blocked accounts list, unblock | All four | P0 | ✅ Shipped (#389) |
| Muted accounts (posts, stories, messages) | Instagram, X, TikTok | P1 | Blocked (#403 → core-platform#659) |
| Restrict an account | Instagram | P2 | Blocked (#416 → core-platform#659) |
| Hidden words; offensive-comment filter | Instagram, TikTok, X | P1 | Blocked (#404 → core-platform#660) |
| Limit interactions (temporary) | Instagram | P2 | Blocked (#416 → core-platform#669) |
| Your reports: status and decision | Instagram, TikTok | P0 (DSA Art. 16–17) | Blocked (#399 → core-platform#658) |
| Account status: strikes, statement of reasons, appeal | Instagram, TikTok | P0 (DSA Art. 17, 20) | ◐ Partial (#390): enforcements carry no decision id (core-platform#658) |

### 5. What you see, and App and Device

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Sensitive content control | Instagram, TikTok | P1 | Blocked (#407 → core-platform#662) |
| Reset For You recommendations | TikTok, Instagram | P1 | Blocked (#407 → core-platform#662) |
| Non-personalised / chronological feed | Instagram, X, TikTok (EU) | P1 (DSA Art. 27, 38) | Blocked (#407 → core-platform#662) |
| Interest tags: view, delete, personalisation off | Douyin, RedNote | P1 | Blocked (#413 → core-platform#662) |
| Label AI-generated content | TikTok, Instagram | P1 (EU AI Act Art. 50) | Missing |
| Autoplay, start with sound, data saver | All four | P1 | ✅ Shipped (#409) |
| Upload quality | TikTok, Instagram | P2 | Missing |
| Reaction band (danmaku) and subtitles: on/off, opacity, speed, backgrounds, muted words and accounts | Bilibili | P1 | ✅ Shipped (#410, #487) |
| Appearance, Reduce Motion | All four | P2 | ✅ Shipped (#468, #487) |
| Haptics, interface sounds | Snapchat, TikTok | P2 | ✅ Shipped (#470, #471) |
| Care Mode (larger, bolder text) | WeChat, Douyin | P2 | ✅ v1 shipped (#492); hiding the shortcut rail and 56 pt targets still open (#482) |
| Text size honoured everywhere, capped at XXXL | Apple HIG | P1 | ✅ #490 merged, #495 in review |
| Background play, picture in picture | Douyin, Bilibili | P2 | Open, client only (#483) |
| Comments flow behind people | Bilibili | P2 | Open, client only (#484) |
| App language | All four | P2 | ✅ Page shipped (English only for now) |
| Clear cache, storage used | TikTok, Snapchat | P1 | ✅ Shipped (#409) |

### 6. Notifications

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Pause all push | Instagram, TikTok | P1 | Blocked (#392 → core-platform#654) |
| Push per category | All four | P0 | Blocked: no preferences RPC, no device-token registration (#392 → core-platform#654) |
| Email per category + marketing opt-in | All four | P0 | Blocked (#392, #395 → core-platform#653, #654) |
| Quiet hours (default on for minors) | TikTok, Instagram Teen | P1 (P0 for minors) | Blocked (#392 → core-platform#654) |
| Sounds and vibration in app | Snapchat, TikTok | P2 | ✅ Shipped (#470, #471) |

### 7. Your activity

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Recently deleted (30-day trash for posts) | Instagram, TikTok | P1 | Blocked (#408 → core-platform#663) |
| Archive posts | Instagram | P2 | Missing |
| Likes, comments, watch and search history (view, clear) | All four | P1 | Blocked: no clear RPC (#408 → core-platform#663) |
| Daily limit, break reminders, screen time | TikTok, Instagram | P1 (P0 for minors) | ✅ Shipped (#489) |
| Sleep reminders | TikTok | P2 | Missing |

### 8. Family and teens

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Teen mode: private, no DMs from strangers, no location, daily limit, curfew, no purchases | Instagram Teen Accounts, Douyin | P0 (13+ decided) | Blocked on date of birth and quiet hours (#401 → core-platform#652, #654) |
| Parental supervision | TikTok, Instagram, Snapchat | P2 | Blocked (#417 → core-platform#670) |

### 9. Wallet and purchases (points and gems)

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Balance and transaction history | TikTok Coins, Snapchat Tokens | P0 once gems are sold | Blocked (#400 → core-platform#665) |
| Restore purchases; refund link to Apple | All with IAP | P0 once gems are sold | Blocked (#400 → core-platform#665) |
| Spending limit; purchases blocked for minors | TikTok | P1 | Blocked (core-platform#665) |
| Creator payouts, tax info | TikTok, X | P2 | Later: needs the ledger first (#417) |

### 10. Ads and data (only once ads ship)

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Personalised ads on/off; ad topics; "why am I seeing this ad" | All four | P0 when ads ship | Not started (#417) |
| Off-app activity / data from partners | Instagram, TikTok | P1 when ads ship | Not started |
| Do Not Sell or Share (US), Global Privacy Control | All four | P0 for US users | Missing |

### 11. Support and about

| Option | Benchmark | Priority | Status / contract |
| --- | --- | --- | --- |
| Help Center | All four | P0 | ✅ Row shipped; URL provisional (#424) |
| Contact support / report a problem | Instagram, Snapchat | P0 (DSA Art. 12) | ✅ Rows shipped; URLs provisional (#424) |
| Terms, Privacy Policy, Community Guidelines | All four | P0 | ✅ Rows shipped; URLs provisional (#424) |
| Cookie and SDK policy, licences | All four | P1 | ✅ Row shipped; URL provisional (#424) |
| Copyright report form | All four | P1 | ✅ Row shipped; URL provisional (#424) |
| Legal notice (mentions légales) | EU apps | P0 in FR/DE | ✅ Row shipped; URL provisional (#424) |
| Transparency reports | All four | P2 | ✅ Row shipped; URL provisional (#424) |
| App version and build | All four | P1 | ✅ Shipped |
| Switch profile, log out | All four | P0 | ✅ Shipped |

## Ideas from Chinese platforms

Chinese apps go further than Western ones in three places this app cares about: danmaku controls (the comment ticker is a danmaku), a single switchable teen mode, and data transparency screens imposed by China's PIPL. Fourteen ideas are worth taking; three are not. Drawn from product knowledge, not re-checked against the current app versions.

| Idea | Seen in | Verdict | Status |
| --- | --- | --- | --- |
| Danmaku settings for the comment ticker | Bilibili | Adopt (no font size, lanes or area) | ✅ Shipped (#410, #487) |
| Comments flow behind people | Bilibili | Adapt later (Vision person segmentation) | Open (#484) |
| One-switch Teen mode | Bilibili, Douyin, Kuaishou | Adopt as the shape of teen protections for 13–17 | Blocked (#401) |
| Care mode | WeChat, Douyin, Kuaishou | Adapt: Dynamic Type everywhere first, then a mode | ✅ Both steps shipped (#490, #492, #495 in review); leftovers on #482 |
| Post history window (3 days, 1 month, 6 months) | WeChat, Weibo | Adopt | Blocked (#411) |
| Per-tab profile visibility | Bilibili, RedNote | Adopt | Blocked (#411) |
| How people can find me, per source | WeChat | Adopt | Blocked (#412) |
| View and delete interest tags; personalisation off | Douyin, RedNote | Adopt (answers DSA Art. 27, GDPR Art. 21) | Blocked (#413) |
| Personal information collected list | PIPL | Adopt | ✅ Shipped (#414) |
| Third-party sharing list | PIPL | Adopt | ✅ Shipped (#414) |
| System permissions page | Douyin, WeChat | Adopt | ✅ Shipped (#414) |
| Deletion checklist with a cooling-off period | Douyin, Kuaishou, WeChat | Adopt | Blocked (#402) |
| Third-party authorisations | Douyin, WeChat | Adopt once partners sign in with the app | Blocked (#485) |
| Background play and picture in picture | Douyin, Bilibili | Adopt | Open (#483) |
| IP-based region on profile and comments | Weibo, Douyin | Avoid: privacy regression under GDPR | — |
| Real-name verification to post | All (China) | Avoid: disproportionate outside China | — |
| Teen-mode prompt on every launch | All (China) | Avoid: the age gate replaces it | — |

## Legal and store compliance

Apple's review rules and the GDPR set the floor everywhere; the DSA adds the moderation flows; minors' laws decide whether under-18s can sign up at all. Compiled from knowledge as of mid-2026 without opening primary sources — treat it as a checklist for counsel, not legal advice. The last column says where the app stands.

| Rule | Applies to | What Settings must provide | Status |
| --- | --- | --- | --- |
| Apple App Review 5.1.1(v) | Any app with account creation | In-app account deletion, reachable from Settings | ✅ |
| Apple App Review 1.2 | Any app with user-generated content | Report content, block users, filter objectionable content, published contact info | ◐ report and block ✅; filter blocked (#404); contact URL #424 |
| Apple App Review 5.1.1(i), privacy manifest | All apps | Privacy Policy link in app and on the store page; declared data uses match reality | ◐ manifest ✅ (#414); Privacy Policy URL #424 |
| Apple App Review 4.8 | Apps offering Google/Facebook login | Sign in with Apple | Not needed yet |
| Apple App Review 3.1.1 | Digital currency (gems) | Sold only via in-app purchase; restore purchases | Blocked (#400) |
| Apple App Review 5.1.2, ATT | Any cross-app tracking | Tracking prompt before any ad-tracking SDK | Not needed yet |
| Google Play account deletion policy | Android, later | In-app deletion plus a web URL | Later |
| GDPR Art. 15, 20 | EU/UK users | Download your data, machine-readable | ✅ |
| GDPR Art. 16 | EU/UK users | Edit email, phone, date of birth, name | ◐ name ✅; email, phone, birthday blocked |
| GDPR Art. 17 | EU/UK users | Delete account and data | ✅ |
| GDPR Art. 7(3), 21 | EU/UK users | Withdraw consent as easily as given; object to profiling | Blocked (#395, #413) |
| GDPR Art. 8 | EU users under 13–16 | Age gate; parental consent below the national age | Blocked (#394) |
| ePrivacy / CNIL guidance | EU users | Consent for analytics and ad SDKs | Blocked (#395) |
| DSA Art. 12, 14 | All EU platforms | Single contact point; clear Terms | ◐ rows ✅, URLs #424 |
| DSA Art. 16, 17 | All EU hosting services | Report illegal content; statement of reasons | ◐ report ✅; reasons partial (#390, #399) |
| DSA Art. 20, 21 | EU platforms (small firms exempt) | Free appeal for 6 months | ◐ (#390) |
| DSA Art. 25 | EU platforms | No dark patterns | Followed in every shipped flow |
| DSA Art. 26, 28 | EU platforms | Ad transparency; no profiling ads to minors; minors private by default | Blocked (#401, #417) |
| DSA Art. 27 | EU platforms | Explain the feed; offer options | Blocked (#407, #413) |
| EU AI Act Art. 50 | From August 2026 | Label AI-generated media | Missing |
| EU consumer rules on in-game currencies | Gems sold to EU users | Real-money price, no pressure tactics | With #400 |
| UK Online Safety Act + Age Appropriate Design Code | UK users | High-privacy defaults for under-18s | Blocked (#401) |
| COPPA (2025 rule) | US users | Block under-13s | Blocked (#394) |
| CCPA/CPRA and US state laws | US users | Know, delete, correct; Do Not Sell; GPC | ◐ delete and download ✅ |
| US state minors and app-store age laws | US users | Store age signals, parental consent | Blocked (#394) |
| Australia minimum age (Dec 2025) | Australian users | No accounts under 16 | Blocked (#394) |
| France LCEN | French publisher | Legal notice reachable from the app | ◐ row ✅, URL #424 |

## Backend dependencies

Everything left at P0 except the final URLs needs a backend contract. They are filed in arnaudmaillet/core-platform under epic #666, one issue per contract, each linking the iOS issue it unblocks.

| Capability | Unblocks (iOS) | Priority | Backend issue |
| --- | --- | --- | --- |
| Client-facing change password and credential step-up | #382 | P0 | core-platform#648 |
| Two-factor enrolment, backup codes, passkeys, login alerts | #383, #405 | P0 | core-platform#649 |
| Self-deactivated accounts can sign back in | #385 | P0 | core-platform#650 |
| Change email and phone with verification | #393 | P0 | core-platform#651 |
| Date of birth and age bracket | #394, #401 | P0 | core-platform#652 |
| User-facing GDPR status, consents, deletion cancel, export delivery | #395, #402 | P0 | core-platform#653 |
| APNs device registration and notification preferences | #392 | P0 | core-platform#654 |
| Follow requests for private profiles | #396 | P0 | core-platform#655 |
| Per-profile interaction settings enforced server-side | #397, #416 | P0 | core-platform#656 |
| Location sharing settings | #398 | P0 | core-platform#657 |
| Enforcements linked to decisions; list my reports | #390, #399 | P0 | core-platform#658 |
| Economy ledger: history, restore, spending limits | #400 | P0 once gems are sold | core-platform#665 |
| Mute, restrict, remove follower, list privacy | #403, #416 | P1 | core-platform#659 |
| Hidden words and comment filter | #404 | P1 | core-platform#660 |
| Presence and discoverability | #406, #412 | P1 | core-platform#661 |
| Recommender controls, interest tags | #407, #413 | P1 | core-platform#662 |
| Recently deleted posts, history clearing | #408 | P1 | core-platform#663 |
| Post history window, per-tab visibility | #411 | P1 | core-platform#664 |
| Third-party app authorisations | #485 | P2 | core-platform#667 |
| Account types and verification requests | #415 | P2 | core-platform#668 |
| Temporary interaction limits, remix and sound reuse | #416 | P2 | core-platform#669 |
| Family supervision | #417 | P2 | core-platform#670 |

## Roadmap

Tracked under the epic [#420](https://github.com/arnaudmaillet/core-platform-ios/issues/420).

**P0a — iOS only, contracts exist**

- [x] Restructure Settings into the target sections, with the scope on screen (#381)
- [x] Where you're logged in, log out one or all (#384)
- [ ] Deactivate and reactivate (#385): moved to backend, a deactivated account can't sign back in
- [x] Delete account with a 30-day notice (#386)
- [x] Download your data (#387)
- [x] Private account toggle (#388)
- [x] Blocked accounts list (#389)
- [ ] Account status, statement of reasons, appeal (#390): partial, waits on decision ids
- [x] Help, support and legal pages (#391); final URLs are yours to provide (#424)

**P0b — needs backend first**

- [ ] Change password and two-factor (#382, #383)
- [ ] Push token registration + notification preferences (#392)
- [ ] Change email and phone (#393)
- [ ] Date of birth and age gate, 13+ (#394)
- [ ] Consent management (#395)
- [ ] Follow requests (#396)
- [ ] Who can comment, mention, message (#397)
- [ ] Location privacy (#398)
- [ ] Your reports and their outcome (#399)
- [ ] Wallet history and restore purchases, before gems go on sale (#400)
- [ ] Teen mode for 13–17 (#401)
- [ ] Deletion checklist and undo window (#402)

**P1 — expected at launch**

- [ ] Mute, remove follower, server-side list privacy (#403)
- [ ] Hidden words and comment filter (#404)
- [ ] Passkeys, backup codes, login alerts (#405)
- [ ] Activity status, read receipts, discoverability (#406)
- [ ] Sensitive content, reset For You, chronological feed (#407)
- [ ] Recently deleted and clear history (#408)
- [x] Daily limit and break reminders (#489, split from #408)
- [x] Media preferences: autoplay, data saver, cache (#409)
- [x] Danmaku settings for the comment ticker (#410), backgrounds (#487)
- [ ] Post history window and per-tab profile visibility (#411)
- [ ] How people can find me, per discovery source (#412)
- [ ] Interest tags (#413)
- [x] Data transparency screens (#414)
- [x] App and Device group, haptics, interface sounds (#468, #470, #471)

**P2 — growth**

- [ ] Account types and verification requests (#415)
- [ ] Restrict, limit interactions, remix and download permissions (#416)
- [ ] Family pairing, ads preferences, creator payouts (#417)
- [x] Security Checkup, App Lock, transparency reports (#418)
- [ ] Dynamic Type and Care Mode (#482): both steps shipped or in review; rail hiding and 56 pt targets left
- [ ] Background play and picture in picture (#483)
- [ ] Comments flow behind people (#484)
- [ ] Apps and websites, third-party authorisations (#485)
