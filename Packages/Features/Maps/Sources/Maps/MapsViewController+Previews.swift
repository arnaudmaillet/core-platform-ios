import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import LocalStore
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// Live previews and predictive prefetch (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Live previews

    /// Recomputes the ≤3 video pins to autoplay: the on-screen, video-capable,
    /// LONE pins (a clustered post isn't its own marker), ranked by closeness
    /// to the viewport center.
    func refreshVideoPlayback() {
        // The same moments decide the one preroll (#654): markers arrived, the
        // map settled, came back into view.
        scheduleIdlePreroll()
        let center = mapView.centerCoordinate
        let visibleRect = mapView.visibleMapRect
        var scored: [(distance: Double, candidate: MapVideoPlaybackCoordinator.Candidate)] = []
        for annotation in displayed.values {
            // The pin a marker SPEAKS FOR: itself when it is a lone pin, its
            // representative when it is a cluster.
            //
            // A cluster's face is one of its members' posts and representatives
            // are kind-neutral, so a video post leading a group is ordinary. It
            // could never play before, because the candidate's view was typed
            // to the lone-pin class — and on the mock corpus that meant nothing
            // ever played at all: every video pin in the default viewport was
            // inside a cluster.
            var spokenPin: MapPin?
            var host: (any MapVideoHost)?
            if let single = annotation as? MapAnnotation {
                spokenPin = single.pin
                host = mapView.view(for: single) as? MapAnnotationView
            } else if let group = annotation as? MapComputedCluster {
                spokenPin = group.representative
                host = mapView.view(for: group) as? MapClusterAnnotationView
            }
            // A locked country's marker plays nothing: it is a teaser, darkened,
            // and its post is not the viewer's to watch.
            guard let pin = spokenPin, let host,
                  isInUnlockedCountry(pin),
                  pin.kind == .video,
                  let url = pin.previewVideoURL,
                  visibleRect.contains(MKMapPoint(annotation.coordinate))
            else { continue }
            let candidate = MapVideoPlaybackCoordinator.Candidate(
                id: pin.postID, url: url, host: host
            )
            scored.append((Self.squaredDistance(annotation.coordinate, center), candidate))
        }
        let ranked = scored.sorted { $0.distance < $1.distance }.map(\.candidate)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-map-icon-hud-log") {
            let lone = displayed.values.compactMap { $0 as? MapAnnotation }
            let groups = displayed.values.compactMap { $0 as? MapComputedCluster }
            print("MAPVIDEO lone=\(lone.count) clusters=\(groups.count) "
                  + "loneVideo=\(lone.count { $0.pin.kind == .video }) "
                  + "clusterVideo=\(groups.count { $0.representative.kind == .video }) "
                  + "onScreen=\(scored.count) chosen=\(ranked.count)")
        }
        #endif
        videoCoordinator.update(candidates: ranked)
    }

    private static func squaredDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude
        let dLng = a.longitude - b.longitude
        return dLat * dLat + dLng * dLng
    }

    // MARK: - Predictive prefetch

    /// Warms the full post behind every visible annotation — the first member for
    /// a cluster — so a tap opens the snap feed from cache with no metadata
    /// desync. Bounded by clustering (a handful of annotations) and capped;
    /// cancels the prior sweep so a fast pan never piles up speculative fetches.
    /// The ONLY place in this feature that writes the map's interaction.
    ///
    /// ⚠️ ONE WRITE, NOT FOUR FLAGS. `isUserInteractionEnabled` covers both
    /// halves at once — MapKit's own pan/pinch/rotate AND every marker's
    /// instant-tap recognizer, which is attached to the annotation VIEW.
    /// Hit-testing never descends into a view that is not interactive, so one
    /// write starves both; `isScrollEnabled` and friends would leave the marker
    /// recognizers live, which is exactly the "a second post opened over the
    /// first" case. Programmatic `selectAnnotation` is unaffected, so the DEBUG
    /// openers and any deep link still work.
    ///
    /// The map's own bar items go with it: they sit ABOVE the transition
    /// container, so neither the hero's shield nor the reveal's host covers
    /// them, and the bell pushes onto the very stack the flight is animating.
    func applyMapInteraction() {
        let inert = openGate.mapIsInert
        // The guest lock rides the SAME write (#564): two writers of one
        // property would undo each other.
        mapView.isUserInteractionEnabled = Self.mapIsInteractive(inert: inert, guestLocked: isGuestLocked)
        navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = !inert }
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = !inert }
    }

    func prewarmVisiblePosts() {
        let visible = mapView.annotations(in: mapView.visibleMapRect)
        var ids: [PostID] = []
        var seen = Set<PostID>()
        func add(_ id: PostID) { if seen.insert(id).inserted { ids.append(id) } }
        for element in visible {
            // A locked marker never opens, so there is nothing to warm.
            if let pin = element as? MapAnnotation, isInUnlockedCountry(pin.pin) {
                add(pin.pin.postID)
            } else if let cluster = element as? MapComputedCluster, isInUnlockedCountry(cluster.representative) {
                cluster.memberIDs.forEach(add)
            }
        }
        guard !ids.isEmpty else { return }

        let batch = Array(ids.prefix(Self.prewarmCap))
        prewarmTask?.cancel()
        let prewarm = self.prewarm
        prewarmTask = Task { await prewarm(batch) }
    }
}
