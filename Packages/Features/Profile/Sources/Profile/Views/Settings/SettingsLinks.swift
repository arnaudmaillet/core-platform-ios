import Foundation

/// Every web page Settings links to, in one place (#391).
///
/// ⚠️ **PROVISIONAL.** None of these pages exist yet, so every URL is nil and
/// its row says "Coming Soon" instead of opening a page that is not there.
/// Filling a URL here is the whole change when a page goes live — tracked in
/// #424 (Terms, Privacy Policy, Community Guidelines, legal notice, Help
/// Center, contact, copyright form, cookie and SDK policy).
public struct SettingsLinks: Equatable, Sendable {
    public var helpCenter: URL?
    /// The DSA Art. 12 single point of contact — a page or a `mailto:`.
    public var contactSupport: URL?
    public var reportProblem: URL?
    public var termsOfService: URL?
    public var privacyPolicy: URL?
    public var communityGuidelines: URL?
    /// Mentions légales / Impressum (LCEN in France).
    public var legalNotice: URL?
    public var copyrightReport: URL?
    public var cookiePolicy: URL?

    public init(
        helpCenter: URL? = nil,
        contactSupport: URL? = nil,
        reportProblem: URL? = nil,
        termsOfService: URL? = nil,
        privacyPolicy: URL? = nil,
        communityGuidelines: URL? = nil,
        legalNotice: URL? = nil,
        copyrightReport: URL? = nil,
        cookiePolicy: URL? = nil
    ) {
        self.helpCenter = helpCenter
        self.contactSupport = contactSupport
        self.reportProblem = reportProblem
        self.termsOfService = termsOfService
        self.privacyPolicy = privacyPolicy
        self.communityGuidelines = communityGuidelines
        self.legalNotice = legalNotice
        self.copyrightReport = copyrightReport
        self.cookiePolicy = cookiePolicy
    }

    /// What the app ships with today: nothing live yet (#424).
    public static let current = SettingsLinks()
}
