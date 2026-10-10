import DesignSystem

extension Loadable {
    /// What a settings read leaves on screen (#799).
    ///
    /// ⚠️ **A FAILED READ IS NEVER A VALUE.** Settings used to fold a failure
    /// into a default — `try? … ?? false`, `?? "Not set"`, "nothing requested"
    /// — so a dropped connection read as an adult account, an empty phone
    /// number or an all-clear checkup. A read that fails is `.failed`, drawn
    /// as the "Couldn't load … Tap to try again." row every Settings screen
    /// already uses.
    ///
    /// A value already on screen outlives a later failed refresh: the screen
    /// keeps showing what it last knew rather than trading a true value for
    /// an error row. The caller reports that failure with a toast.
    func refreshed(by result: Result<Content, any Error>, failure message: String) -> Loadable {
        switch result {
        case .success(let value): .content(value)
        case .failure: content.map(Loadable.content) ?? .failed(message: message)
        }
    }

    /// True when the last read failed and there is nothing older to show.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Runs `read` and wraps its outcome, so a view model can hand it to
/// `Loadable.refreshed(by:failure:)` without a `do`/`catch` per field.
@MainActor
func settingsRead<Value: Sendable>(_ read: () async throws -> Value) async -> Result<Value, any Error> {
    do {
        return .success(try await read())
    } catch {
        return .failure(error)
    }
}
