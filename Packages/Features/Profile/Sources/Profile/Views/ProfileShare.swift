import ShareSheet

// The profile's share sheet is the shared `ShareSheet` package's since
// 5 October 2026 — the place page's QR bubble opens the same one. The old
// names stay as aliases, so the profile's call sites and tests read as before.
typealias ProfileShareViewController = ShareSheetViewController
typealias ProfileQRCardView = ShareQRCardView
typealias ProfileShareCard = ShareCardImage
typealias ProfileShareItemSource = ShareItemSource
