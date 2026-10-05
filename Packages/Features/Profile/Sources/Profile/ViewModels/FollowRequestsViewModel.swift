import CoreModels
import Foundation

/// State for Settings → Privacy → Follow Requests (#396).
@MainActor
final class FollowRequestsViewModel {
    enum Phase: Equatable {
        case loading
        case loaded([FollowRequest])
        case failed
    }

    private(set) var phase: Phase = .loading {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let requests: any FollowRequestsManaging

    init(requests: any FollowRequestsManaging) {
        self.requests = requests
    }

    func load() async {
        if case .failed = phase { phase = .loading }
        do {
            phase = .loaded(try await requests.followRequests())
        } catch {
            phase = .failed
        }
    }

    /// Approves and drops the row once the server agrees.
    func confirm(_ request: FollowRequest) async throws {
        try await requests.approveFollowRequest(from: request.id)
        drop(request)
    }

    /// Declines and drops the row once the server agrees. The requester isn't told.
    func delete(_ request: FollowRequest) async throws {
        try await requests.declineFollowRequest(from: request.id)
        drop(request)
    }

    private func drop(_ request: FollowRequest) {
        if case .loaded(let current) = phase {
            phase = .loaded(current.filter { $0.id != request.id })
        }
    }

    /// The row's initials: display name first, the handle when there is none.
    static func monogram(for request: FollowRequest) -> String {
        let source = request.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? request.handle : request.displayName
        let initials: [String] = source.split(separator: " ").prefix(2).compactMap { word in word.first.map { String($0).uppercased() } }
        return initials.isEmpty ? "?" : initials.joined()
    }
}
