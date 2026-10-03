import Foundation

/// State for Settings → Privacy's Private Account switch (#388).
///
/// Not optimistic. The switch shows what the server holds: it is disabled
/// while a change is in flight and snaps back if the change fails, because a
/// privacy switch that shows "on" while the profile is still public is the
/// one kind of wrong this screen cannot afford.
@MainActor
final class PrivacySectionViewModel {
    enum Phase: Equatable {
        case loading
        case loaded(isPrivate: Bool)
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    private(set) var isSaving = false {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let visibility: any ProfileVisibilityManaging

    init(visibility: any ProfileVisibilityManaging) {
        self.visibility = visibility
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(isPrivate: try await visibility.activeProfileIsPrivate())
        } catch {
            phase = .failed
        }
    }

    func setPrivate(_ isPrivate: Bool) async throws {
        guard case .loaded(let current) = phase, current != isPrivate, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        try await visibility.setActiveProfilePrivate(isPrivate)
        phase = .loaded(isPrivate: isPrivate)
    }
}
