import CoreModels
import CoreNavigation
import Notifications
import UIKit
import UserNotifications

/// Push notifications from the notification service (#651): where this
/// install's token goes, what a tap opens, and the app icon's badge.
///
/// - **Registration.** `notification.v1 RegisterDevice` on every launch and
///   sign-in, once the viewer has allowed notifications — never a prompt of
///   its own: permission is asked from Settings → Notifications. The device id
///   is the session's own (`AppContainer.persistentDeviceID`, the one the login
///   sent), and the environment follows the build: development builds talk to
///   the APNs sandbox, TestFlight and App Store builds to production.
/// - **A tap** opens the notification's subject: the post, the comment's
///   post with its thread up, or the profile.
/// - **The badge** is the unread count: the push sets it, and the shell sets
///   it again after a read, which no push follows.
///
/// ⚠️ PUSHES NEED THE `aps-environment` ENTITLEMENT, which only the paid
/// developer program grants: the device Debug build (free team) signs with
/// none, so there `registerForRemoteNotifications` fails and nothing is sent.
/// The simulator and Release builds carry it (`core-platform-ios.entitlements`).
@MainActor
final class PushNotifications: NSObject {
    private let registering: any PushDeviceRegistering
    private let deviceID: String
    /// The router, once the shell exists; nil before it.
    private let router: () -> (any Router)?
    /// A comment's post, for a tap on a comment's notification.
    private let postOfComment: @Sendable (String) async -> PostID?
    /// A tap that arrived before the shell could route it — a cold launch
    /// from the notification. Routed by `routePending()`.
    private var pending: PushPayload.Destination?

    /// Which APNs gateway this build's tokens belong to.
    static var environment: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    init(
        registering: any PushDeviceRegistering,
        deviceID: String,
        router: @escaping () -> (any Router)?,
        postOfComment: @escaping @Sendable (String) async -> PostID?
    ) {
        self.registering = registering
        self.deviceID = deviceID
        self.router = router
        self.postOfComment = postOfComment
    }

    /// Takes the notification center's delegate. At launch, before
    /// `didFinishLaunching` returns, so a tap that launched the app is heard.
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks APNs for this install's token when the viewer has allowed
    /// notifications; the token comes back through `didRegister(deviceToken:)`.
    func registerIfAllowed() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UIApplication.shared.registerForRemoteNotifications()
            default:
                break
            }
        }
    }

    /// APNs answered: hand the token to the notification service.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let registering = registering
        let deviceID = deviceID
        Task {
            // A guest has no profile to register for: the repository refuses,
            // and the next sign-in registers again.
            do {
                try await registering.registerPushDevice(
                    token: token, deviceID: deviceID, environment: Self.environment
                )
                Self.trace("registered \(token.prefix(8))… env=\(Self.environment)")
            } catch {
                Self.trace("register refused: \(error)")
            }
        }
    }

    /// Before signing out, while the session can still say who it is: this
    /// install stops receiving the departing profile's pushes.
    func signOut() async {
        try? await registering.unregisterPushDevice(deviceID: deviceID)
        setBadge(0)
    }

    /// The app icon's badge: the unread count.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
    }

    /// Routes a tap that came before the shell existed. Called once the shell
    /// is up.
    func routePending() {
        guard let pending else { return }
        self.pending = nil
        open(pending)
    }

    /// `-push-log`: registration and taps, which no screen shows.
    private static func trace(_ line: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-push-log") { print("[push] \(line)") }
        #endif
    }

    private func open(_ destination: PushPayload.Destination) {
        Self.trace("open \(destination)")
        guard let router = router() else {
            pending = destination
            return
        }
        switch destination {
        case .post(let id):
            router.route(to: .post(id))
        case .profile(let id):
            router.route(to: .profile(id, stub: nil))
        case .comment(let commentID):
            let postOfComment = postOfComment
            Task { [weak self] in
                guard let postID = await postOfComment(commentID) else { return }
                // The thread is what the notification is about.
                self?.router()?.route(to: .comments(postID))
            }
        }
    }
}

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// In the foreground, a push shows as a banner like anywhere else.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap. Read here — `userInfo` does not cross actors — and opened on the
    /// main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { open(payload.destination) }
    }
}
