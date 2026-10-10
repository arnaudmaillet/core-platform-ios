import Foundation

/// State for Settings → Ads and Data (#395): the account's consents, and the
/// one change on its way to the server.
///
/// One save at a time, for the whole screen. Each save answers with the full
/// record, so two in flight could land in either order and the later answer
/// would undo the earlier change on screen; a failed first save would also
/// flip back a switch a second flip had already moved. While a change
/// travels it is shown as made (the switch the viewer flipped stays where
/// they put it), the switches are disabled, and a failure puts the consent
/// back where it was.
@MainActor
final class ConsentsViewModel {
    enum Consent: Hashable, Sendable {
        case marketing, analytics
    }

    enum Phase: Equatable {
        case loading
        case loaded(AccountConsents)
        case failed
    }

    /// What a flip came to.
    enum Outcome: Equatable {
        case saved
        /// Not sent: another change is being saved, or nothing is loaded.
        case ignored
        /// Not saved; the consent shows its previous value again.
        case failed
    }

    private struct Change: Equatable {
        let consent: Consent
        let isGiven: Bool
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    /// The change being saved, shown as made while it travels.
    private var pending: Change? {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let manager: any AccountConsentManaging

    init(manager: any AccountConsentManaging) {
        self.manager = manager
    }

    /// True while a change is on its way: the screen disables the switches.
    var isSaving: Bool { pending != nil }

    var consents: AccountConsents? {
        if case .loaded(let consents) = phase { return consents }
        return nil
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await manager.consents())
        } catch {
            phase = .failed
        }
    }

    /// What the switch for `consent` shows: the change in flight if it is
    /// this one, the record otherwise.
    func isGiven(_ consent: Consent) -> Bool {
        if let pending, pending.consent == consent { return pending.isGiven }
        switch consent {
        case .marketing: return consents?.marketing.isGiven ?? false
        case .analytics: return consents?.analytics.isGiven ?? false
        }
    }

    /// Gives or withdraws `consent`; at most one change is sent at a time.
    func set(_ consent: Consent, to isGiven: Bool) async -> Outcome {
        guard consents != nil, pending == nil else { return .ignored }
        pending = Change(consent: consent, isGiven: isGiven)
        do {
            let next = try await manager.updateConsents(
                marketing: consent == .marketing ? isGiven : nil,
                analytics: consent == .analytics ? isGiven : nil
            )
            phase = .loaded(next)
            pending = nil
            return .saved
        } catch {
            pending = nil
            return .failed
        }
    }
}
