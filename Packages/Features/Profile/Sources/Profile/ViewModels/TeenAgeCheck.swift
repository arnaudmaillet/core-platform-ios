import DesignSystem

/// Whether the account is 13 to 17, for Settings → Family and Teens (#799).
///
/// A read that throws is `.failed`, never "adult" — see
/// `FamilyAndTeensViewController`.
///
/// ⚠️ **ONE READ AT A TIME.** The failed row stays on screen while its retry
/// runs, so a double tap used to send two reads and, offline, stack two
/// toasts. A call made while a read is in flight sends nothing and returns
/// true — the read in flight reports.
@MainActor
final class TeenAgeCheck {
    private(set) var age: Loadable<Bool> = .loading
    private(set) var isReading = false

    private let isTeen: () async throws -> Bool

    init(isTeen: @escaping () async throws -> Bool) {
        self.isTeen = isTeen
    }

    /// Returns false when the read failed.
    @discardableResult
    func read() async -> Bool {
        guard !isReading else { return true }
        isReading = true
        defer { isReading = false }
        age = await FamilyAndTeensViewController.readAge(isTeen)
        return !age.isFailed
    }
}
