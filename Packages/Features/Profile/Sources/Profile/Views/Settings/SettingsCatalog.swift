import Foundation

/// Who a settings section applies to. One account owns several profiles, so
/// the root list says it on screen: a viewer who switches profile must know
/// which toggles follow them and which stay behind.
enum SettingsScope: Int, CaseIterable, Sendable {
    /// Follows the login: every profile on the account shares it.
    case account
    /// Belongs to the active profile only; switching profile switches it.
    case profile
    /// This install and the legal pages — neither account nor profile.
    case app
}

/// The thirteen sections of Settings, in on-screen order, grouped by scope.
///
/// The tree is the one in `dev/ACCOUNT_SETTINGS_GAP_REPORT.md` (*Target
/// structure*). A section with no live row yet still appears: its child is an
/// honest "coming soon" page naming what will live there, so the shape of the
/// finished screen is visible and every later slice has a home (#381, epic
/// #420).
enum SettingsSection: String, CaseIterable, Sendable {
    // Account-wide
    case account
    case security
    case familyAndTeens
    case wallet
    case adsAndData
    // Per profile
    case privacy
    case safety
    case notifications
    case whatYouSee
    case activity
    // This device and legal
    case appPreferences
    case help
    case legal

    var scope: SettingsScope {
        switch self {
        case .account, .security, .familyAndTeens, .wallet, .adsAndData: .account
        case .privacy, .safety, .notifications, .whatYouSee, .activity: .profile
        case .appPreferences, .help, .legal: .app
        }
    }

    var title: String {
        switch self {
        case .account: "Account"
        case .security: "Security and Login"
        case .familyAndTeens: "Family and Teens"
        case .wallet: "Wallet and Purchases"
        case .adsAndData: "Ads and Data"
        case .privacy: "Privacy"
        case .safety: "Safety and Interactions"
        case .notifications: "Notifications"
        case .whatYouSee: "What You See"
        case .activity: "Your Activity"
        case .appPreferences: "App Preferences"
        case .help: "Help and Support"
        case .legal: "Legal and About"
        }
    }

    /// SF Symbol for the root row.
    var symbolName: String {
        switch self {
        case .account: "person.crop.circle"
        case .security: "lock.shield"
        case .familyAndTeens: "figure.2.and.child.holdinghands"
        case .wallet: "creditcard"
        case .adsAndData: "chart.bar.doc.horizontal"
        case .privacy: "hand.raised"
        case .safety: "exclamationmark.shield"
        case .notifications: "bell.badge"
        case .whatYouSee: "eye"
        case .activity: "clock.arrow.circlepath"
        case .appPreferences: "slider.horizontal.3"
        case .help: "questionmark.circle"
        case .legal: "doc.text"
        }
    }

    /// What the section will hold, shown on its "coming soon" page until the
    /// rows exist. Plain words, no promises of dates.
    var plannedItems: [String] {
        switch self {
        case .account: ["Email, phone and password", "Date of birth and profiles", "Deactivate, delete or download your data"]
        case .security: ["Change password", "Two-factor authentication and backup codes", "Where you're logged in"]
        case .familyAndTeens: ["Teen protections", "Quiet hours", "Parental supervision"]
        case .wallet: ["Balance and transaction history", "Restore purchases", "Spending limits"]
        case .adsAndData: ["Personalised ads", "Consents", "Why you see an ad"]
        case .privacy: ["Private account and follow requests", "Who can comment and message you", "Location sharing"]
        case .safety: ["Blocked and muted accounts", "Hidden words", "Your reports and account status"]
        case .notifications: ["Push notifications by category", "Email notifications", "Pause and quiet hours"]
        case .whatYouSee: ["Sensitive content", "Reset For You", "Chronological feed"]
        case .activity: ["Recently deleted", "Likes and history", "Time limits and breaks"]
        case .appPreferences: ["Autoplay and data saver", "Captions and comment ticker", "Language and cache"]
        case .help: ["Help Center", "Contact support", "Report a problem"]
        case .legal: ["Terms of Service and Privacy Policy", "Community Guidelines", "Legal notice and licences"]
        }
    }

    /// The sections of one scope, in on-screen order.
    static func sections(in scope: SettingsScope) -> [SettingsSection] {
        allCases.filter { $0.scope == scope }
    }
}
