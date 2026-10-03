import Foundation

/// A write a guest cannot make: the app asks them to sign up first
/// (guest mode, `dev/GUEST_MODE_REPORT.md` §3). Each case carries what its
/// sign-up sheet needs to say why it opened.
public enum GatedAction: Sendable, Equatable {
    case like
    case comment
    case follow(handle: String?)
    case save
    case repost
    case message(handle: String?)
    case create
    case useSound
    case saveSound
    case followingFeed
    case inbox
    case notifications
    case ownProfile
    case followPlace
    case unlockCountry
    case shop
    case claim

    /// The sign-up sheet's title: the reason it opened, in the person's terms.
    public var signUpPrompt: String {
        switch self {
        case .like: "Sign up to like this post"
        case .comment: "Sign up to join the conversation"
        case .follow(let handle): handle.map { "Sign up to follow @\($0)" } ?? "Sign up to follow"
        case .save: "Sign up to save posts"
        case .repost: "Sign up to repost"
        case .message(let handle): handle.map { "Sign up to message @\($0)" } ?? "Sign up to send messages"
        case .create: "Sign up to post"
        case .useSound, .saveSound: "Sign up to use this sound"
        case .followingFeed: "Sign up to see posts from people you follow"
        case .inbox: "Sign up to message friends"
        case .notifications: "Sign up to get notified"
        case .ownProfile: "Sign up to create your profile"
        case .followPlace, .unlockCountry, .shop: "Sign up to explore more places"
        case .claim: "Sign up to claim your likes"
        }
    }
}

/// The one question every write asks before it runs: is there an account?
///
/// ```swift
/// guard await gate.requireMember(for: .follow(handle: author.handle)) else { return }
/// try await socialGraph.setFollowing(true, profile: author.id)
/// ```
///
/// Members pass at once. A guest is shown the sign-up sheet titled for the
/// action, and the call returns true only once a session exists, so the
/// caller carries on with the action the guest started — or false if they
/// closed the sheet, and the caller does nothing.
@MainActor
public protocol MemberGating: AnyObject {
    var isMember: Bool { get }
    func requireMember(for action: GatedAction) async -> Bool
}

/// Shows the sign-up flow for a gated action. Implemented by the app, which
/// owns presentation; `completion` is called exactly once — true when a session
/// landed, false when the flow was closed.
@MainActor
public protocol SignUpPresenting: AnyObject {
    func presentSignUp(for action: GatedAction?, completion: @escaping @MainActor (Bool) -> Void)
}

/// `MemberGating` over a `SignUpPresenting`. One instance per app
/// (`AppContainer.memberGate`); the app keeps `isMember` in step with the
/// session.
@MainActor
public final class MemberGate: MemberGating {
    public var isMember: Bool
    public weak var presenter: (any SignUpPresenting)?
    /// Every caller waiting on the sheet that is up: a second gated tap while
    /// it is open joins it rather than opening another.
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    public init(isMember: Bool = false) {
        self.isMember = isMember
    }

    public func requireMember(for action: GatedAction) async -> Bool {
        if isMember { return true }
        guard let presenter else { return false }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            presenter.presentSignUp(for: action) { [weak self] signedIn in
                self?.finish(signedIn: signedIn)
            }
        }
    }

    private func finish(signedIn: Bool) {
        let resumed = waiting
        waiting = []
        for continuation in resumed {
            continuation.resume(returning: signedIn)
        }
    }
}
