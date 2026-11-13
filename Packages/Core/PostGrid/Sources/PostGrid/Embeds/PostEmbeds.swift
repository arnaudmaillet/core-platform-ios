import CoreModels
import DesignSystem
import Foundation
import LaunchArguments

/// A text post's embed (#2216) on every surface that draws one: the switch,
/// the sizes and the card's words, in one module every surface reaches —
/// Feed, Maps and Profile all depend on PostGrid (no feature imports
/// another).
///
/// ⚠️ **In PostGrid, not VoiceKitUI** (#2216 asks for #2205's module): the
/// card draws the channel's photo, and the app's image loading (`MediaCore`)
/// is out of VoiceKit's reach — its package depends on no local package but
/// CacheKit and DesignSystem, for AVFoundation's sake (see
/// `VoiceKit/Package.swift`). PostGrid already carries the voice component
/// to the same surfaces, so the two sit side by side for every host.
public enum PostEmbeds {
    /// `-channels` (DEBUG) until #2218: without it a showcase is drawn as the
    /// text post it is — its caption — on every surface.
    public static var areDrawn: Bool { DebugFlags.isOn("-channels") }

    /// The embed a surface draws for `embed`, if any: nil with the switch
    /// off. The ONE test a surface reads.
    public static func shown(_ embed: PostEmbed?, drawn: Bool = areDrawn) -> PostEmbed? {
        drawn ? embed : nil
    }

    /// The longest caption a showcase's share text carries — the voice's
    /// (#2208), so the two read alike in the system sheet.
    public static let shareCaptionLimit = 80

    /// What a showcase's share says where no card is drawn (#2216): "📣
    /// Harbour notes", and the author's words cut at `shareCaptionLimit`
    /// ("📣 Harbour notes · Boats in at six"); nil for a post with no embed,
    /// or with the switch off. The system sheet's title and Mail's subject
    /// carry it (`ShareCard.detail`). Pure.
    public static func shareText(caption: String?, embed: PostEmbed?, drawn: Bool = areDrawn) -> String? {
        guard let embed = shown(embed, drawn: drawn) else { return nil }
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cut = words.count > shareCaptionLimit ? String(words.prefix(shareCaptionLimit)) + "…" : words
        return embed.previewText(caption: cut)
    }

    /// How much room a surface gives the caption's card — #2204's rule
    /// again: each surface keeps its text design, only the caption's place
    /// becomes the card, sized to the room.
    public enum Size: Sendable, Equatable, CaseIterable {
        /// Photo, name, description (two lines), subscriber count, the last
        /// message's first line, the action: the text page, the map's text
        /// bubble, For You's card preview, place-page and history rows.
        case full
        /// Photo, name, count, the action: shelf cards.
        case compact
        /// The photo with a channel glyph, the name; not interactive — a tap
        /// is the tile's: grid tiles and map pins.
        case mark
    }
}

/// A channel card's words (#2216), each in one place — the card, its
/// VoiceOver label and the catalogue say a channel the same way.
public enum ChannelEmbedCopy {
    /// "1 subscriber", "820 subscribers", "12.4K subscribers" — Chat's
    /// `ChannelCopy.subscriberCount`, which PostGrid can't reach.
    public static func subscriberCount(_ count: Int) -> String {
        let clamped = max(0, count)
        return clamped == 1 ? "1 subscriber" : "\(CountFormatter.compactString(for: clamped)) subscribers"
    }

    /// The button's title for `action`.
    public static func title(for action: ChannelEmbed.Action) -> String {
        switch action {
        case .join: "Join"
        case .requestToJoin: "Request to Join"
        case .requested: "Requested"
        case .open: "Open"
        }
    }

    /// What an unavailable channel's card says (Bluesky's `viewNotFound` /
    /// `viewBlocked`); nil for one that is available.
    public static func unavailable(_ availability: ChannelEmbed.Availability) -> String? {
        switch availability {
        case .available: nil
        case .deleted: "This channel no longer exists"
        case .private: "This channel is private"
        case .blocked: "This channel isn't available"
        }
    }

    /// The same, in the few words a mark has room for.
    public static func unavailableMark(_ availability: ChannelEmbed.Availability) -> String? {
        switch availability {
        case .available: nil
        case .deleted: "Deleted channel"
        case .private: "Private channel"
        case .blocked: "Unavailable"
        }
    }

    /// The glyph an unavailable card wears.
    public static func unavailableSymbol(_ availability: ChannelEmbed.Availability) -> String {
        switch availability {
        case .available: channelSymbol
        case .deleted: "trash"
        case .private: "lock.fill"
        case .blocked: "nosign"
        }
    }

    /// A channel's glyph: the megaphone every channel row in Chats wears (#2230).
    public static let channelSymbol = "megaphone.fill"

    /// What VoiceOver reads for the card: "Channel Harbour notes, 10
    /// subscribers" — the action is its own button.
    public static func accessibilityLabel(_ channel: ChannelEmbed) -> String {
        if let unavailable = unavailable(channel.availability) { return unavailable }
        return "Channel \(channel.displayName), \(subscriberCount(channel.subscriberCount))"
    }

    /// The cancel's confirmation.
    public static let cancelRequestTitle = "Cancel Request"
    public static let cancelRequestMessage = "Your request to join will be withdrawn."
}
