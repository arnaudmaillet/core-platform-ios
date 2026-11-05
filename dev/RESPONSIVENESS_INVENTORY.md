# Responsiveness inventory (#2116): every interaction, from the code

The companion of `dev/RESPONSIVENESS_AUDIT.md`. Every interactive element found by reading the code, with:
- the response it owes within 100 ms;
- its handler, which notes when the handler awaits, hops or hits a repository before the response;
- how to reach it.

What was measured is in the audit's table. A line here with no measurement there is **not measured yet**.

Paths: `F/` is `Packages/Features/`, `C/` is `Packages/Core/`.

## Four timing facts to know before measuring

- **Spinner delay.** Every `PendingFeedback` / `LoaderGate` / `RowBusyAccessory` shows nothing until `LoadingTiming.loaderGrace = 0.25 s` has passed. Skeletons wait `skeletonDelay = 0.15 s`. Defined in `C/DesignSystem/Sources/DesignSystem/Components/Loader/LoadingKit.swift:18-21`. Any action whose only feedback is one of these will show nothing on screen for 250 ms, by design.
- **Guest gate hop.** `MemberGates.perform` runs synchronously for a member. For a guest it does a `Task { await gate.requireMember }` and then presents the sign-in sheet (`C/CoreNavigation/Sources/CoreNavigation/MemberGateProviding.swift:50-61`). That costs one main-actor hop.
- **Routes are synchronous.** All of `RouteResolver.route(to:)` is synchronous (`App/RouteResolver.swift:138-371`). The exceptions:
  - A gated route for a guest goes through `Task` + `await gate.requireMember` (`:165-168`).
  - A route that arrives mid-transition waits for `navigation.whenAtRest` (`:109-113`).
  - `.search` is a cross-dissolve wrapping an unanimated push (`:233-240`).
- **Mock latency.** It is 0 unless you pass `-mock-latency <ms>` or `<min-max>`. `-mock-fail <Service>` forces failures (`SimulatedConditions.swift:74-98`).

## Inventory: one line per element

Columns: area | screen | element | gesture | response | handler (async note) | how to reach

### Shell / tab bar
- shell | ShellTabBarController | Explore / For You / Messages / Profile tab | tap | tab switch | `MainTabCoordinator.swift:693`, sync | any launch
- shell | ShellTabBarController | re-tap selected tab | tap | scroll-to-top (UIKit pops a pushed stack) | `:697-701`, sync | any
- shell | ShellTabBarController | "+" | tap | UIMenu (Camera / Upload / Text) | `:693-719` → `createItem.presentMenu()` `CreateTabItem.swift:122`. Fallback action sheet `:137` | `-open-create-menu` (`MainTabCoordinator+QA.swift:224`)
- shell | ShellTabBarController | "+" menu row Camera/Upload/Text | tap | present full-screen (CaptureViewController / MediaPicker / TextPostComposer) | `openCreate` → `MemberGates.perform(.create)` → `presentCreate` `:811-830`, sync for a member | `-open-create camera\|upload\|text` (`+QA:207`)
- shell | ShellTabBarController | "+" | long press (hold to arm) | disc + ring → present camera | `CreateHoldShortcut.swift:108-127`, `fire` → `createItem.open(.camera)` | `-plus-hold-demo full\|short\|hold\|drift` (`+QA:238`)
- shell | ShellTabBarController | "Sign in" bubble (guest) | tap | present sign-in sheet | `:705-707` → `AppCoordinator.presentSignUp` `AppCoordinator.swift:418-450`, sync | `-guest`
- shell | ShellTabBarController | Profile tab | long press 0.4 s | profile switcher (tracking menu) | `profileOverlayHeld` `:153-169`, sync (switcher data prewarmed by `Task` at `:284`) | `-profile-switcher-hold` (`+QA:28`)
- shell | switcher | "Add Profile" | tap | alert | `presentAddProfilePlaceholder` `:447-455` | same
- shell | NotificationsBell (leading item on every root) | bell | tap | side drawer opens | `NotificationsBell.swift:54` → `NotificationsDrawer.open` `NotificationsDrawer.swift:88` | `-open-notifications`; `-notifications-progress 0.5`; `-notifications-drag-demo` (`+QA:398-423`)
- shell | any root | edge pull from left / "page −1" | swipe | drawer interactive | `SideDrawerContainerViewController`, `DrawerPull` (`ForYouSectorViewController.swift:121`) | `-notifications-drag-demo`
- shell | WalletBadgeInstaller (root headers) | coin/balance badge | tap | present wallet sheet | `WalletBadgeInstaller.swift:71-73`, `:211`, sync | `-open-wallet` (`WalletBadgeInstaller.swift:196`)
- shell | Explore header | magnifier | tap | push Search (cross-dissolve, unanimated) | `ExploreTabCoordinator.swift:52-56` → `.search` | `-open-search` (`+QA:167`)
- shell | Explore header (guest) | "Allow location" | tap | system permission prompt | `ExploreTabCoordinator.swift` `allowLocationItem` → `MapsViewController.allowGuestLocation` `:3767` | `-guest`
- shell | toasts | toast body / Undo / Retry | tap | undo or retry; long message opens the full text | `Feedback` / `ToastView` (DesignSystem) | `-toast-demo kinds\|undo\|stack\|long\|navbar\|pop`

### For You tab: sector (`F/Feed/Sources/Feed/ForYou/ForYouSectorViewController.swift`)
- foryou | ForYouSectorViewController | Feed \| Shots selector (PagedTabBar) | tap / scrub | page switch | `:57`, `:112-133`, sync | default opens on Shots. Any `-foryou-*` arg opens on Feed (`:83-91`)
- foryou | ForYouSectorViewController | pager | horizontal swipe | page switch / drawer past Feed | `HorizontalPagerView`, `:117-124` | `-select-tab 1`

### For You → Feed page (`ForYouViewController.swift`)
- foryou | ForYouViewController | search item | tap | push Search | `:156` → `.search`, sync | `-open-foryou` / `-select-tab 1` + Feed
- foryou | ForYouViewController | Discover grid tile | tap | push / hero → SnapFeedViewController | `page.onItemTapped` `:427` → `openFeed(at:)` `:1303`, sync (`activeTransition` guard) | `-foryou-open N` (`ForYouViewController+QA.swift:34`, `:175`)
- foryou | ForYouViewController | tile comment count | tap | open the feed with comments up | `:430` → `openFeed(showingComments:)` | `-foryou-open-comments N`
- foryou | ForYouViewController | paired half-width card | tap | hero | `openFeed` | `-foryou-open-paired K`
- foryou | ForYouViewController | friend story face | tap | hero feed | `friendsRow.onStoryTapped` `:376` → `openStory` `:2273` (larger face loaded by `Task` at `:2279`, but the open is sync) | `-foryou-open-story N`
- foryou | ForYouViewController | friend face | long press | context menu (View Profile, Unfollow) | `storyMenuElements` `:1144-1159`; `FriendsStoriesRow.swift:397` | (no arg)
- foryou | ForYouViewController | Following shelf card | tap | hero | `shelf.onOpen` `:386` → `presentCard` `:2304` | `-foryou-open-card N`
- foryou | ForYouViewController | shelf card author | tap | push profile | `:394` → `openAuthor` `:608` | –
- foryou | ForYouViewController | Friends row title / shelf "View all" | tap | push ForYouPostListViewController | `:387-388` → `pushList` `:2346` | `-foryou-push-list friends\|following`, then `-foryou-list-open N`
- foryou | ForYouViewController | Discover title / "View all" | tap | push DiscoverGalleryViewController | `:390`, `:500` → `pushDiscoverGallery` `:1272` | `-foryou-view-all`, `-foryou-gallery-open N`
- foryou | ForYouViewController | card author band | tap | push profile | `:440` → `openAuthor` | –
- foryou | ForYouViewController | card "…" / long press | menu (PostCardMenu) | `ForYouGridPage.swift:3972-3996`; `PostAuthorBandView.swift:279` | `-post-menu-audit` (prints)
- foryou | menu | Hide (Not interested) | tap | optimistic hide + undo toast | `hidePost` `:1030`, sync | –
- foryou | menu | Mute author | tap | **non-optimistic:** PendingFeedback (250 ms grace), `await moderation.setPostsMuted`, then hide | `mute` `:1042-1062` | –
- foryou | menu | Block | tap | action sheet, then **non-optimistic** PendingFeedback + `await moderation.block` | `confirmBlock` `:1077`, `block` `:1095-1116` | –
- foryou | menu | Follow | tap | **non-optimistic** PendingFeedback + `await setFollowing` | `follow` `:1120-1137` | –
- foryou | menu | Unfollow | tap | **non-optimistic** PendingFeedback + `await` before rows leave | `unfollow` `:1179-1197` | –
- foryou | menu | Report | tap | ReportReasonSheet, then PendingFeedback + `await reporting.report` | `:1212-1236` | –
- foryou | ForYouViewController | grid | pull-to-refresh | loading state | `page.onRefresh` `:436` | –
- foryou | ForYouViewController | text card | long press | top comments preview | `page.topComments` `:441` | –

### For You → Shots / snap feed (`F/Feed/Sources/Feed/Snap/SnapFeedViewController.swift` unless noted)
Reach with `-select-tab 1` (the default) and `-snap-start-index N` (`LaunchCurtain.swift:70`, `:1124`). `-snap-start-paused` pauses. Pushed variants: `-open-post <id>`, `-open-feed`.

- snap | SnapFeedCell | media | tap | play/pause | `handleBackgroundTap` `SnapFeedCell.swift:2868` → `togglePlayback` `:3108` | –
- snap | SnapFeedCell | media | long press | hold (pause / speed) | `handleMediaHold` `SnapFeedCell.swift:2934` | –
- snap | SnapFeedCollectionView | pager | vertical swipe | next/previous post | collection paging | `-snap-fling [n]`, `-snap-scroll-demo`, `-snap-page-demo`
- snap | SnapChromeView | caption | tap | expand caption | `captionTapped` `SnapChromeView.swift:379` | –
- snap | SnapMediaPageBarView | carousel / scrub bar | tap / drag | page change / seek + scrub preview | `handleScrubGesture` `SnapMediaPageBarView.swift:916` | `-strip-browse`, `-strip-browse-release`
- snap | identity pill (author row in cell, or bar pill) | pill | tap | present ProfileCardViewController (own pill → push own profile) | `cell.onRequestAuthorCard` `:1878-1881`; `pill.onAuthorTapped` `:2288` → `FeedViewModel.didTapAuthorPill` `FeedViewModel.swift:374` → `.profileCard` route `RouteResolver.swift:242-252`, sync | `-open-profile-card <id>`
- snap | identity pill | pill | long press 0.4 s | push profile | `:2294`; `SnapAuthorIdentityView.swift:143` → `didTapAuthor` `FeedViewModel.swift:361` | –
- snap | identity pill | "+" follow | tap | optimistic follow mark (rollback + toast on failure) | `followAuthor` `:2481-2500` → `followStore.follow` | –
- snap | snap feed | leftward swipe | swipe | interactive push of profile | `RouteResolver.destination(for:)` `:424` | `-engage-profile` (`:6555`)
- snap | rail (SnapShortcutRailView boost button) | like / boost | tap | optimistic stake + haptic + confirmation | `SnapShortcutRailView.swift:745-753` → `cell.onRequestBoost` `:1830` → `performBoost` `:3136`, sync | `-wallet-demo-boost`, `-wallet-demo-shot`
- snap | rail | boost button | long press | UIMenu (StakeMenu: amounts, Undo) | deferred menu `SnapShortcutRailView.swift:759-767` → `performBoostUndo` `:3219` | `-wallet-demo-undo`
- snap | SnapWheelCapsule (shortcut wheel) | wheel / return chevron | press-drag / tap | wheel scroll / return to rest | `pressChanged` `SnapWheelCapsule.swift:283`, `returnTapped` `:329` | –
- snap | SnapPostActionsCapsule (column) | save | tap | optimistic bookmark toggle | `SnapPostActionsCapsule.swift:53` → `toggleBookmark` `:2654` | `-save-elsewhere`
- snap | SnapPostActionsCapsule | share | tap | present ShareSheetViewController | `:56` → `presentShareSheet` `:5657-5690`, sync | –
- snap | share sheet | system share | tap | UIActivityViewController | `:5676-5683` | –
- snap | share sheet | send to a person | tap | push draft DM | `:5684` → `.sendLink` route | –
- snap | share sheet | Repost | tap | info toast "coming soon" | `repostRequested` `:5703`, `:5725` | –
- snap | share sheet | Not interested | tap | undo toast | `markNotInterested` `:5739` | –
- snap | share sheet | Report | tap | ReportReasonSheet, then PendingFeedback + `await` | `:5759-5781` | –
- snap | SnapSoundBubble / footer sound item | sound | tap | present SoundSheetViewController | `SnapSoundBubble.swift:147` → `presentSoundSheet` `:5273-5331`, sync (pending tiles filled by `Task` afterwards, `:5345`) | `-snap-sound-sheet [large\|roundtrip\|push]`, `-sound-sheet-open`
- snap | carousel post track | tap / hold | toggle post sound / hold | `togglePostTrack` `:5205`, `holdPostTrack` `:5219` | –
- snap | SnapCommentsPreview / comments pill | tap | present comments sheet (SnapCommentsSheetSession) | `SnapCommentsPreview.swift:185` → `cell.onRequestComments` `:1807` → `presentComments` `:3597` → `presentCommentsSheet` `:3606-3653`, sync (prewarmed) | `-open-comments <postID>`, `-snap-comments-demo`, `-snap-comments-close N`, `-snap-comments-reopen N`
- snap | comments preview | pan / expand | drag | page drive | `:184`, `:186`; `drivePageSwipe` `:4419` | –
- snap | sound return chevron | tap | scroll the comments panel to start | `:1857` | –
- snap | footer like (text page) | tap | optimistic stake | `likeFromFooter` `:3394` | –
- snap | header wallet badge | tap | present wallet sheet | `:2542` → `presentWalletSheet` `:3452` | `-feed-open-wallet`
- snap | side list | edge pull / tap entry | open side list; select an entry | `SnapSideList.swift:507` | `-snap-side-list-open`
- snap | pushed feed | edge swipe / grab | pop / interactive zoom dismiss | `InteractiveSlideDismissal`, `ZoomDismissInteractionController` | `-snap-auto-dismiss`, `-feed-swipe-demo`, `-hero-demo-grab`

### Comments panel / sheet (`PostDetailViewController`, `CommentsInputBar`, `CommentRowView`)
- comments | CommentsInputBar | field | tap | keyboard (guest: Task + await gate → sign-in sheet) | `textViewShouldBeginEditing` `CommentsInputBar.swift:2198-2207` | `-guest -open-comments <id>`
- comments | CommentsInputBar | send | tap | field clears at once; **comment row appears only after `await commentsProvider.addComment`** (not optimistic; composer shows "sending") | `sendTapped` `:1229` → `PostDetailViewController.swift:776` → `PostDetailViewModel.swift:~430-468` | `-composer-draft`
- comments | CommentsInputBar | boost in composer | tap / long press | optimistic stake / menu | `:658-676`; `PostDetailViewController.swift:793-846` | –
- comments | CommentsInputBar | visibility menu | tap | UIMenu | `:680`, `:1270` | –
- comments | CommentsInputBar | avatar (profile switch) | tap | profile switcher | `PostDetailViewController.swift:554-568`. **Armed only after `Task { await profileSwitcher.reload() }`: a tap before that does nothing.** | –
- comments | CommentsInputBar | guest "Sign up to comment" button | tap | Task + await gate → sign-in sheet | `signUpTapped` `:1453-1463` | `-guest`
- comments | CommentRowView | row | long press | context menu (reply / copy / report / delete…) | `CommentRowView.swift:142`, `:361-385`, `:1081` | –
- comments | CommentStream | row | menu | review / copy / select / share / moderation | `CommentStream.swift:1306-1310` | –
- comments | PostDetailViewController | stream | tap | dismiss keyboard / reply state | `handleStreamTap` `:572` | –
- comments | PostDetailViewController | comment like | tap | optimistic | `likeComment` `PostDetailViewModel.swift:1096` | –

### Text and media post pages
- post | SnapFeedViewController (single-post feed) | as Shots | – | – | `.post` route `RouteResolver.swift:286-292` | `-open-post <id>`, `-mock-takedown <id>`
- post | PostDetailViewController | author | tap | push profile | `didTapAuthor` `PostDetailViewModel.swift:420`, sync | –
- post | PostDetailViewController | like | tap | optimistic | `PostDetailViewModel.swift:~395-416` (`Task` after state) | –
- text | TextPostComposerViewController | Cancel | tap | action sheet if a draft exists, else close | `cancelTapped` `TextPostComposerViewController.swift:322-346` | `-open-create text`, `-text-post-type <t>`
- text | TextPostComposerViewController | Drafts | tap | push TextPostDraftsViewController | `:263` → `showDrafts` `:372` | same
- text | TextPostComposerViewController | send (publish) | tap | composer "sending"; **page becomes the published post after `await draft.publish`** (+ `await viewerIdentity` if no author has been shown yet) | `PostDetailViewModel.publish` `:478-498` | `-text-post-send <t>`, `-text-post-comment <t>`
- text | TextPostComposerViewController | who-can-see menu / ⋯ / close / wallet / share | tap | UIMenu / close / sheet / activity | `:286`, `:555`, `:529`, `:611` → `:654`, `:681` | –

### Profile (`F/Profile/Sources/Profile/Views/ProfileViewController.swift`)
Own profile: `-select-tab 3` / `-open-my-profile`. Other: `-open-profile <id>`, `-open-profile-stubbed <id> <handle> <name>`, `-open-profile-delayed <id> [s]`, `-open-unavailable-profile [hidden\|suspended]`.

- profile | ProfileViewController | settings gear (own) | tap | push SettingsViewController | `:1663` → `pushSettings` `:1894` | `-open-settings [section]` (`:882`)
- profile | ProfileViewController | switch-profile item (own) | tap | switcher menu | `:1676-1688` (prewarmed `:1835`) | –
- profile | ProfileHeaderView | Follow | tap | optimistic flip + haptic | `:431-437` → `ProfileViewModel.toggleFollow` `ProfileViewModel.swift:914` (Task after state) | `-profile-follow-tap`
- profile | ProfileHeaderView | Message | tap | push draft thread (guest: gate) | `:438-443` → `messageTapped` `ProfileViewModel.swift:1014` → `.messageUser` | –
- profile | ProfileHeaderView | Edit Profile (own) | tap | push EditProfileViewController | `:444` → `pushEditProfile` `:1248-1257` | `-profile-edit-privacy`
- profile | ProfileHeaderView | QR / share | tap | present ProfileShareViewController | `:450` → `presentShareSheet` `:1461-1488` | `-profile-share-demo [step]`
- profile | ProfileShareViewController | system share / send to a person | tap | activity sheet / push DM | `:1481-1499` | same
- profile | ProfileHeaderView | followers / following counters | tap | push ProfileRelationshipsViewController | `:453` → `pushRelationships` `:1219-1227` | `-profile-relationships [following]`
- profile | ProfileHeaderView | website | tap | open URL | `:447` | –
- profile | ProfileHeaderView | "…" more | tap | UIMenu (deferred) | `configureMoreMenu` `:1413-1446` | `-profile-menu-audit` (prints)
- profile | more menu | Share / Copy link | tap | sheet / toast | `:1461`, `:1501-1509` | –
- profile | more menu | map rails toggle | tap | optimistic + `Task` write | `toggleMapCategory` `ProfileViewModel.swift:847` | `-profile-map-pin-demo`
- profile | more menu | Report | tap | ReportReasonSheet, then `Task` await → toast | `:1576`; `ProfileViewModel.swift:1215` | –
- profile | more menu | Restrict | tap | optimistic + undo | `toggleRestrict` `ProfileViewModel.swift:1153` | –
- profile | more menu | **Block** | tap | action sheet, then **non-optimistic with NO pending UI**: `await repository.setBlocked` / `blockAccount`, then toast + pop | `confirmBlock` `:1511-1529` → `ProfileViewModel.block` `:1038-1070` | `-profile-block-demo [account]`
- profile | more menu | **Unblock** | tap | **no pending UI**: `await setBlocked(false)`, then toast | `ProfileViewModel.unblock` `:1076-1092` | –
- profile | more menu | Clear history (own) | tap | action sheet → clear | `:1448-1459` | –
- profile | mute bell / mute menu | tap / menu | mute with undo (optimistic); unmute: Task + await → toast | `makeMuteMenu` `:1294`; `toggleMute` `ProfileViewModel.swift:1098-1150` | –
- profile | band (gallery selector Posts/Saved/Liked) | tap / swipe | page switch | `heroPager`, `galleryPager.onPageSettled` `:522`; selector binding `:1739` | `-profile-tab posts\|saved\|liked`
- profile | gallery tile | tap | hero / push snap feed | `:499` → `openGalleryPost` | `-profile-open-post <i>`
- profile | gallery tile comments / author | tap | open with comments / push profile | `:503`, `:506` | –
- profile | gallery "View all" | tap | push ProfileMediaGalleryViewController | `:509` → `pushMediaGallery` `:2740` | `-profile-view-all [s]`
- profile | gallery tile "…" | menu | Delete (undo) / Report | `galleryMenuActions` `:1531-1550` | `-post-menu-audit`
- profile | page | pull-to-refresh | loading | – | `-profile-stretch-sweep`

### Profile card (sheet from the identity pill) (`ProfileCardViewController.swift`)
- card | ProfileCardViewController | close / View Profile / Message / Follow | tap | dismiss / push profile / push DM / optimistic follow | `:210`, `:540`, `:546` → `messageTapped` `:679`, `followTapped` `:671` | `-open-profile-card <id>`
- card | ProfileCardViewController | counters | tap | push relationships on the same stack | `openRelationships` `:695` | same
- card | ProfileCardViewController | share / ⋯ menu / block / report / info | tap | sheet / menu / alert | `:531`, `:591-604`, `confirmBlock` `:753`, `:745`, `infoTapped` `:690` | same

### Relationship lists
- rel | ProfileRelationshipsViewController | Followers/Following tabs | tap / scrub / swipe | page switch | `tabBar.onScrub` `ProfileRelationshipsViewController.swift:177-199` | `-profile-relationships`, `-profile-relationships-tab N`
- rel | ProfileRelationshipListViewController | row | tap | push profile | `didSelectItemAt` `ProfileRelationshipListViewController.swift:379` → `rowTapped` (sync route) | `-profile-relationships-open-self`
- rel | ProfileRelationshipListViewController | Follow / Following pill | tap | optimistic | `cell.onAction` `:116-128` → `ProfileRelationshipsViewModel.toggleFollow` (state, then Task) | `-profile-relationships-action`
- rel | ProfileRelationshipsViewController | search | tap / type / cancel | search UI | – | `-profile-relationships-search-open`, `-profile-relationships-search <q>`, `-…-search-clear`, `-…-search-cancel`, `-profile-relationships-pop`

### Edit Profile (`EditProfileViewController.swift`)
- edit | EditProfileViewController | field row (name / username / bio / website / links) | tap | push EditFieldViewController / EditLinksViewController | `didSelectItemAt` `:580` → `edit` `:442-446`, `push` `:539` | `-profile-edit-privacy`
- edit | EditFieldViewController | Save | tap | pop at once; write in `Task` | `saveTapped` `EditFieldViewController.swift:222-226` | –
- edit | EditProfileViewController | Privacy / Account type rows | tap | push | `:584-586` | `-profile-edit-privacy`
- edit | EditProfileViewController | Change photo | tap | alert | `changePhotoTapped` `:545` | –
- edit | EditProfileViewController | Video banner | tap | action sheet; Buy → `Task { await buyVideoBanner }` with PendingFeedback (250 ms) | `openVideoBanner` `:593-620` | –

### Settings / account settings (`F/Profile/Sources/Profile/Views/Settings/`)
- settings | SettingsViewController | section row | tap | push section VC (or ComingSoon) | `didSelectItemAt` `SettingsViewController.swift:345-357` → `open` `:308-313`, sync | `-open-settings [account\|security\|privacy\|…]`
- settings | SettingsViewController | Log out | tap | action sheet → `onLogout` (Task: push signOut + logout) | `confirmLogout` `:315-332`; `AppCoordinator.swift:345-352` | –
- settings | SettingsViewController | Switch profile row | tap | switcher menu | `presentSwitcher` `:302` | –
- settings | SettingsViewController (guest) | Sign in row | tap | sign-in sheet | `:353` | `-guest -select-tab 3`
- settings | PrivacySectionViewController | Private account switch | toggle | **not optimistic:** switch + row loader (RowBusyAccessory, 250 ms grace) until the server answers | `setPrivate` `PrivacySectionViewController.swift:~494`; `didSelectItemAt` `:509` | `-open-settings privacy`
- settings | PrivacySectionViewController | Follow requests / Hide lists / Activity / Location / Data transparency | tap | push | `:509-536` | same
- settings | other toggle screens (Notification, Location, Activity, HiddenWords, LimitInteractions, WhatYouSee, Supervision…) | toggles | same busy-row pattern (RowBusyAccessory / PendingFeedback) | the respective `*ViewController.swift` | `-open-settings <section>`; `-supervision-open`
- settings | AccountSettings / Deactivate | tap | **StepUpPrompt `.signInAgain`: `await stepUp.sendReconfirmationCode()` BEFORE the code alert is presented, with no loading UI** | `AccountSettingsViewController.swift:486` → `StepUpPrompt.swift:48-60` | `-open-settings account`
- settings | TwoStepViewController | Turn on / Recover | tap | same `.signInAgain` await-before-present | `TwoStepViewController.swift:237`, `:632` | `-open-settings security`, then Two-Step
- settings | TwoStepViewController | New backup codes | tap | `.code` alert (sync); then `isWorking` + `await regenerateBackupCodes` → setViewControllers | `:302`, `:313-325`, `:357-367` | same
- settings | ChangeContactViewController | confirm | tap | `.signInAgain` await-before-present | `ChangeContactViewController.swift:309` | –
- settings | DeleteAccountViewController | Delete | tap | alert → `verifyThenRequestDeletion` → `.signInAgain` await-before-present | `DeleteAccountViewController.swift:349` | `-open-settings account`
- settings | PasskeysViewController | remove / add | tap | `presentPreferringPasskey`: `Task { await passkeyStepUpRequest; await assertPasskey … }` (system sheet) | `PasskeysViewController.swift:237`; `StepUpPrompt.swift:85-95` | –
- settings | Security / Delete / list screens | retry / "taking longer" rows | tap | `Task { await viewModel.load() }` | e.g. `SecuritySettingsViewController.swift:573-590` | –
- settings | StorageSettingsViewController | Clear | tap | sheet → clear | `:258-266` | `-storage-clear-all`

### Messages (`F/Chat/Sources/Chat/…`)
Reach with `-select-tab 2` or `-open-messages [all\|requests\|suggestions]`.

- msg | MessagesInboxViewController | category bar All / Requests / Suggestions | tap / scrub / swipe | page switch (instant) | `Inbox/MessagesInboxViewController.swift:200-224` | `-inbox-page-to <cat>`
- msg | MessagesInboxViewController | search field | tap | UISearchController active. Keyboard comes one hop later (`DispatchQueue.main.async becomeFirstResponder`). | `:557-560` | `-inbox-search-open`, `-inbox-search-query <t>`, `-inbox-search-cancel`
- msg | InboxSearchResultsViewController | result row | tap | push thread / draft | `didSelectItemAt` `InboxSearchResultsViewController.swift:372` → `InboxSearchViewModel.didSelect` `:309` | same
- msg | ConversationListViewController | row | tap | push ConversationThreadViewController | `didSelectRowAt` `ConversationListViewController.swift:573` → `viewModel.didSelect` `ConversationListViewModel.swift:119` (sync route) | `-open-conversation <id>`, `-open-conversation-settled <id>`
- msg | ConversationListViewController | row | long press | context menu with thread preview (Pin / Mute / Delete); preview tap → push | `:584-628` | `-chat-preview-demo`
- msg | ConversationListViewController | Pin / Delete | tap | optimistic (catalog emit) | `pin` `:253`; `InboxCatalog.togglePin` `:480`, `delete` `:540` | `-chat-pin-demo`
- msg | ConversationListViewController | Mute | tap | optimistic catalog + toast after the server answers | `ConversationListViewModel.toggleMute` `:137` | –
- msg | ConversationListViewController | section header pill | tap | scroll / filter | `header?.onTap` `:540` | `-inbox-tap-section new\|recent`
- msg | ConversationListViewController | pull-to-refresh | loading | `:164` | –
- msg | MessageRequestsViewController | Accept / Dismiss / long press / hidden-requests row | tap | optimistic / menu / push | `:257-258`, `:505-540`, `openHiddenRequests` `:209` | `-open-messages requests`
- msg | SuggestionsViewController | Follow / dismiss / row / long press | tap | optimistic / push profile / menu | `:135-136`, `:275` → `SuggestionsViewModel.didSelect` `:274`, `:285-308` | `-open-messages suggestions`
- msg | compose / new message | – | **no compose button exists in the inbox** (no `square.and.pencil` / compose item). New message is reached only via `.messageUser` (profile Message, map sub-filter "Send message"). | – | `-message-user <profileID>`, `-new-message-page-size`

### Thread / composer (`F/Feed/Sources/Feed/Conversation/ConversationThreadViewController.swift`)
- thread | ConversationThreadViewController | send | tap | optimistic pending bubble | `composeBar.onSend` `:731` → `ConversationViewModel.send` (emit, then Task) | `-open-conversation <id>`
- thread | ConversationThreadViewController | camera / library | tap | present picker | `:810-818` → `ConversationThreadDriver.pickMedia` `:175-185`, sync | same
- thread | ConversationThreadViewController | media bubble | tap | present ThreadMediaViewer (failed one: retry) | `tapMedia` `:822-836` | same
- thread | ConversationThreadViewController | message | long press | context menu (Reply / Copy / Select / Forward / Delete); Delete → action sheet after the menu leaves | `:1527-1548`, `confirmDelete` `:1559-1572` | same
- thread | ConversationThreadViewController | peer pill / "+" / ⋯ View Profile | tap | profile card or push / follow / push | `:857-858`, `:792-796` | same
- thread | ConversationThreadViewController | mute bell / menu | tap | **bell is held in its old look until the server confirms, then toast** (non-optimistic) | `:913-947`, `setMuted` `:972` → `driver.setMuted` `ConversationThreadDriver.swift:133` | same
- thread | ConversationThreadViewController | rail pin / hold | tap / hold | toggle pin (optimistic) | `:746-750`, `:106` | same
- thread | ConversationThreadViewController | day header / quote / retry | tap | scroll / scroll / retry | `:507`, `:1385`, `:1398` | same
- thread | voice | hold record / play / seek / speed | hold / tap | recording UI / playback | `:2186-2192`, `:2319-2324`; `VoiceHoldGesture.swift` | `-voice-messages`
- thread | sticker strip / emote panel | composer emote button | tap | emote keyboard | `CommentsInputBar` / `EmoteKit` `EmotePickerView` | `-emote-keyboard-qa`, `-composer-keyboard-qa`

### Map / Explore (`F/Maps/Sources/Maps/MapsViewController.swift`)
Reach with `-select-tab 0`, plus `-maps-wide-region`, `-maps-tight-region`, `-maps-set-region lat,lng,span`.

- map | MapsViewController | pin | tap (instant, on MapAnnotationView.onSelect) | hero present / plain push of the snap feed (text pins slide) | `:2725-2730` → `openAnnotation` `:2969-3071`, sync. Touch-down warms playback (`beginPlaybackWarm` `:2798`). | `-maps-open-first-pin`, `-maps-open-first-text-pin`, `-maps-open-post <id>`, `-maps-open-delay <ms>`
- map | MapsViewController | cluster | tap | hero / push cluster feed + place page beneath | `:2703-2706` → `openAnnotation` | `-maps-open-first-cluster`, `-maps-open-first-media-cluster`, `-maps-open-first-text-cluster`, `-maps-open-hierarchy-cluster`
- map | MapsViewController | locked-country marker / country | tap | present CountryUnlockSheet (offer) | `countryLayer.onLockedCountryTapped` `:855` → `offer`; `:1021` | `-maps-offer-country <CC>`, `-offer-country`, `-show-country`
- map | CountryUnlockSheetViewController | Unlock | tap | busy control, then `await access.unlock` → close (inside a `Task`, one hop) | `unlockTapped` `CountryUnlockSheetViewController.swift:282-292`, `unlock` `:307-332` | same
- map | MapsViewController | filter pills (primary) | tap | pill selected (sync); pins re-query | `filterBar.onFilterChanged` `:1370` → `updateSubFilterBar` `:1464` (cached row first, then Task refresh) | `-maps-select-filter <tok>`, `-maps-select-filter-2`
- map | sub-filter row | pill | tap | toggle sub-filter | `:1375` | `-maps-tap-subfilter <id>`, `-maps-select-subfilter`, `-maps-toggle-subfilter`
- map | sub-filter row | pill | long press | context menu (View profile / Message / Mute / Details / Share / Unpin) | `:1383-1405` → `openProfile` `:1628`, share `:1670` | `-maps-subfilter-menu-open <id>`, `-maps-subfilter-remove <id>`
- map | sub-filter row | "+" expand | tap | present MapSubFilterSheetViewController | `presentSubFilterSheet` `:1593-1621` | `-maps-open-subfilter-sheet`
- map | filter bar | place entry | tap | fly camera | `filterBar.onPlaceTapped` `:778` | –
- map | MapLocationControlsView | location button | tap | permission request / recentre (LoaderGate inside) | `locationControlTapped` (via `:1365`) | –
- map | profile button (people pins / favourites "View profile") | tap | push profile | `openProfile` `:1628` | `-maps-pin-favorite`
- map | country shop | open | push CountryShopViewController | `presentCountryShop` `:875-889` | `-open-country-shop`
- place | PlaceProfileViewController | tile / comments | tap | open feed | `PlaceProfileViewController.swift:769`, `:788` | `-open-place <CC>`, `-maps-open-place`, `-maps-open-place-id <id>`, `-maps-place-open-tile <i>`
- place | PlaceProfileViewController | star (follow place) | tap | optimistic | `starTapped` `:1711-1716` | same
- place | PlaceProfileViewController | dock pin | tap | optimistic + toast | `dockPinTapped` `:1092-1101` | same
- place | PlaceProfileViewController | QR / share / wallet / "View all" / popular list | tap | sheet / push | `:1076` → `:1131-1139`, `:1665`, `:819-822` | same
- place | PlaceProfileViewController | pull / down-grab | drag | refresh / dismiss to marker | – | `-place-pull-refresh`, `-place-grab-demo`, `-maps-place-pop-demo`, `-maps-place-tile-dismiss[-vertical]`

### Search / Explore (`F/Search/Sources/Search/…`)
Reach with `-open-search` (and optionally `-select-tab N`).

- search | SearchViewController | field typing | type | suggestions | `searchTextChanged` `SearchViewController.swift:679` | `-search-query <t>`
- search | SearchViewController | return / submit | key | push SearchResultsViewController (sync); results load async (`.loading` phase) | `textFieldShouldReturn` `:1195` → `submitCurrentQuery` `:557` → `showResults` `:594`; `SearchViewModel.submitQuery` `:491` | `-search-submit`, `-search-sort`, `-search-scope`
- search | SearchViewController | Cancel | tap | pop | `:500` → `cancelSearch` `:504` | `-search-refine-cycle`
- search | SearchViewController | recent / suggestion / creator row | tap | push hashtag / profile, or submit | `didSelectItemAt` `:1162-1175` → `didSelectRow` `SearchViewModel.swift:533`, `didSelectCreator` `:774` | –
- search | SearchResultsViewController | query field | tap | cut-push refine screen | `results.onEditQuery` `SearchViewController.swift:615-626` | `-search-tap-query`
- search | SearchResultsViewController | People / Posts tabs | tap / swipe | page | `:563-570` | `-search-results-tab 0\|1`
- search | SearchResultsViewController | filters | tap | present SearchFilterSheetViewController | `presentFilters` `:879-883` | `-search-filters-open`
- search | SearchPeoplePage | row | tap | push profile | `:534` → `didSelectResult` `SearchViewModel.swift:638` | `-search-tap-user <i>`
- search | PostSetSurfaceViewController | tile / lead card | tap | open feed | `PostSetSurfaceViewController.swift:541`, `:577` | `-search-open-post <i>`, `-search-open-card <i>`
- search | HashtagViewController | recent title / retry | tap | push list / `Task` refresh | `HashtagViewController.swift:110-139` | `-open-hashtag <tag>`

### Create (`F/Upload/Sources/Upload/…`)
- create | CaptureViewController | shutter | tap | photo: busy look + flash immediately, then `await capturePhoto`, then **push editor** (loading state first, push after await) | `shutterTapped` `Capture/CaptureViewController.swift:963` → `takePhoto` `:1152-1170` → `openEditor` `:1216-1221` | `-open-create camera`, `-camera-simulated`, `-camera-script`
- create | CaptureViewController | shutter | hold | record (optimistic UI) | `holdBegan` `:983`; `startRecording` `:1225` | same
- create | CaptureViewController | Next (after clips) | tap | busy shutter, then **`await CaptureStitcher.stitch` + duration + size, then push editor** | `nextTapped` `:1318-1355` | same
- create | CaptureViewController | flip / flash / undo / close / library / preview tap / double tap / pinch | tap / pinch | rotate / cycle / undo / discard sheet / push picker / focus / flip / zoom | `:158` → `flip` `:1744` (`Task` `source.flip`, after the visual turn), `:179`/`:207`, `:102`/`:1301`, `:1482`/`:406`, `:603`/`openLibrary` `:1785`, `:1644`, `:1730`, `:1632` | same
- create | MediaPickerViewController | tile / album tabs / Next / Drafts / Cancel | tap | select / switch album / push editor / push drafts / close | `goNext` `Views/MediaPickerViewController.swift:398-407`, `:132`/`:396`, `:374` | `-open-create upload`, `-upload-fake-library`, `-upload-album <i>`, `-upload-pick 0,2`, `-upload-edit`, `-upload-edit-return`
- create | MediaEditorViewController | Next / undo / redo / category strip / tools / crop | tap | push NewPostViewController / step / mode change / crop | `goNext` `Views/MediaEditorViewController.swift:2503`, `:392`, `:402`, `:1347`, `enterCrop` `:3183`, `mediaTapped` `:3097` | `-upload-edit`, `-upload-category <i>`, `-open-transitions`, `-upload-seed-cuts N`
- create | MediaEditor stickers / effects | tap | present sticker picker | `MediaEditorViewController+Host.swift:197`; `Editor/MediaEditorEffectsMode.swift:227` | –
- create | NewPostViewController | Post | tap | progress shown at once (0.02), list frozen; export/upload awaited; dismiss on success | `postItem` `Views/NewPostViewController.swift:259` → `post` `:1219-1260` | `-upload-post`, `-upload-publish`, `-mock-upload-fail 0.5`
- create | NewPostViewController | Save to Photos switch | toggle | on at once; `await requestAccess`, refusal → back off + alert | `confirmLibraryAccess` `:1434-1445` | `-upload-save-to-photos`
- create | NewPostViewController | comments menu / clip tile / keyboard dismiss | tap | UIMenu / sheet / dismiss | `:1181`, `clipTileTapped` `:895`, `:817` | –
- create | "Use this sound" (sound sheet) | tap | gate → close sheet → present camera with soundtrack. `MainTabCoordinator.openCamera` silently returns unless `previewURL.isFileURL`. | `SoundSheetViewController.swift:2222-2228` → `MainTabCoordinator.swift:801-808` | `-snap-sound-sheet`

### Sound sheet (`F/Feed/Sources/Feed/Snap/Sound/SoundSheetViewController.swift`)
- sound | SoundSheetViewController | record / play preview | tap | plays at once if a player exists; otherwise `Task { await pool.playableURL }` before the player starts (header shows loading) | `recordTapped` `:628`, `togglePreview` `:1674-1717` | `-snap-sound-sheet`, `-sound-sheet-open`
- sound | SoundSheetViewController | close / share / bookmark / Use | tap | dismiss / activity / optimistic save / camera | `:721`, `:760` → `:2231-2239`, `:767` → `toggleSaved` `:796` | same
- sound | SoundSheetViewController | tile | tap / long press | open the post over the sheet / context menu | `:1963`, `:2358-2385` | `-sound-sheet-open`
- sound | SoundSheetViewController | gallery | tap | push SoundSheetGalleryViewController | `:1592` | –

### Notifications (`F/Notifications/Sources/Notifications/Views/`)
- notif | NotificationsViewController | row | tap | route to post / profile / supervision; the drawer closes | `didSelectItemAt` `NotificationsViewController.swift:556` → `NotificationsViewModel.swift:~320-335` | `-open-notifications`
- notif | NotificationsViewController | clear (trash) | tap | optimistic clear + undo toast | `:102` → `clearTapped` `:182` | same
- notif | NotificationsViewController | mute / mute menu | tap / menu | **bar keeps its old look with a busy loader; `await muteModel.set`, then toast reveals the new look** | `NotificationsViewController+Mute.swift:99-160` | same
- notif | NotificationsViewController | "Show more" / section selector | tap | paging / scroll | `:54` | `-notifications-show-more`

### Wallet / shop / gems (`App/Shell/Wallet*`, `F/Maps/Sources/Maps/Countries/`)
- wallet | WalletSheetViewController | close / How it works / Stakes / Activity / Shop | tap | dismiss / push / push / push / push storefront over root | `App/Shell/WalletSheetViewController.swift:536`, `:544` → `:563`, `:571`, `:579`, `:585-596` | `-open-wallet`, `-wallet-open-stakes active\|settled`, `-wallet-open-activity`, `-wallet-open-shop`, `-wallet-sheet-large`, `-wallet-sheet-scroll`
- wallet | WalletSheetViewController | Claim | tap | pending state at once (`pendingKey` + `changed()`), then `await wallet.claim`, then toast / alert | `claim` `:598` → `WalletClaimer.swift:30-83` | `-wallet-demo-claim`, `-wallet-claim-ready`
- wallet | WalletStakesViewController | segment / stake row / retry | tap | reload (Task) / hero open | `:97`, `openFeed` `:390` | `-wallet-open-stake <n>`
- shop | ShopStorefrontViewController / CountryShopViewController | country / "See all" / pack buy (confirmation menu) | tap | unlock sheet / push list / PendingFeedback (250 ms) + `await buyPack` | `ShopStorefrontViewController.swift:524-534`; `CountryShopViewController.swift:518-527`; `ShopPurchaseFeedback.swift:14` | `-open-country-shop`, `-wallet-gems N`, `-wallet-balance N`

### Guest-mode surfaces (`-guest`; `-guest-sign-in-after <s>`, `-guest-sign-out-after <s>`)
- guest | tab bar | "Sign in" bubble | tap | sign-in sheet | see Shell
- guest | GuestSignInViewController (Messages root, when reached by route) | Sign in | tap | sign-in sheet | `App/Shell/GuestSignInViewController.swift:38`
- guest | any gated control (like, follow, save, comment field, message, create, use sound, follow place, unlock country) | tap | Task hop, then sign-in sheet | `MemberGates.perform` `MemberGateProviding.swift:59`; `AppCoordinator.presentSignUp` `:418-450`
- guest | Auth MethodSelection / Phone / Email → Continue | tap | `setWorking(true)` (spinner on button), then **`await startVerification`, then push / present the OTP step** | `F/Auth/Sources/Auth/LoginFlowCoordinator.swift:177-197` → `showCode` `:200` → `push` `:540-560` | `-guest`, `-login-demo-phone`, `-login-demo-signup`
- guest | OTP verify | entry | `setWorking`, then **`await signIn`, then push birthday / second step, or `await profileSetup.hasProfile`** | `:239-262`, `:348-356` | `-mock-two-step`
- guest | sign-up consent → Create | tap | `setWorking`, then **`await signUp.signUp`, then push profile setup** | `:426-457`
- guest | Apple / passkey | tap | Task + system sheet | `:277-330` | `-mock-apple-sign-in <email>`

## 2. Push / present preceded by an `await`, or wrapped in `Task { … await … ; push/present }`

These are the prime suspects. Most UI routes and pushes are synchronous by explicit design (`RouteResolver.swift:209-214`, `:360-363`; `SnapFeedViewController.swift:5337-5341`). These are the exceptions:

- `F/Upload/Sources/Upload/Capture/CaptureViewController.swift:1318-1351` — Next: `await CaptureStitcher.stitch` + `duration` + `uprightVideoSize`, then `openEditor` (push). Busy shutter shows first.
- `CaptureViewController.swift:1152-1167` → `:1182-1193` — shutter photo: `await source.capturePhoto`, then push the editor. Flash and busy look first.
- `F/Auth/Sources/Auth/LoginFlowCoordinator.swift:177-197` — Continue (email/phone): `await startVerification`, then `showCode` → push/present the OTP form. `setWorking` first.
- `LoginFlowCoordinator.swift:239-262` — verify code: `await signIn`, then push second-step / birthday steps.
- `LoginFlowCoordinator.swift:348-356` — finishing sign-in: `await profileSetup.hasProfile`, then push profile setup.
- `LoginFlowCoordinator.swift:426-457` — create account: `await homeCountry()` + `await signUp.signUp`, then push profile setup.
- `LoginFlowCoordinator.swift:277-330` — Apple / passkey: `await` the system sheet + server, then push.
- `F/Profile/Sources/Profile/Views/Settings/StepUpPrompt.swift:48-60` — `.signInAgain` (the default): `Task { await sendReconfirmationCode(); askForSentCode → present alert }` **with no loading UI**. Reached from Deactivate (`AccountSettingsViewController.swift:486`), Two-step on (`TwoStepViewController.swift:237`), Recover (`:632`), Change contact (`ChangeContactViewController.swift:309`), Delete account (`DeleteAccountViewController.swift:349`).
- `StepUpPrompt.swift:85-95` (`presentPreferringPasskey`, `PasskeysViewController.swift:237`) — passkey request + assertion awaited; the fallback alert is presented after.
- `F/Profile/Sources/Profile/Views/Settings/PasskeyOffer.swift:45-65`, `:76-89` — post-sign-in offer: alert / StepUp presented after awaits. Not a tap.
- `F/Profile/Sources/Profile/Views/Settings/TwoStepViewController.swift:313-325` → `:357-367` — regenerate codes: `await regenerateBackupCodes`, then `setViewControllers` (push codes list).
- `App/RouteResolver.swift:165-168` — gated route for a guest: `await gate.requireMember`, then re-route. For a member it is sync.
- `C/CoreNavigation/Sources/CoreNavigation/MemberGateProviding.swift:59-60` — guest-gated taps: `Task { await requireMember }`, then body (presents the sheet).
- `F/Feed/Sources/Feed/Comments/CommentsInputBar.swift:1458-1462`, `:2202-2205` — guest comment field / sign-up: Task + await gate, then focus.
- `F/Feed/Sources/Feed/PostDetail/PostDetailViewController.swift:554-568` — composer avatar switcher is armed only after `await profileSwitcher.reload()`. A tap before that gets no response.
- `F/Profile/Sources/Profile/Views/Settings/SettingsViewController.swift:276-280` — switch-profile row data: `await accountProfiles()` / `activeProfileID()` / `switcher.reload()` before the row is configured.
- `F/Maps/Sources/Maps/Countries/CountryUnlockSheetViewController.swift:289-291` → `:307-324` — Unlock: `Task { await unlock() }`, busy control, `await access.unlock`, then `closePresentation`.
- `App/Shell/WalletClaimer.swift:42-81` — Claim: `await wallet.claim`, then toast or Retry alert. Pending state set before the Task.
- `F/Upload/Sources/Upload/Views/NewPostViewController.swift:1239-1372` — Post: export/upload awaited; progress bar first; failure alerts after.
- `NewPostViewController.swift:1435-1443` — Save to Photos: `await requestAccess`, then refusal alert.
- `F/Feed/Sources/Feed/PostDetail/PostDetailViewModel.swift:~445-468` (comment send) and `:478-498` (text publish) — the visible result (row / published page) comes only after the awaits.
- `F/Feed/Sources/Feed/Snap/Sound/SoundSheetViewController.swift:1698-1716` — preview with an unresolved URL: `await pool.playableURL`, then the player starts.
- Non-optimistic writes with **no** immediate visible change other than a 250 ms-grace spinner or toast:
  - `ProfileViewModel.block` (`ProfileViewModel.swift:1038`) / `unblock` (`:1076`) — **no pending UI at all**.
  - For You menu Mute / Block / Follow / Unfollow / Report (`ForYouViewController.swift:1042-1236`) — PendingFeedback.
  - Snap Report (`SnapFeedViewController.swift:5767`).
  - Thread mute bell (`ConversationThreadViewController.swift:972`) — held until the server confirms.
  - Notifications mute (`NotificationsViewController+Mute.swift:147-170`).
  - Settings switches (Privacy `setPrivate`, etc.) — RowBusyAccessory.
  - Edit Profile video banner buy (`EditProfileViewController.swift:610-625`).
  - Shop pack buy (`CountryShopViewController.swift:518-527`).
- `DispatchQueue.main.async` hops before present / keyboard:
  - `MessagesInboxViewController.swift:560` — search keyboard one hop after activation.
  - `ConversationListViewController.swift:227-230` — DEBUG `-chat-preview-demo` only.
- DEBUG-only `Task`s with a sleep before present (not user paths): `AppCoordinator.swift:381-408` (catalogs).

These were not flagged: every tab switch, push, route, hero flight, comments sheet, sound sheet, share sheet, wallet sheet, profile card, Search, and the like / follow / save / pin / accept toggles. All are synchronous or optimistic in the tap's own turn.
