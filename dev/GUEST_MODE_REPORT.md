# Guest Mode Report: browse first, sign up later

2026-10-03 · Arnaud Maillet · living version: [Claude doc](https://claude.ai/code/artifact/a1cd4532-d53b-491c-ad57-290df5c5c9de) · epic #456

## Summary

The goal: on first launch the app opens straight into content, with no onboarding, login or sign-up screen. Until the person creates an account they browse **read-only**. Any write (like, comment, follow, message, post) opens a sign-up sheet, and the action completes once they are signed in. TikTok, Douyin, Kuaishou and YouTube all work this way. Instagram is the main app that still puts a login wall up.

**Nothing in the app or the backend supports this today, and no issue tracks it** (searched both repos for guest, anonymous, visitor, sign-up and read-only).

- **iOS.** The tab shell only exists when `AuthState` is `.authenticated`; otherwise the login screen *replaces* the window root (`App/AppCoordinator.swift:176-201`). For You reads the **following** timeline, which needs a viewer, so even with the shell open a guest would see "Couldn't load".
- **Backend.** Only `auth.Login` and `auth.Refresh` are reachable without a token (`crates/services/auth/src/service.rs:40-48`). No guest principal exists and no client can create an account: `CreateAccount` is not exposed to clients, and Login refuses unknown identities (`grpc_account_directory.rs:47-51`). No discovery feed exists either.
- **Security debt this exposes.** Read handlers ignore the viewer entirely. `GetPost` returns drafts and deleted posts, private profiles are served as-is, and follower lists of private accounts are readable (§7.2). Today this is hidden behind "you need a token". Opening reads to anonymous traffic without fixing it would leak private data.
- **Local dev hides the problem.** The local Envoy routes to the mesh ports, which have no edge policy at all. Guest mode would appear to work locally and fail with `UNAUTHENTICATED` in staging and prod.

The good news is that the iOS side is well placed:
- `AuthInterceptor` already sends requests without a token when there is none (`AuthInterceptor.swift:23-26`).
- Comments, posts, other people's profiles, search and map tiles are already read without needing a viewer.
- The `StakeShopOpening` responder-chain pattern is a ready-made shape for a "sign in to continue" gate.

**Decisions settled on 2026-10-03** (§10): a guest token; Apple, Google, email or phone at sign-up; non-personalised regional trending for guests; restricted content by default; guest reports allowed; bookmarks gated; a non-blocking legal card; no nudges (unlimited browsing); location unlocks the current country only; a locked welcome gift of 50 likes plus daily likes that pile up for 3 days, claimed at sign-up (§3.2).

**Path:**
1. Build the iOS guest shell against the mock first (no backend dependency).
2. In parallel, the backend ships five launch blockers:
   - a guest session token;
   - viewer-aware public reads;
   - a discovery feed;
   - a client sign-up path;
   - abuse controls plus a CDN for media.

## 1. Where we stand today

### iOS

| Area | Today | Evidence |
| --- | --- | --- |
| Launch | Spinner, then login screen as window root when signed out | `App/AppCoordinator.swift:46-47, 178-180` |
| Auth state | `enum AuthState { unauthenticated, authenticated(AccountID) }`, no guest case | `AuthInterface/AuthContracts.swift:6-9` |
| Login UI | Navigation controller built to be a window root, so it has no Cancel button. Only email + password works; Apple/Google/phone/registration are "not available yet" placeholders | `LoginFlowCoordinator.swift:104-127, 240-251, 282-290` |
| Sign-in → shell | `render(.authenticated)` **rebuilds the whole shell**, so signing in from a prompt would lose the current screen | `App/AppCoordinator.swift:191-201` |
| Viewer identity | No shared type. Six repositories each resolve `accountID → ListProfilesByAccount → first profile`, cache it forever and throw their own `notAuthenticated` | `FeedRepository.swift:365-387`, `CommentsRepository.swift:359-378`, `ProfileRepository.swift:528-550`, `ChatRepository.swift:484-503`, `NotificationsRepository.swift:319-338`, `PostComposer.swift:496-518` |
| Logout | Drops the shell and stops realtime. It does **not** reset repository caches, the on-disk feed snapshot, or any local store | `App/AppCoordinator.swift:179-180`, `AppContainer.swift:36, 348` |
| Transport | Authenticated client works without a token (passes through) | `AuthInterceptor.swift:23-26` |
| For You | Reads `GetFollowingFeed`; Discover and Following are two orderings of the same corpus | `ForYou/ForYouDiscovery.swift:16-22`, `dev/BACKEND_GAPS.md` §14 |
| Mock BFF | Routes never check the bearer token, and the viewer is a fixed dataset id, so mock mode cannot reveal gating bugs | `MockBackend.swift:72-77` |
| Local stores | Device-wide UserDefaults keys. Only `CountryUnlockStore` is keyed by account (and hard-wired to the mock account). `WalletStore` seeds free points on first init. | §6.6 |
| Push, analytics, deep links | None. One install id exists: `device.identifier` in UserDefaults, sent as `DeviceContext.device_id` at login | `AppContainer.swift:981-991` |

### Backend (`arnaudmaillet/core-platform-backend`, develop @ `0e79ba79`)

| Area | Today | Evidence |
| --- | --- | --- |
| Edge access levels | `Public` (reserved for Login/Refresh), `Authenticated`, `Permission(perm)`. There is no optional-auth level: a `Public` method never parses the token. | `crates/platform/transport/src/grpc/edge.rs:30-41`, `layer/edge.rs:179-182` |
| Guest / anonymous principal | None. `DeviceContext.device_id` is session metadata only | `auth/v1/messages.proto:16-22` |
| Sign-up | No `auth.v1` sign-up RPC. `CreateAccount` stays mesh-only. Keycloak has `registrationAllowed: false`. Login does not auto-provision unknown subjects. | `account/src/service.rs:43-46`, `local-dev/keycloak/realm-core-platform.json:5`, `grpc_account_directory.rs:47-51` |
| Verification / age / consent | `VerifyEmail`/`VerifyPhone` only flip a flag (no code send). No date of birth. GDPR record has consent fields, but no RPC writes them. | `account/v1/messages.proto:37-45, 73-79` |
| Discovery | No For You, ranking or recommendation service. Material that exists: `counter.GetTrending` (only the GLOBAL board is fed), `geo_discovery.QueryTile` (viewer-independent by design), `timeline.GetAudioFeed` | `counter/.../redis_counter_store.rs:109-118` |
| Viewer-aware reads | None. Post, profile, comment, social-graph and search reads ignore the caller: drafts, private profiles, hidden profiles and private follower lists are all served | §7.2 |
| Abuse controls | Rate limit scopes are `PerMethod`/`PerCaller` only, and prod uses `per_method` for everything. No per-IP scope, no WAF, no App Attest, no CloudFront. | `foundation/traffic/src/config.rs:9-16`, `k8s/overlays/prod/infrastructure.toml:24-26` |
| Realtime | Handshake requires a `did` device claim that auth never mints (likely bug for members too) | `realtime/src/config.rs:17`, `auth_context_verifier.rs:72-79` |
| Local fleet | iOS Envoy targets mesh ports, so no edge policy applies locally | `dev/envoy/envoy.yaml`, `local-dev/docker-compose.fleet.yml` |

### Related open issues

- **iOS:**
  - #394 date of birth and age gate (13+)
  - #386 in-app deletion
  - #392 push token registration
  - #399 DSA reports
  - #401 teen mode
  - #407 / #413 personalisation off
  - #409 app preferences
  - #424 legal URLs
  - Each of these has a guest dimension (§9). `dev/BACKEND_GAPS.md` already records the missing discovery feed (§14), unenforced list privacy (§13a) and search with no viewer scope (§19).
- **Backend:** #380 tile clustering and #386 geo_discovery composition root (likely stale: geo-discovery is in the prod overlay).

## 2. Benchmark

| | TikTok | Douyin | Kuaishou | RedNote | YouTube | Threads | Instagram |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Browse without an account | Yes | Yes | Yes ("visitor mode") | Web yes; app unverified | Yes (signed out) | EU/EEA only (DMA) | **No** |
| Guest feed | Weakly personalised per device | Personalised per device ID; "basic mode" is random | Random curated picks | Unverified | Empty home until 2–3 videos watched | — | — |
| Profiles, search, share link | Yes | Search yes | Unverified | Web: profiles yes, keyword search gated | Yes | Browse + search + share | — |
| Like, comment, follow, DM, post | No | No | No | No | No | No (report and mute allowed) | — |

Sources: third-party guides for TikTok (SlashGear 2023-12, TokPortal 2025-12); the Douyin privacy policy (2026-09); Kuaishou's privacy guide and basic-function policy (2025-11); Google Help; Threads' EU launch announcement (2023-12). Most in-app UX details (sheet style, resuming the action after sign-in) are not documented publicly. They are common practice, not verified facts.

What we take from it:
- **Every Chinese app ships a visitor mode because the law requires it.** Since 2021, CAC/MIIT rules define video search and playback as a basic function that must not require personal information.
- **The EU pushes the same way.** Threads' no-profile mode came from the DMA; very large platforms must offer a non-profiled feed under the DSA.
- **Apple backs it up.** Guideline 5.1.1(v): if an app "doesn't include significant account-based features, let people use it without a login." Browsing public posts is not account-based, so a login wall is challengeable at review.
- **Guests are read-only everywhere.** The common set is: watch, open profiles, read comments, search, share a link. Every write is gated.
- **The prompt is per action, not on a timer.** It is usually a half sheet with context ("Sign up to like").
- **Guest personalisation is a choice, not a given.** Douyin and TikTok personalise per device. Kuaishou's visitor mode is random curated content. YouTube chose to show nothing. We start non-personalised (decision 3). Apple 5.1.1(ii) requires consent for usage data "even if such data is considered to be anonymous".

## 3. Guest scope and rights

### Principles

1. **Read public, write nothing.** A guest sees what a logged-out web visitor would see: public posts, public profiles, comments, the map, search. Every write that creates content, a relationship, or economy state is gated.
2. **A gate is an invitation, not an error.** Every gated control stays visible and opens the sign-up sheet. Hidden controls are reserved for things that make no sense without an identity (a Following scope, the favourites dock).
3. **The action survives sign-up.** The pending action is replayed after the account exists: a like lands, a follow lands, a comment draft is kept.
4. **Safety and legal features stay open.** Reporting illegal content must be available to "any individual or entity" (DSA Art. 16), and Apple 1.2 requires a report mechanism for user-generated content. Guests can report.
5. **Device-only state is honest.** Nothing earned or bought is spendable on a guest device, and nothing can be bought. A guest sees what is waiting for them (§3.2), locked until sign-up, when the server credits it.

### Rights matrix

✅ allowed · 🔒 visible, opens the sign-up sheet · — hidden for guests

| Surface | Capability | Guest | Notes |
| --- | --- | --- | --- |
| For You | Discover feed (cards, snap feed, post detail) | ✅ | Needs the discovery feed (§7.3). Sensitive content filtered by default (§8). |
| For You | Following segment | 🔒 | Empty state: "Follow creators to see their posts here" + sign up |
| For You | Friends stories row, Following rows | — | Need a follow graph |
| Post | Watch, scrub, mute, captions, comment ticker (display) | ✅ | |
| Post | Like / boost / stake (card chip, rail, detail) | 🔒 | Counts still visible |
| Post | Comment, reply, emote, comment like | 🔒 | Tapping the input field opens the sheet; its placeholder says "Sign up to comment" |
| Post | Read comments and replies | ✅ | |
| Post | Save / bookmark | 🔒 | Benchmark gates it; avoids orphaned device bookmarks |
| Post | Repost | 🔒 | Not wired in the app yet |
| Post | Share sheet, copy link | ✅ | The acquisition loop; needs universal links to land (§6.7) |
| Post | Send to friends (DM quick-send row) | — | Needs a graph |
| Post | Not interested | ✅ | Local today; becomes a guest signal (§7.4) |
| Post | Report post / comment / profile | ✅ | DSA Art. 16. Backend must accept a guest reporter (§7.1). |
| Post | Block | — | No identity to protect |
| Sound | Sound sheet, preview | ✅ | |
| Sound | Save sound, Use this sound | 🔒 | "Use" opens the camera |
| Profile (others) | Public profile, gallery, followers/following of public accounts | ✅ | Private accounts show the private header only |
| Profile (others) | Follow, Message, add to map favourites | 🔒 | |
| Profile tab | Own profile | 🔒 | Full-page sign-up state + Settings gear |
| Map | Map, pins, clusters, place pages, galleries | ✅ | `QueryTile` is viewer-independent |
| Map | Posts in the country the device is in | ✅ | Only once location is allowed (§3.1) |
| Map | Favourites dock (following/friends rails) | — | |
| Map | Follow place, unlock another country, shop | 🔒 | Economy is account-bound |
| Search | Results, trending, people, hashtags | ✅ | |
| Search | Recent searches | ✅ | Device-local, as today |
| Search | "Following" scope | — | |
| Messages tab | Inbox, requests, suggestions | 🔒 | Full-page state: "Sign up to message friends" |
| Notifications | Bell + drawer | 🔒 | Drawer shows the sign-up state; no badge |
| Create "+" | Camera, upload, text post, long-press camera | 🔒 | TikTok behaviour: the "+" stays, a tap opens the sheet |
| Wallet | Balance badge, wallet sheet | ✅ | The badge shows the welcome gift (§3.2) and pulses; the sheet's Claim button is locked |
| Wallet | Daily claim, spending likes, shop | 🔒 | The sheet names the amount waiting |
| Settings | Language, app preferences (#409), captions, comment ticker, data saver, clear cache, personalisation off, help, legal, "delete my guest data" | ✅ | Reached from the Profile tab gear |
| Settings | Everything account-scoped | — | Shown after sign-up |
| Realtime | Live counters, typing, presence | — | Counts refresh on load and pull-to-refresh |

### 3.1 Location unlocks the current country

**Rule.** When the person allows location (guest or member), the country the device is in is unlocked on the map, for free. Every other country stays locked: a member unlocks it with gems, while a guest who taps one gets the sign-up sheet.

Location is implemented by `CurrentCountryProvider` (Maps, CoreLocation, reduced accuracy). Against the fleet, `countryAccess` is still `nil`, so every country is open to members.

**Guest map without location (#564).** While a guest has not allowed location (never asked, or denied), the map is a locked showcase:
- the whole world, at the widest zoom MapKit allows;
- a dark veil over it;
- no pan, zoom, rotate, pitch, marker or country tap;
- no filter pills and no compass.

The "See posts around you" card sits above the veil and stays usable. When location is allowed, the veil fades, the map unlocks and flies to the current country. That happens from the card, or from iOS Settings and back. A guest who signs up while locked is unlocked at once. Members are never locked. The location provider reaches the map on the fleet too, so the lock can unlock there.

How it works:

| Step | Behaviour |
| --- | --- |
| Ask | Never at launch. The system prompt only comes after the person taps something: the map's locate button, or a card on the map ("See posts around you", shown to anyone with no unlocked country). Apple 5.1.1 expects permission in context. |
| Precision | Approximate location is enough (`kCLLocationAccuracyReduced`; `NSLocationDefaultAccuracyReduced = YES`). Country borders are kilometres wide. |
| On device | The coordinate becomes a country code through the bundled borders (`CountryAtlas.shared.country(owning:)`). **Only the ISO code leaves the device, never the coordinate.** |
| Unlock | `CountryAccess` gains `currentCountry: String?`. `isUnlocked(code)` = home, purchased, or current. The map refreshes through the existing `.countryAccessDidChange` notification. |
| Refresh | Re-read at each app foreground and on significant location change. Travelling unlocks the new country; the previous one locks again unless it is home or purchased (decision 10). |
| Denied or unavailable | No country is unlocked from location, and there is no storefront fallback (decision 9). The card stays on the map and links to iOS Settings. Members keep their home country. |
| Member home country | Set at sign-up from the current country when known, otherwise from the App Store storefront country. It stays unlocked for good, as `BACKEND_COUNTRY_UNLOCKS.md` already proposes (`home_country`, "set at signup"). |

**The server enforces it.** Following `BACKEND_COUNTRY_UNLOCKS.md`, which says the client never filters the map on the device's word:
- The client sends `current_country` (a code, not a coordinate) with `GetCountryAccess` and the guest session.
- The server grants it only if it matches the request's IP country (ALB/CloudFront GeoIP header), within tolerance for roaming. Without that check, a spoofed GPS position would open any country for free and undercut the gem price.
- For a guest principal, the granted set is {current country}, and `QueryTile` filters to it server-side.

### 3.2 Welcome gift: likes waiting for sign-up

**Rule.** At first launch a guest is shown a welcome gift of **50 likes**, and a daily allowance keeps piling up for **3 days**. None of it can be spent as a guest: it is credited when the person signs up, then the action they were attempting replays with it.

| | |
| --- | --- |
| Welcome gift | 50 likes, granted at first launch |
| Daily allowance | One un-streaked claim per day (`WalletStore.Policy.baseClaimAmount`, 25 today) |
| Accumulation cap | 3 days (75), so at most 125 likes waiting |
| Where it shows | The wallet badge shows the amount with the claim-ready pulse and opens the wallet sheet, where the Claim button carries the lock ("🔒 Claim 75 likes"). Nothing pops up (decision 8). |
| What a tap does | The sheet's Claim button opens the sign-up sheet titled with the amount: "Sign up to claim your 125 likes". A like says "Sign up to use your 125 likes". |
| At sign-up | The server credits the gift and the accrued days, then the pending action replays (the like is spent from the new balance) |
| Once per device | Keyed to the guest id and App Attest (B1): a second account on the same device gets no second gift |

**Why the likes stay locked.**
- A like is a write that counts. The guest feed is regional trending (decision 3), built from likes; guests who could like would let bots mint guests and push any post into everyone's feed.
- The wallet is device-local today (`WalletStore`). A spendable guest balance would need guest writes and a server wallet; a locked one needs neither until sign-up.

**Honesty rules.**
- No countdown and no "expires in 24 h": the EU treats false urgency as a dark pattern (DSA Art. 25, consumer law).
- The label says "welcome gift"; what was shown is never taken away. The cap only stops more from piling up.

**Measure it.** Sign-up rate with and without the gift, through the same A/B switch as the claim sheet.

### Gated actions as a single list

This is the `GatedAction` enum the code would carry (§6.3). Each case maps to one sheet title.

| Action | Sheet title |
| --- | --- |
| `like` | Sign up to use your N likes (N = the amount waiting, §3.2) |
| `comment` | Sign up to join the conversation |
| `follow(profile)` | Sign up to follow @handle |
| `save` | Sign up to save posts |
| `repost` | Sign up to repost |
| `message(profile)` | Sign up to message @handle |
| `create` | Sign up to post |
| `useSound` / `saveSound` | Sign up to use this sound |
| `followingFeed` | Sign up to see posts from people you follow |
| `inbox` | Sign up to message friends |
| `notifications` | Sign up to get notified |
| `ownProfile` | Sign up to create your profile |
| `followPlace` / `unlockCountry` / `shop` | Sign up to explore more places |
| `claim` | Sign up to claim your N likes |

## 4. First launch

1. **No onboarding, no login, no interest picker in v1.** The first frame after the launch screen is the For You feed. An interest picker can come later as an optional, skippable card *inside* the feed, never as a gate.
2. **Guest session.** A guest session token is fetched in the background on first launch (§7.1). The first feed request awaits it, adding about one round trip. It is kept in the keychain and refreshed like a member token. If the request fails, the feed shows its normal error and retries.
3. **Legal notice.**
   - A one-time, non-blocking card at the bottom of the first feed session: "By using the app you agree to the Terms and acknowledge the Privacy Policy", with links (#424) and a dismiss button.
   - It does not block the feed (decision 7). Guests get no personalisation in v1 (decision 3), which keeps the card sufficient; counsel still reviews the wording before launch.
   - No ATT prompt: the app has no IDFA, ads or cross-app tracking.
4. **No age gate for guests.** Age is asked at sign-up (#394, 13+). Because a guest's age is unknown, guests get the restricted content level by default (§8).
5. **No location prompt at launch.** Location is asked only from the map, in context (§3.1).

## 5. Sign-up prompt and conversion

**The sheet.**
- A sheet exactly as tall as the step it shows, with a contextual title from the gated action. It has one content-sized detent, capped at the screen's height (taller content scrolls), and it cannot be dragged taller than its content. Pushing or popping a step animates it to that step's height (#563).
- Below the title: Continue with Apple, Continue with Google, then Continue with email / phone (decision 2).
- Footer: "Already have an account? Log in".
- It is dismissible by swipe or ✕, and dismissing does nothing else: no nag, no counter.
- It opens over whatever is on screen, including a hero-presented post or another sheet.

**Methods.**
- **Sign in with Apple is the primary button.** It costs the user the fewest steps, and because Google is offered, guideline 4.8 requires an equivalent privacy-preserving login: Sign in with Apple is that login.
- **Continue with Google** comes second, through `ASWebAuthenticationSession` and the IdP's Google broker (no Google SDK needed).
- Email and phone follow, with OTP verification.
- Password login stays for existing accounts.
- **One person, one account.** If a sign-up's verified email already belongs to an account created with another method, the sheet offers to log in with that method instead of creating a duplicate. Apple's private relay addresses never match, so linking methods from Settings comes later.

**Sign-up flow** (inside the sheet, expanding to large):
1. Method.
2. Verification code, if email or phone.
3. Date of birth (#394).
4. Handle, with live availability; display name pre-filled from Apple when shared.
5. Done.

The account and its first profile are created in one flow. If the app is killed in between, the account exists without a profile: the next gated action reopens the sheet at step 4 ("Finish setting up").

**After success:**
- **Navigation is kept.** The sheet dismisses onto the same screen; the shell is not rebuilt (§6.2).
- **The pending action replays** (the like lands, the follow lands, the comment composer opens with the draft) and a short toast confirms it.
- The Profile and Messages tabs switch from their sign-up state to real content.
- Guest signals (not-interested, watch history once telemetry exists) are attached to the new account (§7.4).
- The current country, if known, becomes the member's home country (§3.1).
- The welcome gift and the accrued daily likes are credited (§3.2) before the pending action replays.

**Logout returns to guest mode, not to a login screen.** Member-scoped local state is wiped (§6.6); device preferences stay.

**No nudges, unlimited browsing (decision 8).** A guest is never interrupted, capped or reminded: the only sign-up prompts are the ones their own taps open. Abuse is handled server-side by rate limits (§7.7), not by a browsing cap.

## 6. iOS architecture

### 6.1 One viewer model instead of six resolvers

Replace `AuthState` and the six per-repository resolvers with one source of truth in `AuthInterface`:

```swift
public enum ViewerState: Equatable, Sendable {
    case guest(GuestID)                                 // guest session token held
    case member(AccountID, activeProfile: ProfileID?)   // nil = sign-up not finished
}

public protocol ViewerProviding: Sendable {
    func current() async -> ViewerState
    func updates() -> AsyncStream<ViewerState>          // emits current, then changes
    func activeProfileID() async throws -> ProfileID    // throws ViewerError.requiresMember
}
```

- `SessionManager` becomes the single owner of both tokens (guest and member). `AuthTokenProviding.validAccessToken()` returns the member token when there is one, and the guest token otherwise.
- `activeProfileID()` moves into this provider. That deletes the duplicate `resolveViewerProfileID()` copies, and it fixes the known gap that Feed, Chat, Notifications and PostComposer never hear a profile switch.
- Repositories that cache viewer-scoped data adopt `ViewerScoped { func viewerDidChange(_:) }` and drop their caches on every transition (guest→member, member→guest, profile switch).
  - Today logout leaves `FeedRepository.viewerProfileID`, `ProfileCache` and the feed snapshot from the previous user in place. That is a bug even without guest mode.

### 6.2 The shell always exists

- `AppCoordinator.start()` builds `MainTabCoordinator` immediately, for any `ViewerState`. `render(_:)` no longer swaps the window root.
- On a viewer change it calls `mainTabCoordinator.viewerDidChange(_:)`, which:
  - swaps the root of the Profile and Messages tabs between their sign-up state and real content;
  - switches the wallet badge between the locked gift and the real balance, and shows or hides the notification badge and the favourites dock;
  - leaves every navigation stack in place.
- The login screen stops being a window root. `AuthFeatureBuilding` gains:

```swift
func makeSignUpSheet(for action: GatedAction?, completion: @escaping (SignUpOutcome) -> Void) -> UIViewController
```

  `LoginFlowCoordinator` gets a close button and reports `.signedIn` / `.cancelled` instead of relying on the window root swap.
- `-mock-auto-login` keeps working (it logs in, so the viewer becomes a member). A new `-guest` DEBUG argument wipes the member session and the member-scoped stores to simulate a fresh install. UI tests and the `verify` skill keep `-mock-auto-login` as their default.

### 6.3 The gate

The protocol lives in `CoreModels` (Kit), so every feature *and* the Core UI packages (PostGrid, DesignSystem) can reach it without importing Auth:

```swift
public enum GatedAction: Sendable, Equatable { case like, comment, follow(ProfileID), save, repost, message(ProfileID),
    create, useSound, saveSound, followingFeed, inbox, notifications, ownProfile, followPlace, unlockCountry, shop }

@MainActor public protocol MemberGating: AnyObject {
    var isMember: Bool { get }
    /// Returns true at once for members. For guests, presents the sign-up sheet
    /// over the top-most controller and returns true only after a successful sign-up.
    func requireMember(for action: GatedAction) async -> Bool
}
```

- The App target implements it (`MemberGate`) and injects it from `AppContainer`, like `SocialGraphWriting` today.
- For leaf controls that have no injected dependencies, a responder-chain lookup is added, the same shape as `StakeShopOpening` (`DesignSystem/Components/StakeShopOpening.swift:15-60`). `ShellTabBarController` adopts it.

Call sites read the same everywhere:

```swift
guard await gate.requireMember(for: .follow(author.id)) else { return }
try await socialGraph.setFollowing(true, profile: author.id)
```

Gate where the action starts, at a handful of choke points rather than in every view:

| Choke point | Covers |
| --- | --- |
| `PostCardStaking.stake` (`PostCardStaking.swift:116`) | Every card like chip (For You grid, rails, profile gallery) |
| Snap `performBoost` (`SnapFeedViewController.swift:2513`) and post-detail `onBoost` / `toggleLike` | Rail and detail likes |
| `CommentsInputBar` focus / `sendTapped` (`CommentsInputBar.swift:838`) | Comments, replies, emotes; also covers chat sends, though those are unreachable for guests |
| `SocialGraphWriting` call sites (`followAuthor`, `ProfileViewModel.toggleFollow`, relationship lists, suggestions) | Follow everywhere |
| `MainTabCoordinator.openCreate` (`:715`) and `openCamera` (`:706`) | All "+" entries and "Use this sound" |
| `toggleBookmark` call sites | Save |
| `RouteResolver` `.messageUser` / `.sendLink` | Message buttons |
| `CountryUnlockSheetViewController` unlock, `CountryShopViewController` | Unlock another country, shop |

**Defence in depth.** Write repositories throw `ViewerError.requiresMember` when called by a guest. A DEBUG assertion flags any write that reached the network without passing the gate.

### 6.4 Guest surfaces

| Surface | Guest state | Building block |
| --- | --- | --- |
| Profile tab | Full-page `EmptyStateView`: icon, "Sign up for an account", button; Settings gear in the header | `EmptyStateView.swift` |
| Messages tab | Same pattern; the inbox is not primed at shell start (`MessagesTabCoordinator.swift:58`) | |
| Notifications drawer | Sign-up state, no unread polling | `NotificationsFeatureBuilder.swift:33-35` |
| For You → Following | Sign-up state inside the page; Discover is the default | |
| Wallet badge | Locked welcome gift (§3.2); a tap opens the gate | `WalletBadgeInstaller` |
| Map favourites dock | Not shown | `MapFavoritesRepository` |
| Map location card | "See posts around you" when no country is unlocked; tap → location prompt (§3.1) | |
| Settings | Guest catalog (§3) reusing `SettingsCatalog` sections | `SettingsCatalog.swift` |
| Comment input | Placeholder "Sign up to comment"; focus opens the gate | `CommentsInputBar` |

### 6.5 Data

- **Discover feed.** A new `DiscoveryFeedRepository` behind the existing `ForYouRepository` seam calls the discovery RPC (§7.3). Today's client-side Trending/Recent orderings fall away, as `ForYouDiscovery.swift` already anticipates.
- **Search trending.** The trending section reads the same discovery source, not the following timeline (`AppContainer.swift:791-796`).
- **Profiles seen as a guest.**
  - The relationship is simply "none": skip `GetRelationStatus` instead of letting it fail silently into a hidden header (`ProfileViewModel.swift:993-1001`).
  - Follow shows and is gated.
- **Realtime.** Not started for guests. `RealtimeClient` must not sit in its token-retry loop (`RealtimeClient.swift:124-128`).
- **Location.** A `CurrentCountryProvider` in Maps (CoreLocation, reduced accuracy) feeds `CountryAccess.currentCountry` (§3.1). `App/Info.plist` gains `NSLocationWhenInUseUsageDescription`.
- **Media.** Delivery URLs must be public CDN URLs (§7.7); the fleet placeholder image fetcher is already a known gap.

### 6.6 Local state policy

| Store | Guest | On sign-up | On logout (back to guest) |
| --- | --- | --- | --- |
| `device.identifier` (install id) | Used for the guest session | Kept | Kept |
| Keychain `auth.session` | Holds the guest token | Replaced by the member token | Replaced by a guest token |
| `WalletStore` (`wallet.*`) | **Pending, not spendable**: welcome gift + accrued days (§3.2) | Replaced by the server-credited balance, keyed by account | Wiped (the gift is never offered again on this device) |
| `CountryUnlockStore` | Empty (the current country comes from location and is never stored as an unlock) | Keyed by the real account (not `MockAuthService.accountID`) | Kept per account |
| `PostBookmarkStore`, `SavedSoundStore`, `MapPlaceFollowStore`, `MapFavoritesStore` | Unused (gated) | Keyed by profile | Wiped |
| `PostDraftStore` | Unused (gated) | Keyed by profile | Wiped |
| Feed snapshot `feed-first-page` | Discovery snapshot | Re-keyed by viewer | Wiped |
| `RecentSearchStore`, `EmoteRecents`, `GalleryPreferences`, `ContentContextStore`, `ForYouUnread` / `ForYouSeenPostsStore` | Device-local, kept | Kept | Kept (device preferences) |
| `RelationshipPrivacyStore` | Unused | Keyed by profile (until server-side, #403) | Wiped |
| Not-interested list | Local, sent with guest signals | Attached to the account | Kept |

The rule behind the table:
- Device preferences stay across logout.
- Anything that expresses an identity (saves, follows, drafts, money) is keyed by profile or account and wiped on logout.

A small `ScopedDefaults(scope: .device | .account(id) | .profile(id))` wrapper avoids hand-building keys in fifteen stores.

### 6.7 Supporting pieces

- **Universal links** (P1): share and copy link are the guest acquisition loop. Today `SceneDelegate` handles neither `openURLContexts` nor `userActivity`, and there is no associated-domains entitlement. A shared post link must open the post in the app for a guest without any sign-in.
- **Mock harness** (P0):
  - `MockBackend` must check the bearer token and apply a route policy that mirrors the backend `EDGE_POLICY`: public reads accept a guest token, writes require a member.
  - Without this, mock mode passes every gating bug.
  - `MockAuthService` gains the guest-session and sign-up routes.
- **Tests:**
  - A guest UI smoke suite: launch with `-guest`, scroll For You, open a profile, read comments, tap like (the sheet appears), sign up with mock credentials, check that the like landed and the navigation stack is unchanged.
  - Unit tests for `MemberGate` replay, and for `viewerDidChange` cache resets.

## 7. Backend work

### 7.1 Guest principal (P0)

Decided: a guest session token (option A). It fits ADR-0005 and gives per-guest rate limits and attribution. Optional auth (option B: decode a token when present, pass through otherwise) was simpler but anonymous to the rate limiter and to personalisation.

```proto
// auth.v1 — edge: public
rpc StartGuestSession(StartGuestSessionRequest) returns (StartGuestSessionResponse);

message StartGuestSessionRequest {
  DeviceContext device = 1;        // install id, platform, app version
  string attestation = 2;          // App Attest assertion (DeviceCheck fallback)
  string locale = 3;
  string region_hint = 4;          // store country, for discovery
  string current_country = 5;      // ISO code from location, when allowed (§3.1); verified against IP
}
message StartGuestSessionResponse { string guest_id = 1; TokenPair tokens = 2; }
```

**The token.**
- It carries `sub = guest:<uuid>`, `kind = "guest"`, `perms = ["read:public"]`, no `pids`, and a `did` claim (which also fixes the realtime mismatch).
- It is refreshed through the existing `Refresh`.

**Edge policy.**
- Public read RPCs move from `authenticated(...)` to `permission(..., "read:public")`; members carry the permission too.
- Every write stays `authenticated` and additionally rejects `kind = guest`.
  - Today `require_profile` would already fail for a guest (no `pids`), but `require_account` would not: the guest check must be explicit.

**Reads guests need** (all viewer-free today):
- `post.GetPost`, `ListPostsByProfile`
- `profile.GetProfileById`, `GetProfileByHandle`
- `comment.GetComment`, `ListTopLevel`, `ListReplies`
- `counter.BatchGetCounters`, `GetTrending`
- `engagement.GetPostEngagement`, `RecordView`, `RecordShare`
- `social_graph.ListFollowers`, `ListFollowing`
- `geo_discovery.QueryTile`, `GetGeoTimeline`
- `search.Search`, `Suggest`, `MultiSearch`
- `media.ResolveDelivery`, `BatchResolveDelivery`
- `timeline.GetAudioFeed`
- the new discovery feed (§7.3)

**Writes open to guests:**
- `moderation` report (DSA Art. 16), with the guest id as reporter and a per-guest rate limit.
- `StartGuestSession` itself.

### 7.2 Viewer-aware public reads (P0, and a bug today)

Before any read opens to guests:

| Read | Required change |
| --- | --- |
| `GetPost`, `ListPostsByProfile` | Serve only `PUBLISHED` and not-taken-down posts to anyone but the author. `GetPost` returns any status today (`post/src/application/query/get_post.rs:26-31`). Post does not consume `moderation.v1.events`. |
| `GetProfileById/ByHandle` | Hide `HIDDEN`/`SUSPENDED` profiles. For `PRIVATE`, return the header only to non-followers, which includes every guest. |
| `ListPostsByProfile`, comments, lists of a private profile | Empty for non-followers |
| `ListFollowers` / `ListFollowing` | Honour list privacy (`BACKEND_GAPS.md` §13a) |
| Search | Exclude private, hidden and moderated content, server-side |

The viewer comes from the principal (`guest` or `member`), not from a request field. Members get block filtering from the same layer, which `event-topology/src/lib.rs:189` claims exists but no read path implements.

### 7.3 Discovery feed (P0)

```proto
// timeline.v1 — edge: read:public
rpc GetDiscoveryFeed(GetDiscoveryFeedRequest) returns (GetDiscoveryFeedResponse);
message GetDiscoveryFeedRequest {
  DiscoveryRanking ranking = 1;   // FOR_YOU | TRENDING | RECENT | NEARBY
  string region = 2; double lat = 3; double lng = 4;
  ContentLevel content_level = 5; // RESTRICTED for guests and minors
  string page_token = 6; int32 limit = 7;
}
```

- The viewer comes from the token. v1 can be non-personalised:
  - a time-decayed trending board per region (today only a GLOBAL all-time board is fed);
  - a freshness mix;
  - a NEARBY pool from `geo_discovery`.
- Personalisation keyed by `guest_id` or `profile_id` comes in v2 (§7.4).
- **Members need this RPC too.** The For You tab has no real source today (`BACKEND_GAPS.md` §14).

### 7.4 Signals and the guest → member merge (P1)

- **`engagement.RecordImpressions`** takes `repeated {post_id, surface, position, dwell_ms, watch_ms}`. The actor comes from the token. It produces the deferred `view.v1` / `impression.v1` / `click.v1` topics, which have consumers but no producer (`event-topology/src/lib.rs:131-133`).
- **`RecordNotInterested`** for the feed's "Not interested".
- **Sign-up accepts the guest token.** The new account inherits the guest's signals; the guest id is then retired.
- **Guest data deletion.** "Delete my guest data" in guest settings calls `auth.DeleteGuestData` and erases signals keyed by `guest_id`. This is GDPR Art. 17 for device-keyed data.

### 7.5 Sign-up path (P0)

| Need | Proposal |
| --- | --- |
| Create an account from the client | Enable Keycloak self-registration with brokered Sign in with Apple and Google, plus auto-provisioning in `GrpcAccountDirectory::resolve_or_provision` (the deferred TODO at `:47-51`). Alternatively, a public `auth.v1.SignUp` that drives the IdP. Either way, `Login`/`SignUp` can take the guest token for the merge. |
| Verify email / phone | `account.v1.SendVerificationCode` + `ConfirmVerificationCode` (today `VerifyEmail` only flips a flag) |
| Date of birth | Field on the account, set at sign-up, 13+ enforced server-side (#394) |
| Consent | `account.v1.RecordConsent{consent_version, data_processing, marketing}`; the GDPR record fields already exist |
| Handle | `profile.v1.CheckHandleAvailability` (callable with a guest token) |
| Welcome gift | Sign-up credits 50 likes plus the accrued daily allowance (25 a day, 3 days at most) to the new account, once per device (guest id + App Attest). Needs a server wallet (`BACKEND_VIRTUAL_CURRENCY.md`). |
| Fresh profile ids | After `CreateProfile`, return re-minted tokens or document a mandatory `Refresh`. `pids` are only minted at Login/Refresh, so the first write after sign-up fails `require_profile` otherwise. |

### 7.6 Country access from location (P1)

Extend the `BACKEND_COUNTRY_UNLOCKS.md` proposal:

- `GetCountryAccessRequest.current_country`: an ISO code the client derived on device.
- `GetCountryAccessResponse.current_country`: echoed only when it is granted.
- The grant requires a match with the request's GeoIP country.
- Guests get country access too: their set is {current country}, and `QueryTile` / `GetGeoTimeline` filter to it for a guest principal.
- `home_country` is written at sign-up (current country, else storefront).

### 7.7 Abuse, delivery and environments (P0)

- **Rate limiting:**
  - add a per-IP scope in `foundation/traffic` (trusted client-IP header from the ALB) and a per-guest scope;
  - switch prod from `per_method` to `per_caller` (today one scraper can exhaust a method's bucket for everyone);
  - apply strict limits on `StartGuestSession`.
- **App Attest** verification on `StartGuestSession` (DeviceCheck fallback). **AWS WAF** on the ALB: rate-based rules and bot control.
- **CloudFront** in front of the media bucket so `PUBLIC` delivery URLs resolve. This is needed for members too.
- **Realtime:** fix the `did` claim mismatch (`REALTIME_DEVICE_CLAIM=did`, never minted). Guests get no realtime in v1.
- **Local fleet:** an edge-mode compose profile (`GRPC_EDGE_ADDR` set, Envoy pointed at `:9443`) so iOS can test gating against real policy.

## 8. Compliance and safety

| Topic | Decision |
| --- | --- |
| Apple 5.1.1(v) | Guest mode is the defensible posture. In-app deletion stays required for members (#386). |
| Apple 4.8 | Google is offered, so Sign in with Apple ships alongside it as the equivalent login |
| Apple 5.1.1(ii) | v1 guests get a non-personalised feed (decision 3), so no usage-data consent is needed yet. If guest personalisation comes later, it ships with a "Personalised feed" toggle that is easy to withdraw. |
| Age and minors | No age gate for guests. Guests get `ContentLevel.RESTRICTED`: no sensitive or mature content until a date of birth is known. This also covers DSA Art. 28 (minors) and teen mode (#401). |
| GDPR | Privacy policy names guest data (install id, guest id, signals), the retention period, and the merge at sign-up. Guest data is erasable from the device. |
| Dark patterns | The welcome gift has no countdown or expiry and is labelled as a gift (DSA Art. 25, consumer law) |
| DSA | Guests can report (Art. 16). A non-profiled feed option is required for very large platforms; `ranking = TRENDING` provides it. |
| ATT | Not needed (no IDFA, no ads) |
| Location | When-in-use, reduced accuracy, asked in context. Only a country code leaves the device. The privacy policy and App Privacy label list "coarse location, app functionality". |

## 9. Delivery plan

**Phase 0: contracts (1 week).** Decisions are settled (§10). Backend designs the guest token, edge permission and discovery contract; iOS pins them in the mock.

**Phase 1: iOS guest shell on the mock (no backend dependency).**

| # | Issue | Priority |
| --- | --- | --- |
| G1 (#437) | `ViewerState` + `ViewerProviding`, one active-profile resolver, `ViewerScoped` cache resets (fixes logout leaking the previous user's caches) | P0 |
| G2 (#438) | Shell always built; `viewerDidChange` swaps Profile/Messages roots; logout returns to guest | P0 |
| G3 (#439) | `MemberGating` + `MemberGate` + responder-chain lookup + `GatedAction` sheet titles | P0 |
| G4 (#440) | Gate every choke point in §6.3; DEBUG assertion on ungated writes | P0 |
| G5 (#441) | Sign-up sheet: login flow as a dismissible half sheet, pending-action replay | P0 |
| G6 (#442) | Guest surfaces: Profile/Messages/Notifications/Following states, locked welcome-gift badge, favourites dock hidden, guest Settings catalog | P0 |
| G7 (#443) | `ScopedDefaults` and the local-state policy of §6.6; guest wallet = pending welcome gift + 3-day accrual, not spendable | P0 |
| G8 (#444) | Mock: bearer checks + edge-policy mirror, guest session and sign-up routes, `-guest` launch argument, guest UI smoke suite | P0 |
| G9 (#445) | Location unlocks the current country (§3.1): in-context permission, reduced accuracy, on-device country code, `CountryAccess.currentCountry` | P1 |

**Phase 2: backend launch blockers (parallel to phase 1).**

| # | Item | Priority |
| --- | --- | --- |
| B1 (#446) | `StartGuestSession`, guest token claims, `read:public` permission, guest rejection on writes; guest start date and device recorded for the welcome gift | P0 |
| B2 (#447) | Viewer-aware public reads (§7.2) | P0 |
| B3 (#448) | `GetDiscoveryFeed` v1, non-personalised, regional trending with decay | P0 |
| B4 (#449) | Sign-up path: self-registration + Sign in with Apple and Google, OTP verification, date of birth, consent, handle availability, token re-mint, welcome-gift credit | P0 |
| B5 (#450) | Per-IP / per-guest rate limits, `per_caller` in prod, App Attest, WAF | P0 |
| B6 (#451) | CloudFront for media delivery | P0 |
| B7 (#452) | Guest reports accepted by moderation | P0 |
| B8 (#453) | Edge-mode local fleet profile | P1 |
| B9 (#454) | Realtime `did` claim fix | P1 |
| B10 (#455) | Country access from location: `current_country` verified against GeoIP, guest country set, `home_country` at sign-up (§7.6) | P1 |

**Phase 3: real network and conversion.**
- **iOS** (P0): sign-up screens (Sign in with Apple, Google, OTP, date of birth, handle) on real contracts; discovery repository; guest token in `SessionManager`.
- **iOS** (P1): universal links.
- **Backend** (P1): sign-up with guest-token merge.

**Phase 4: personalisation and growth.**
- `RecordImpressions` / not-interested signals.
- Personalised `FOR_YOU` for guests (with the consent toggle), if v1 data says it is worth it.
- Optional in-feed interest card.
- Push for guests (#392, keyed by install).
- A/B measurement of the welcome gift's effect on sign-up.

The existing settings issues that gain a guest variant: #409 (app preferences, guest-visible), #407/#413 (personalisation off, guest-visible), #424 (legal links in guest settings), #399 (reports, guest reporter), #386 (guest data deletion next to account deletion).

## 10. Decisions (settled 2026-10-03)

| # | Question | Decision |
| --- | --- | --- |
| 1 | Guest principal | Guest session token (§7.1) |
| 2 | Sign-up methods at launch | Sign in with Apple, Google, email or phone. Apple satisfies guideline 4.8 next to Google; duplicate accounts are avoided by email matching (§5) |
| 3 | Guest personalisation in v1 | None: non-personalised regional trending |
| 4 | Content level for guests | Restricted by default |
| 5 | Guest reporting | Allowed (DSA Art. 16) |
| 6 | Bookmarks | Gated |
| 7 | First-run legal notice | Non-blocking card; counsel reviews the wording |
| 8 | Nudges | None; guest browsing is unlimited |
| 9 | Guest map without location | No country unlocked; the map invites the person to allow location, which unlocks the country they are in |
| 10 | Country left behind | Locks again; the new country unlocks |
| 11 | Likes for guests | A locked welcome gift of 50 likes, plus a daily allowance that piles up for 3 days; all claimed at sign-up (§3.2) |

## Appendix: interaction inventory

Every write in the app today, with its handler, grouped by feature. "Gate" is the `GatedAction` it maps to.

| Feature | Action | Handler | Gate |
| --- | --- | --- | --- |
| Snap feed | Boost/stake (like) | `SnapFeedViewController.swift:2513-2570` (undo `:2572`) | `like` |
| Snap feed | Follow author "+" | `:1884-1895` | `follow` |
| Snap feed | Save | `:2215-2231` | `save` |
| Snap feed | Share | `:4919-4928` | open |
| Snap feed | Not interested | `:4975-4983` | open |
| Snap feed | Report | `:4993-5008` | open |
| Snap feed | Save sound / Use sound | `SoundSheetViewController.swift:651, 1639` | `saveSound`, `useSound` |
| Post detail | Comment / reply send | `PostDetailViewController.swift:761-770` → `PostDetailViewModel.swift:229-243` | `comment` |
| Post detail | Comment like (in memory only) | `PostDetailViewModel.swift:467-473` | `comment` |
| Post detail | Post like | `PostDetailViewModel.swift:193-204` | `like` |
| Post detail | Boost / undo | `PostDetailViewController.swift:778-816` | `like` |
| For You / grids | Card like chip | `PostCardStaking.swift:116-140` | `like` |
| For You / grids | Bookmark | `ForYouGridPage.swift:3386`, `ForYouRailsView.swift:500` | `save` |
| For You / grids | Unfollow / report from "…" | `ForYouViewController.swift:1036-1078` | `follow` / open |
| Place page | Follow place | `PlaceProfileViewController.swift:1858` | `followPlace` |
| Text post | Publish, drafts | `PostDetailViewModel.swift:252-286`, `TextPostComposerViewController.swift:348-494` | `create` |
| Upload | Post media | `NewPostViewController.swift:1147, 1258` | `create` |
| Profile | Follow / unfollow | `ProfileViewModel.swift:551-573` | `follow` |
| Profile | Message | `:575-580` | `message` |
| Profile | Block / unblock | `:599-634` | hidden |
| Profile | Report profile / post | `:655-698, 746-764` | open |
| Profile | Send profile in DM | `:585-589` | hidden |
| Profile | Edit profile | `EditProfileViewModel.swift:120, 132` | `ownProfile` |
| Profile | Map categories | `:493-509` | `ownProfile` |
| Relationship lists | Follow, remove follower | `ProfileRelationshipsViewModel.swift:343-378` | `follow` / own only |
| Chat | Send, reply, delete, mark read, requests, suggestions follow | `ConversationViewModel.swift:218-325`, `MessageRequestsViewController.swift:317-326`, `SuggestionsViewModel.swift:99-121` | `inbox` (tab gated) |
| Maps | Pin favourite | `MapsViewController.swift:1651-1666` | hidden |
| Maps | Country unlock | `CountryUnlockSheetViewController.swift:107, 221` | `unlockCountry` |
| Maps | Buy stake pack | `CountryShopViewController.swift:470, 490` | `shop` |
| Wallet | Daily claim | `WalletClaimViewController.swift:414` | `claim` |
| Search | Recent searches | `SearchViewModel.swift:347-449` | open (device) |
| Notifications | Mark all read | `NotificationsViewModel.swift:148-153` | `notifications` |
| Create | "+", long-press camera | `MainTabCoordinator.swift:706-725` | `create` |
