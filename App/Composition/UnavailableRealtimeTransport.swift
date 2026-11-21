import CoreRealtime
import Foundation

/// A backend with no realtime socket (#2391: `REALTIME_URL` empty): the
/// connection never opens and never fails, so the client waits quietly
/// instead of retrying in a loop, and every live update simply never comes.
/// The screens read their counts from RPCs either way.
nonisolated struct UnavailableRealtimeTransport: RealtimeTransport {
    func connect(edgeToken: String) async throws -> AsyncStream<RealtimeTransportEvent> {
        AsyncStream { _ in }
    }

    func send(_ data: Data) async throws {
        throw URLError(.notConnectedToInternet)
    }

    func disconnect() async {}
}
