import CoreNetworking
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
    /// Why the last read failed: the retry's toast says what the failed row
    /// says (#794).
    private(set) var failure: NetworkFailure?

    private let isTeen: () async throws -> Bool

    init(isTeen: @escaping () async throws -> Bool) {
        self.isTeen = isTeen
    }

    /// Returns false when the read failed.
    @discardableResult
    /// `force` (#1770): Try Again past "taking longer" — a read still out
    /// is superseded rather than waited on, and its late answer dropped.
    func read(force: Bool = false) async -> Bool {
        guard force || !isReading else { return true }
        isReading = true
        readGeneration += 1
        let mine = readGeneration
        defer { if readGeneration == mine { isReading = false } }
        let isTeen = isTeen
        var caught: NetworkFailure?
        let answer = await FamilyAndTeensViewController.readAge {
            do {
                return try await isTeen()
            } catch {
                caught = NetworkFailure.of(error)
                throw error
            }
        }
        guard readGeneration == mine else { return !age.isFailed }
        age = answer
        failure = caught
        return !age.isFailed
    }

    /// The newest read: a superseded one's answer is not this check's.
    private var readGeneration = 0
}
