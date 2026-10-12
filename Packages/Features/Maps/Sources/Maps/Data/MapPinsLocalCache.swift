import CoreModels
import Foundation
import LocalStore
import OSLog
import Synchronization

/// The map's pins of the last viewports on the device (#893), in the
/// LocalStore: a cold start puts the markers back on the map before the first
/// tile query answers, offline included, then the query revalidates them.
///
/// ⚠️ PINS, NOT TILES. MapKit keeps its own tile cache, and the marker art has
/// its own (`IconBaker`, the image pipeline): this stores only what a marker
/// is made of, as the wire sent it (`RadarPin` plus its like count). The DEBUG
/// decorations (mock places, avatars, icons, preview sheets) are not stored:
/// the view model runs them over the restored pins as over any answer.
///
/// One list (`map.pins`), one page: the pins of the last unfiltered answers,
/// the newest viewport first, at most `maxStoredPins`. Each answer REPLACES
/// what was stored inside its viewport (a pin gone from there is gone) and
/// keeps the rest, so the list is the map as last seen around each place the
/// viewer looked. A filtered answer is not stored: it is a view of the map,
/// not the map. A pin is a versioned JSON record; a format this build cannot
/// read is a miss.
///
/// Reads are synchronous (the map's first frame); writes go to a serial
/// queue, coalesced: a fast pan's answers fold into one write.
final class MapPinsLocalCache: Sendable {
    static let listKey = "map.pins"
    static let entityType = "map.pin"
    static let format = 1
    /// Enough for a few viewports of a dense city (a tile query answers a
    /// few dozen to a couple of hundred pins); about 60 KB of records.
    static let maxStoredPins = 400

    private let store: LocalStore
    private let queue = DispatchQueue(label: "cn.wynn.map-pins-local-cache", qos: .utility)
    private let logger = Logger(subsystem: "cn.wynn.core-platform-ios", category: "map-pins-cache")

    /// One answer to fold into the stored pins.
    private struct Answer {
        var pins: [MapPin]
        var viewport: MapViewport
        var viewer: LocalStoreViewer?
    }

    private struct State {
        /// Answers recorded and not yet folded, oldest first.
        var answers: [Answer] = []
        var drainScheduled = false
    }

    private let state = Mutex(State())

    init(store: LocalStore) {
        self.store = store
    }

    /// Who an answer is being fetched for, captured before the query.
    var viewer: LocalStoreViewer? { store.currentViewer }

    /// The stored pins, newest viewport first; nil when nothing is stored for
    /// the viewer here now.
    func stored() -> [MapPin]? {
        storedRecords()?.map(\.pin)
    }

    /// Folds an unfiltered answer for `viewport` into the stored pins, as the
    /// viewer captured before its query.
    func record(_ pins: [MapPin], in viewport: MapViewport, as viewer: LocalStoreViewer?) {
        let schedules = state.withLock { state -> Bool in
            state.answers.append(Answer(pins: pins, viewport: viewport, viewer: viewer))
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        guard schedules else { return }
        queue.async { [self] in drain() }
    }

    /// Waits for every write queued so far. Tests only.
    func waitForPendingWrites() {
        queue.sync {}
        store.waitForPendingWrites()
    }

    // MARK: - Writing

    /// On the queue: folds every answer recorded so far into what is stored,
    /// then writes once. Read back from the store each time, never kept in
    /// memory: a wipe (a viewer change, a Settings clear) leaves nothing here
    /// to write back.
    private func drain() {
        let answers = state.withLock { state in
            defer {
                state.answers.removeAll()
                state.drainScheduled = false
            }
            return state.answers
        }
        guard let writer = answers.last?.viewer else { return }
        // Only the last answer's viewer's: an answer fetched for someone who
        // has since left never folds into the next person's pins.
        var pins = storedRecords() ?? []
        for answer in answers where answer.viewer?.isSamePerson(as: writer) == true {
            pins = Self.folding(answer.pins.map(Record.init), in: answer.viewport, into: pins)
        }
        let entities = pins.compactMap { record -> LocalEntityWrite? in
            guard let payload = try? JSONEncoder().encode(record) else { return nil }
            return LocalEntityWrite(
                key: LocalEntityKey(type: Self.entityType, id: record.id), payload: payload,
                format: Self.format, lifetime: LocalStorePolicy.mapPinLifetime
            )
        }
        let page = LocalListPage(items: entities.map(\.key), entities: entities, nextCursor: nil, tier: .retained)
        do {
            try store.replaceList(Self.listKey, with: page, as: writer, lifetime: LocalStorePolicy.mapPinLifetime)
        } catch {
            logger.error("map pins cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func storedRecords() -> [Record]? {
        guard let list = store.list(Self.listKey) else { return nil }
        return list.entries.compactMap { entity -> Record? in
            guard entity.format == Self.format else { return nil }
            return try? JSONDecoder().decode(Record.self, from: entity.payload)
        }
    }

    /// The answer's pins first; then what was stored OUTSIDE its viewport,
    /// in its order; at most `maxStoredPins`. Pure, for tests.
    static func folding(_ answer: [Record], in viewport: MapViewport, into stored: [Record]) -> [Record] {
        var seen = Set<String>()
        var folded: [Record] = []
        for record in answer where seen.insert(record.id).inserted {
            folded.append(record)
        }
        for record in stored where !viewport.contains(latitude: record.latitude, longitude: record.longitude) {
            guard seen.insert(record.id).inserted else { continue }
            folded.append(record)
        }
        return Array(folded.prefix(maxStoredPins))
    }

    // MARK: - Record

    /// One pin as stored: the wire's fields only. Kinds are fixed strings,
    /// never the case order: the file outlives the code.
    struct Record: Codable, Equatable {
        var id: String
        var latitude: Double
        var longitude: Double
        var thumbnailURL: URL?
        var kind: String
        var likeCount: Int64

        init(_ pin: MapPin) {
            id = pin.postID.rawValue
            latitude = pin.latitude
            longitude = pin.longitude
            thumbnailURL = pin.thumbnailURL
            kind = switch pin.kind {
            case .photo: "photo"
            case .video: "video"
            case .text: "text"
            }
            likeCount = pin.likeCount
        }

        var pin: MapPin {
            let storedKind: MapPin.Kind = switch kind {
            case "video": .video
            case "text": .text
            default: .photo
            }
            return MapPin(
                postID: PostID(id), latitude: latitude, longitude: longitude,
                thumbnailURL: thumbnailURL, kind: storedKind, likeCount: likeCount
            )
        }
    }
}

extension MapViewport {
    /// Whether a coordinate lies in the box, edges included.
    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= swLat && latitude <= neLat && longitude >= swLng && longitude <= neLng
    }
}
