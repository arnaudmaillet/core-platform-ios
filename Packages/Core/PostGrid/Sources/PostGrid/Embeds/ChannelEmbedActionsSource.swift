import CoreModels
import UIKit

/// What a channel card's button does (#2216), as the composition root hands
/// it out (#2506): Chat's actions, made on the first tap rather than at
/// launch, so a launch that lands on a post never builds Chat, and made once
/// (the same instance every card and a profile's Channels rows use, so Chats
/// reloads the same catalog).
///
/// The app builds ONE and sets it on its window as a trait
/// (`ChannelEmbedActionsTrait`): every card reads it from its trait
/// environment when its button is tapped. A test or the catalogue sets its
/// own on the view it hosts the card in.
@MainActor
public final class ChannelEmbedActionsSource {
    private let make: @MainActor () -> (any ChannelEmbedActing)?
    private var made: (any ChannelEmbedActing)?

    /// - Parameter make: asked on the first use, and again while it answers
    ///   nil (the channels off: nothing to act with, and nothing built).
    public init(make: @escaping @MainActor () -> (any ChannelEmbedActing)?) {
        self.make = make
    }

    /// Actions already in hand: a test's spy, the catalogue's stand-ins.
    public convenience init(_ actions: any ChannelEmbedActing) {
        self.init { actions }
    }

    /// The actions, made now if they weren't yet. Nil with the channels off.
    public var actions: (any ChannelEmbedActing)? {
        if let made { return made }
        made = make()
        return made
    }
}

extension ChannelEmbedActionsSource: Equatable {
    /// The same source, by identity: the trait system compares values to
    /// tell a change.
    public nonisolated static func == (lhs: ChannelEmbedActionsSource, rhs: ChannelEmbedActionsSource) -> Bool {
        lhs === rhs
    }
}

/// The channel card's actions as a trait (#2506, ADR 0016): set once on the
/// app's window by the composition root, inherited by every view under it,
/// read by `PostEmbedView` when its button is tapped. Nil (the default): no
/// one set any.
public struct ChannelEmbedActionsTrait: UITraitDefinition {
    public static var defaultValue: ChannelEmbedActionsSource? { nil }
    public static var name: String { "ChannelEmbedActions" }
}

extension UITraitCollection {
    /// The channel card's actions in this environment (`ChannelEmbedActionsTrait`).
    public var channelEmbedActions: ChannelEmbedActionsSource? { self[ChannelEmbedActionsTrait.self] }
}

extension UIMutableTraits {
    /// Sets the channel card's actions for a window, a view or a controller
    /// and everything under it: `window.traitOverrides.channelEmbedActions = …`.
    public var channelEmbedActions: ChannelEmbedActionsSource? {
        get { self[ChannelEmbedActionsTrait.self] }
        set { self[ChannelEmbedActionsTrait.self] = newValue }
    }
}
