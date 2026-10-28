import Foundation

/// Settings saved while the viewer goes on (#1775, the owner 2026-10-28): a
/// switch stays where the tap put it, with the kit's loader beside it
/// (`UICellAccessory.busy()`), until the server holds the change — then it
/// shows the server's answer, or snaps back and the screen says why.
///
/// Not optimistic: nothing claims a change is made before it is — a privacy
/// switch reading "on" while the profile is still public is the one kind of
/// wrong those screens cannot afford — but never a tap that seems to do
/// nothing either.
///
/// ⚠️ **ONE SAVE AFTER ANOTHER, IN THE ORDER ASKED.** Most settings answer
/// with the whole record: two saves in flight could land in either order,
/// and the later answer would undo the earlier change on screen. Run in turn,
/// each save starts from the record the one before left. The other rows stay
/// usable meanwhile; only the row on its way waits.
@MainActor
public final class SettingSaves<Key: Hashable & Sendable, Value: Sendable> {
    private var pending: [Key: Value] = [:]
    private var tail: Task<Void, Never>?

    /// A change asked for, saved or let go: the screen redraws its rows.
    public var onChange: (() -> Void)?

    public init() {}

    /// The value on its way for `key`: what its row shows meanwhile.
    public func value(for key: Key) -> Value? { pending[key] }

    /// Whether `key` is on its way: its row shows the loader and waits.
    public func isSaving(_ key: Key) -> Bool { pending[key] != nil }

    /// Every value on its way, by key: what a screen lays over its record
    /// when one record holds them all.
    public var values: [Key: Value] { pending }

    /// Whether nothing is on its way.
    public var isIdle: Bool { pending.isEmpty }

    /// Shows `value` for `key` at once and saves it once the saves asked
    /// before it are done. `work` saves it and takes the server's answer in;
    /// on failure the row goes back to the record first, then `failed` says
    /// why. False, and nothing sent, while `key` is already on its way.
    @discardableResult
    public func save(
        _ value: Value, for key: Key,
        _ work: @escaping @MainActor (Value) async throws -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) -> Bool {
        guard pending[key] == nil else { return false }
        pending[key] = value
        onChange?()
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            var failure: Error?
            do { try await work(value) } catch { failure = error }
            guard let self else { return }
            pending[key] = nil
            onChange?()
            if let failure { failed(failure) }
        }
        return true
    }

    #if DEBUG
    /// Internal for tests: waits for every save asked so far.
    public func debugSettle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }
    #endif
}
