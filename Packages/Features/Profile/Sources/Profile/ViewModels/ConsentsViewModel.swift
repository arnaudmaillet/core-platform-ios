import CoreNetworking
import Foundation
import LocalStore

/// State for Settings → Ads and Data (#395): the account's consents, and the
/// changes on their way to the server.
///
/// ⚠️ ONE SAVE AFTER ANOTHER, in the order flipped. Each save answers with
/// the full record, so two in flight could land in either order and the
/// later answer would undo the earlier change on screen. Run in turn, each
/// starts from the record the one before left — so the other switch stays
/// usable while one travels (#1775, the owner 2026-10-28). A change on its
/// way is shown as made (the switch stays where the viewer put it, its row
/// waits with the loader), and a failure puts only that consent back.
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

    private(set) var phase: Phase = .loading {
        didSet {
            // Every answer, a save's included, is the next visit's first
            // frame (#1776).
            if case .loaded(let consents) = phase {
                deviceCache?.store(consents, as: ConsentsRecord.self, viewer: writer)
            }
            onChange?()
        }
    }
    /// The consents as the server last said (#1776): the screen opens on
    /// them, then revalidates in place.
    private let deviceCache: SettingsLocalCache?
    private let writer: LocalStoreViewer?
    /// The changes being saved, shown as made while they travel.
    private var pending: [Consent: Bool] = [:] {
        didSet { onChange?() }
    }
    /// The last save asked for: the next waits for it.
    private var tail: Task<Void, Never>?
    /// Why the last load failed, kept beside `.failed` so the failed row
    /// can say "You’re offline" when that is the cause (#794). Set before
    /// the phase, so the redraw `.failed` triggers already reads it.
    private(set) var failure: NetworkFailure?
    var onChange: (() -> Void)?

    private let manager: any AccountConsentManaging

    init(manager: any AccountConsentManaging, deviceCache: SettingsLocalCache? = nil) {
        self.manager = manager
        self.deviceCache = deviceCache
        writer = deviceCache?.viewer
        if let stored = deviceCache?.value(ConsentsRecord.self) { phase = .loaded(stored) }
    }

    /// True while any change is on its way.
    var isSaving: Bool { !pending.isEmpty }

    /// True while `consent`'s change is on its way: its switch waits.
    func isSaving(_ consent: Consent) -> Bool { pending[consent] != nil }

    var consents: AccountConsents? {
        if case .loaded(let consents) = phase { return consents }
        return nil
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await manager.consents())
        } catch {
            failure = NetworkFailure.of(error)
            // A failed revalidation keeps the consents on screen.
            if case .loaded = phase { return }
            phase = .failed
        }
    }

    /// What the switch for `consent` shows: the change in flight if it is
    /// this one, the record otherwise.
    func isGiven(_ consent: Consent) -> Bool {
        if let pending = pending[consent] { return pending }
        switch consent {
        case .marketing: return consents?.marketing.isGiven ?? false
        case .analytics: return consents?.analytics.isGiven ?? false
        }
    }

    /// Gives or withdraws `consent` once the changes before it are saved;
    /// ignored while `consent` itself is on its way.
    func set(_ consent: Consent, to isGiven: Bool) async -> Outcome {
        guard consents != nil, pending[consent] == nil else { return .ignored }
        pending[consent] = isGiven
        let previous = tail
        let manager = manager
        let save = Task<Outcome, Never> { [weak self] in
            await previous?.value
            do {
                let next = try await manager.updateConsents(
                    marketing: consent == .marketing ? isGiven : nil,
                    analytics: consent == .analytics ? isGiven : nil
                )
                self?.phase = .loaded(next)
                self?.pending[consent] = nil
                return .saved
            } catch {
                self?.pending[consent] = nil
                return .failed
            }
        }
        tail = Task { _ = await save.value }
        return await save.value
    }
}
