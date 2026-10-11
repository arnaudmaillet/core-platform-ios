#if DEBUG
import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MapKit
import MapsInterface
import MediaCore
import MediaPlayback
import UIKit

// MARK: - QA hooks
//
// The launch-argument drives, the `-maps-soak` harness, the marker openers,
// the nav and zoom sweeps, the icon HUD, the chrome trace and the camera log.
// Private methods stay private: this file reaches them through thin `debug*`
// wrappers in the main file (`debugUpdateSubFilterBar`, `debugShowCountry`,
// `debugOffer`, `debugBeginPlaybackWarm`, `debugGateAppearedAtRoot`, ...).
// Only stored members and pure read accessors are widened for it, each marked
// "Internal (not private) only for the +QA hooks."
//
// Left in `MapsViewController.swift` because they read locals of the
// production path they log: the `-maps-log-gate` trace in the gate's
// `didSet`, the sub-filter row-update and dock-reload prints, the churn
// counters, `-maps-no-clustering`, `-zoom-blend-log`, `-zoom-live-log`,
// `-maps-open-place`'s direct push, `-maps-demo-grab`, `-grab-log`, the
// `[card-close]` line and the `OfferLog` notes. Stored DEBUG properties stay
// with the type (an extension cannot hold them).

// MARK: - Launch arguments

extension MapsViewController {
    /// The `-maps-*` launch-argument hooks `viewDidLoad` runs last, once the
    /// map has its opening region.
    func runDebugLaunchHooks() {
        // `-maps-wide-region`: open zoomed out far enough that the mock pins
        // collapse into clusters — for screenshotting/driving cluster UI in
        // the sim, where pinch gestures can't be injected. Under dissolve
        // banding (~77 km diagonal) this is the CITY band.
        if ProcessInfo.processInfo.arguments.contains("-maps-wide-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta *= 6
            region.span.longitudeDelta *= 6
            mapView.setRegion(region, animated: false)
        }
        // `-maps-tight-region`: open at level 13 (span 0.045°, ~6.4 km
        // diagonal), framing almost the same pins as the default view. Both
        // are LOCAL-band views under dissolve banding (a city-scale viewport
        // dissolves the city): individual posts and generic proximity
        // clusters, all in neutral rings. The city-band A/B is a region-scale
        // framing (e.g. `-maps-set-region 48.7,2.5,1.6`). Screenshotable in
        // the sim, where a pinch can't be injected.
        if ProcessInfo.processInfo.arguments.contains("-maps-tight-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta = 0.045
            region.span.longitudeDelta = 0.045
            mapView.setRegion(region, animated: false)
        }
        // `-maps-country-region`: open at the COUNTRY band. Dissolve banding
        // keeps a country marker only while the viewport diagonal exceeds
        // ~2261 km (2.7 × the res-1 span), so this is a Europe-scale framing:
        // countries roll up into amber markers — the top of the nesting
        // ladder, unreachable by the ×6 wide region (city band).
        if ProcessInfo.processInfo.arguments.contains("-maps-country-region") {
            var region = Self.defaultRegion
            region.span.latitudeDelta = 20
            region.span.longitudeDelta = 20
            mapView.setRegion(region, animated: false)
        }
        // `-maps-set-region <lat>,<lng>,<spanDegrees>`: open anywhere at any
        // scale — the generic hook the European hierarchy sweep drives (the
        // sim can't inject a continent's worth of panning). Example:
        // `-maps-set-region 41.39,2.17,0.09` opens on Barcelona at the city
        // band.
        if let region = Self.debugSetRegion {
            mapView.setRegion(region, animated: false)
        }
        // `-maps-camera-distance <metres>`: pull the camera back to that
        // distance above the current centre — how the widest zoom is reached
        // in the sim (no pinch), and past what a region's span can say (a span
        // is capped at 180°/360°, a camera is not). The standard map clamps
        // it at ~26 300 km (see `MapBaseConfiguration`). Applied after
        // `-maps-set-region`, so the two compose,
        // and a second after launch: written in `viewDidLoad`, before the map
        // has a size, MapKit framed a continent instead. Logs what MapKit
        // kept. `-maps-camera-pitch <degrees>` tilts the same camera.
        if let value = Self.debugArgumentValue("-maps-camera-distance"),
           let distance = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let camera = mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
                camera.centerCoordinateDistance = distance
                if let pitch = Self.debugArgumentValue("-maps-camera-pitch").flatMap(Double.init) {
                    camera.pitch = pitch
                }
                mapView.setCamera(camera, animated: false)
                print(String(
                    format: "[maps-camera] asked=%.0f kept=%.0f pitch=%.0f span=%.2f",
                    distance, mapView.camera.centerCoordinateDistance, mapView.camera.pitch,
                    mapView.region.span.latitudeDelta
                ))
            }
        }
        // `-maps-select-filter <token>`: selects a filter pill (~1.5s after
        // launch, once the first unfiltered settle has painted) — drives the
        // filtered-query path in the sim, where taps can't be injected.
        // Tokens are `MapFilter.wireToken` (friends/following/pinned/nearby/
        // profile:<id>).
        if let token = Self.debugArgumentValue("-maps-select-filter"),
           let filter = MapFilter(wireToken: token) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.filterBar.setSelectedFilter(filter)
                self.viewModel.filterChanged(filter)
                self.debugUpdateSubFilterBar(for: filter)
            }
        }
        // `-maps-select-filter-2 <token|all>`: a SECOND primary selection at
        // ~3.5s — drives primary-to-primary switches (sub-row cross-dissolve)
        // and, with `all`, the fade-out path.
        if let token = Self.debugArgumentValue("-maps-select-filter-2") {
            let second: MapFilter? = token == "all" ? nil : MapFilter(wireToken: token)
            if second != nil || token == "all" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self else { return }
                    self.filterBar.setSelectedFilter(second)
                    self.viewModel.filterChanged(second)
                    self.debugUpdateSubFilterBar(for: second)
                }
            }
        }
        // `-maps-toggle-subfilter <profileID>`: adds or removes that profile
        // from the ACTIVE primary's rail ~5s in, while the map is on screen —
        // the edit the profile's star makes from another screen, which is the
        // one path that has to animate rather than flash. Pair with
        // `-maps-select-filter friends|following`.
        if let id = Self.debugArgumentValue("-maps-toggle-subfilter") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self,
                      let primary = filterBar.selectedFilter,
                      let category = MapSubFilterRowMemory.railCategory(for: primary) else { return }
                let profile = ProfileID(id)
                let pinService = pinService
                Task {
                    var categories = await pinService.categories(for: profile)
                    let wasOn = categories.contains(category)
                    categories.formSymmetricDifference([category])
                    print("[maps] sub-filter toggle: \(id) \(wasOn ? "leaves" : "joins") \(category)")
                    await pinService.setCategories(categories, for: profile)
                }
            }
        }
        // `-maps-subfilter-remove <profileID>`: fires that pill's context-menu
        // Remove ~5s in, through the same routing a long press does
        // (`MapSubFilterBarView.perform`). The menu itself needs a long press
        // the simulator cannot deliver, and this is the path that flashed:
        // the removal restacks, then the rail write it commits comes back
        // round as a refresh.
        if let id = Self.debugArgumentValue("-maps-subfilter-remove") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self else { return }
                print("[maps] sub-filter menu: Remove \(id)")
                subFilterBar.perform(.unpin, on: .profile(ProfileID(id)))
            }
        }
        // `-maps-subfilter-menu-audit <profileID>`: prints the pill's
        // long-press menu ~5s in — its title and its verbs, in order. The menu
        // needs a long press the simulator cannot deliver, so this is how a
        // scripted run sees what it would contain (the same instrument
        // `-profile-menu-audit` is for the profile's overflow menu).
        if let id = Self.debugArgumentValue("-maps-subfilter-menu-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let menu = self?.subFilterBar.menu(for: .profile(ProfileID(id))) else {
                    print("[maps] pill menu: no pill for \(id)")
                    return
                }
                // A person's name is the FIRST section's action now, not the
                // root title: it is the header the viewer taps. Print both,
                // plus what the pill actually carries — the header used to be
                // built correctly and never reach the screen.
                let sections = menu.children.compactMap { $0 as? UIMenu }
                let header = sections.first?.children.compactMap { $0 as? UIAction }.first
                let verbs = sections.last?.children
                    .compactMap { ($0 as? UIAction)?.title } ?? []
                let separated = sections.count > 1 || !menu.title.isEmpty
                // `installed*` is read off the pill WITHOUT opening anything:
                // the header is installed when the cell is configured, so the
                // name and handle are already on it before any thumb lands.
                let installed = self?.subFilterBar
                    .debugInstalledMenuTitle(for: .profile(ProfileID(id))) ?? "<none>"
                let installedSubtitle = self?.subFilterBar
                    .debugInstalledMenuSubtitle(for: .profile(ProfileID(id))) ?? "<none>"
                print("[maps] pill menu: header=\"\(header?.title ?? menu.title)\" "
                    + "subtitle=\"\(header?.subtitle ?? "")\" "
                    + "headerTappable=\(header != nil) headerImage=\(header?.image != nil) "
                    + "separator=\(separated) verbs=\(verbs) "
                    + "installedHeader=\"\(installed)\" "
                    + "installedSubtitle=\"\(installedSubtitle)\"")
            }
        }
        // `-maps-subfilter-menu-open <profileID>`: presents that pill's
        // long-press menu ~5s in, so the header can be screenshotted.
        if let id = Self.debugArgumentValue("-maps-subfilter-menu-open") {
            // The delay is a knob because WHEN the menu opens is the whole
            // question: opened late everything has settled, opened while the
            // row is still hydrating it shows what a fast thumb would see.
            let delay = Self.debugArgumentValue("-maps-subfilter-menu-open-after")
                .flatMap(Double.init) ?? 5.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.subFilterBar.debugPresentMenu(for: .profile(ProfileID(id)))
            }
        }
        // `-maps-tap-subfilter <profileID>`: taps a refinement pill ~6s in,
        // after `-maps-select-subfilter` has had its turn — so the pair shows
        // a selected pill being toggled back off.
        if let id = Self.debugArgumentValue("-maps-tap-subfilter") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.subFilterBar.debugTap(.profile(ProfileID(id)))
            }
        }
        // `-maps-open-subfilter-sheet`: presents the sub-filter full-list
        // sheet ~3s in (the header's organize tap). Pair with
        // `-maps-select-filter friends|following|pinned`.
        if ProcessInfo.processInfo.arguments.contains("-maps-open-subfilter-sheet") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.debugPresentSubFilterSheet()
            }
        }
        // `-maps-pin-favorite <profileID>`: toggles that profile in the
        // pinned-favorites store ~2s in (the long-press menu's mutation,
        // which can't be driven by injected touches). Pair with
        // `-maps-reset-favorites` for deterministic runs.
        if let id = Self.debugArgumentValue("-maps-pin-favorite") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.debugTogglePinnedFavorite(MapFavorite(profileID: ProfileID(id), title: ""))
            }
        }
        // `-maps-select-subfilter <profile:ID|place:token>[,…]`: selects
        // refinement pills ~3s in (after the sub-filter row has loaded).
        // Several comma-separated tokens select several at once — the row and
        // the query then carry their union. Pair with
        // `-maps-select-filter friends|following|pinned`.
        if let tokens = Self.debugArgumentValue("-maps-select-subfilter") {
            let subFilters = Set(tokens.split(separator: ",").compactMap { token -> MapSubFilter? in
                if token.hasPrefix("profile:") {
                    .profile(ProfileID(String(token.dropFirst("profile:".count))))
                } else if token.hasPrefix("place:") {
                    .placeCategory(String(token.dropFirst("place:".count)))
                } else {
                    nil
                }
            })
            if !subFilters.isEmpty {
                // ⚠️ 3 s IS THE EARLIEST, NOT THE PROOF. It keeps this hook's
                // place on the timeline its siblings are laid against
                // (`-maps-tap-subfilter` at 6 s toggles what this selected),
                // but "the row has loaded by then" was a guess: on a slow load
                // the query was filtered while the bar carried no such pill,
                // and the row landing afterwards (`setOptions`) cleared the
                // selection — a filtered map with nothing selected, silently.
                // So it also waits for the bar to actually carry every
                // requested pill, in the row the controller means to show.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    QAWait.until("-maps-select-subfilter \(tokens)", timeout: 20, { [weak self] in
                        guard let self else { return true }
                        let intended = Set(currentSubFilterOptions.map(\.subFilter))
                        return subFilters.allSatisfy {
                            intended.contains($0) && subFilterBar.entity(for: $0) != nil
                        }
                    }) { [weak self] in
                        guard let self else { return }
                        subFilterBar.setSelectedSubFilters(subFilters)
                        viewModel.subFiltersChanged(subFilters)
                    }
                }
            }
        }
    }

    /// `-open-country-shop` / `-offer-country XX` / `-show-country XX`, run
    /// at the end of `configureCountries`.
    func runDebugCountryHooks() {
        // `-open-country-shop` / `-offer-country XX` / `-show-country XX`: the
        // shop, a locked country's offer, or the shop's "go to" — once the map
        // is on screen and the borders are in (a tap the sim can't place).
        let arguments = ProcessInfo.processInfo.arguments
        let code = { (flag: String) in
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        if countryAccess != nil, arguments.contains("-open-country-shop") || code("-offer-country") != nil
            || code("-show-country") != nil {
            QAWait.until("country QA hook", timeout: 20, { [weak self] in
                guard let self else { return true }
                return view.window != nil && countryLayer.hasBorders && presentedViewController == nil
            }) { [weak self] in
                guard let self else { return }
                if let shown = code("-show-country") {
                    debugShowCountry(shown.uppercased())
                } else if let offered = code("-offer-country"), let country = CountryAtlas.shared.country(code: offered) {
                    debugOffer(country)
                } else {
                    presentCountryShop()
                }
            }
        }
    }

    /// `-maps-camera-log`: the settled camera — distance, pitch, how much of
    /// the world's width is on screen, the region MapKit reports (and so the
    /// viewport the query is built from). Pairs with `-maps-zoom-sweep`.
    func logSettledCamera() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-camera-log") else { return }
        let region = mapView.region
        print(String(
            format: "[maps-camera] settled distance=%.0f pitch=%.0f worldFraction=%.3f center=%.2f,%.2f span=%.2fx%.2f",
            mapView.camera.centerCoordinateDistance, mapView.camera.pitch,
            mapView.visibleMapRect.width / MKMapRect.world.width,
            region.center.latitude, region.center.longitude,
            region.span.latitudeDelta, region.span.longitudeDelta
        ))
    }
}

// MARK: - Chrome trace

extension MapsViewController {
    /// `-maps-trace-chrome`: samples the filter bars' window position every frame,
    /// so "do they move during the grab, and do they snap at the end?" is a number
    /// rather than an impression. Same instrument that found both For You defects.
    func installChromeTrace() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-trace-chrome") else { return }
        // Weak-target proxy, not `target: self`: a display link retains its
        // target, so the direct form pinned this controller for the life of
        // the process. The proxy dies with the controller; the link retires
        // itself on the next tick.
        let proxy = MapsChromeTraceProxy(target: self)
        CADisplayLink(target: proxy, selector: #selector(MapsChromeTraceProxy.tick))
            .add(to: .main, forMode: .common)
    }

    @objc fileprivate func sampleChrome() {
        guard let window = view.window else { return }
        let bars = barsStack.convert(barsStack.bounds, to: window)
        print(String(
            format: "[maps:%@] barsY=%.2f barsH=%.2f safeB=%.2f viewT=%@ mapT=%@",
            activeTransition == nil ? "rest" : "flight",
            bars.minY, bars.height, view.safeAreaInsets.bottom,
            NSCoder.string(for: view.transform), NSCoder.string(for: mapView.transform)
        ))
    }
}

/// Weak-target beat for `-maps-trace-chrome` — see `installChromeTrace`.
private final class MapsChromeTraceProxy {
    private weak var target: MapsViewController?
    init(target: MapsViewController) { self.target = target }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else { return link.invalidate() }
        target.sampleChrome()
    }
}

// MARK: - Soak

extension MapsViewController {
    /// Drives one soak cycle when the map is idle and cycles remain.
    ///
    /// Called from the gate's own idle transitions, which is the only honest
    /// "the map is ready again" signal there is — a fixed delay would race the
    /// spring's tail, and this file's history is full of measurements ruined by
    /// exactly that.
    func advanceSoakIfNeeded() {
        guard soakCyclesRemaining > 0 else { return }
        // ⚠️ EVERY UNMET PRECONDITION RETRIES, and it took two goes to get this
        // right. The advance is EDGE-TRIGGERED on the gate, so any condition
        // that is merely not-yet-true at that instant loses the cycle and every
        // cycle after it — silently, because a soak that stops looks exactly
        // like a soak that finished.
        //
        // The first version retried only on an empty annotation list, which was
        // a guess. The trace named the real one: after popping home from the
        // place page the gate opens while the map is still off-window
        // (`window=n annotations=4`), one runloop turn before UIKit reattaches
        // it. Retrying on the conjunction covers both, and whatever the third
        // one turns out to be.
        guard openGate.canOpen, view.window != nil else { return scheduleSoakRetry() }
        // ⚠️ HIERARCHY MARKERS FIRST, and the ordering is the only way to reach
        // the place page at all. That page is carried beneath the feed of a
        // CITY or COUNTRY cluster and nothing else, and it is uncovered by a
        // vertical close — so a soak that takes markers in post-id order can
        // run for eight cycles without ever meeting one, which is what the
        // first three runs did. Post-id order still decides everything after,
        // because MapKit's own annotation order is undefined.
        let ordered = mapView.annotations
            .compactMap { annotation -> (id: String, hierarchy: Bool, value: any MKAnnotation)? in
                if let pin = annotation as? MapAnnotation {
                    (pin.pin.postID.rawValue, false, annotation)
                } else if let cluster = annotation as? MapComputedCluster {
                    (cluster.representative.postID.rawValue, cluster.isHierarchyMarker, annotation)
                } else { nil }
            }
            .sorted { ($0.hierarchy ? 0 : 1, $0.id) < ($1.hierarchy ? 0 : 1, $1.id) }
        // ⚠️ RETRY RATHER THAN DROP. The advance is edge-triggered on the gate,
        // so a map whose annotations have not been re-added yet — which is the
        // ordinary state one runloop turn after popping home — would lose that
        // cycle and every cycle after it, silently. The first place-page soak
        // ran exactly one of its six cycles this way.
        guard !ordered.isEmpty else { return scheduleSoakRetry() }
        let hierarchyCount = ordered.filter(\.hierarchy).count
        let target = (ordered[soakCursor % ordered.count].id,
                      ordered[soakCursor % ordered.count].value)
        soakCursor += 1
        soakCyclesRemaining -= 1
        print("[soak] cycle \(soakCursor) opening \(target.0) of \(ordered.count) markers"
              + " (\(hierarchyCount) hierarchy)")
        // One runloop turn, so this never runs inside the gate's own didSet.
        DispatchQueue.main.async { [weak self] in
            self?.mapView.selectAnnotation(target.1, animated: true)
        }
        soakGeneration += 1
        let generation = soakGeneration
        // ⚠️ A WATCHDOG PER CYCLE, because a soak that hangs reports nothing at
        // all — and "the round trip never came back" is the single most
        // important thing this harness can find. A cycle that has not returned
        // the map to idle by here is named, counted and force-closed, so the
        // run continues and the log says which marker did it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.soakGeneration == generation, !self.openGate.canOpen else { return }
            // ⚠️ RESTING ON THE PLACE PAGE IS NOT BEING STUCK. A vertical close
            // lands there on purpose and the map is one pop away, so the soak
            // pops and carries on. Calling that a hang is how a working route
            // gets reported as a broken one — which is exactly what the first
            // run of this path did, before the landing was even reported.
            let resting = self.openGate.isAtIntermediate
            print("[soak] cycle \(generation) \(resting ? "at the place page" : "STUCK")"
                  + " on \(target.0) — popping home")
            self.navigationController?.popToViewController(self, animated: false)
            self.debugGateAppearedAtRoot()
        }
        // ⚠️ SCHEDULED FROM HERE AND NOT FROM A LANDING CALLBACK, because only
        // ONE of the three routes has one. `onDestinationShown` belongs to the
        // hero's transition controller; a reveal and a plain push have no such
        // hook on this side, and a soak that can only close a hero would stall
        // on the first text marker it met — which is exactly what the first run
        // did.
        //
        // ⚠️ BUT ON THE LANDING, NOT ON A CLOCK. It used to fire at a fixed
        // 2.5 s with no generation check: on a slow simulator the flight had
        // not landed, so the close grabbed a flight still presenting (or found
        // nothing to close), and a close that ran late could hit the NEXT
        // cycle's flight. It now waits for `soakFlightHasLanded` — which reads
        // each route's own landing, see there — and is keyed by this cycle's
        // generation, so a stale close is a no-op. Given up just before the
        // 12 s watchdog, which then names and force-closes the cycle.
        QAWait.until("[soak] close cycle \(generation) on \(target.0)", timeout: 10, { [weak self] in
            guard let self else { return true }
            return soakGeneration != generation || soakFlightHasLanded
        }) { [weak self] in
            guard let self, soakGeneration == generation else { return }
            closeSoakedFeed()
        }
    }

    /// Whether the soak's current flight is on screen and still — the moment a
    /// finger could close it.
    ///
    /// The hero reports its own landing (`onDestinationShown` →
    /// `destinationShown()` → `.open`). The reveal and the plain push have no
    /// landing hook on this side (see `MapOpenGate.appearedAtRoot`: they sit in
    /// `.presenting` for the whole round trip), so for those the landing is
    /// the stack itself: something other than the map on top and no push
    /// transition still running.
    private var soakFlightHasLanded: Bool {
        guard let nav = navigationController,
              nav.transitionCoordinator == nil,
              nav.topViewController !== self else { return false }
        switch openGate.state {
        case .open: return true
        case .presenting(let route): return route != .hero
        case .idle, .dismissing, .intermediate: return false
        }
    }

    /// Re-checks shortly, at most one pending check at a time.
    private func scheduleSoakRetry() {
        guard !soakRetryScheduled else { return }
        soakRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.soakRetryScheduled = false
            self?.advanceSoakIfNeeded()
        }
    }

    /// Closes whatever the soak opened, by the same path a finger would take on
    /// that route.
    ///
    /// The hero gets `debugScriptedGrab` — one release below the threshold and
    /// one above it, so a cycle exercises BOTH dismissal outcomes rather than
    /// only the happy path. The reveal and the plain push have no interactive
    /// script on this side, so they are popped, which is the chevron's own path
    /// through the same animator.
    private func closeSoakedFeed() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-soak") else { return }
        if let transition = activeTransition {
            // ⚠️ ALTERNATING AXES, because the two go to DIFFERENT SCREENS. A
            // horizontal close lands on the marker; a vertical one lands on the
            // place page a hierarchy marker carries beneath its feed — the
            // route that fires `dismissedToIntermediate`, leaves the gate in
            // `.intermediate`, and is then popped home by a second gesture. A
            // soak that only ever closes sideways never reaches it, which is
            // exactly what the first three runs did.
            transition.debugScriptedGrab(axis: soakCursor % 2 == 0 ? .horizontal : .vertical)
        } else if navigationController?.topViewController !== self {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - Marker openers

extension MapsViewController {
    /// `-maps-set-region <lat>,<lng>,<spanDegrees>`, parsed — nil without it.
    /// Read raw rather than through `debugArgumentValue`: a southern or
    /// western framing starts with a minus sign ("-33.4,151.2,40").
    static var debugSetRegion: MKCoordinateRegion? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-maps-set-region"),
              position + 1 < arguments.count else { return nil }
        let parts = arguments[position + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
            span: MKCoordinateSpan(latitudeDelta: parts[2], longitudeDelta: parts[2])
        )
    }

    /// The value following a `-flag value` DEBUG launch argument, read from
    /// the process arguments and NOWHERE else.
    ///
    /// These hooks used to read `UserDefaults.standard.string(forKey:)`, which
    /// is a superset: it resolves the argument domain, but also every
    /// PERSISTED domain. Anything that had ever written `maps-select-filter`
    /// into a simulator's preference store — a stray `defaults write`, a
    /// device-level plist surviving an app reinstall — was then replayed on
    /// EVERY launch, scripting a filter selection with no launch argument
    /// present and leaving the map booted into a filtered state nobody asked
    /// for. Scanning the arguments makes the hooks strictly opt-in per launch,
    /// so the resting default is unfiltered by construction.
    static func debugArgumentValue(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        // A bare flag followed by another flag carries no value.
        guard !value.hasPrefix("-") else { return nil }
        return value
    }

    /// `-maps-open-first-pin`: taps a pin shortly after it appears so the hero
    /// transition into the snap feed can be driven/screenshotted in the sim.
    /// Prefers a video pin when any exists (with `-maps-force-video`), so
    /// live-media flights are exercised deterministically.
    ///
    /// `-maps-open-first-text-pin` picks a TEXT pin instead — the flight whose
    /// card carries the symbol face rather than a cover, which is otherwise
    /// only reachable by finding one of them by hand on the map.
    func debugOpenFirstPinIfRequested(among views: [MKAnnotationView]) {
        let arguments = ProcessInfo.processInfo.arguments
        // `-maps-soak <cycles>`: arm once, then drive from the gate.
        if soakCyclesRemaining == 0, !didDebugOpenPin,
           let index = arguments.firstIndex(of: "-maps-soak"), index + 1 < arguments.count,
           let cycles = Int(arguments[index + 1]), cycles > 0 {
            didDebugOpenPin = true
            soakCyclesRemaining = cycles
            print("[soak] armed for \(cycles) cycles")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.advanceSoakIfNeeded()
            }
            return
        }
        // `-maps-open-post <id>`: open THAT post, not whichever one happens to
        // be first.
        //
        // ⚠️ `-maps-open-first-pin` picks by kind and then by MapKit's
        // annotation order, which is undefined — so two runs open two different
        // posts, and a transition A/B across two builds compares two different
        // flights. Three such comparisons proved nothing before this existed.
        if let index = arguments.firstIndex(of: "-maps-open-post"),
           index + 1 < arguments.count {
            let wanted = arguments[index + 1]
            guard !didDebugOpenPin,
                  views.contains(where: { ($0.annotation as? MapAnnotation)?.pin.postID.rawValue == wanted })
            else { return }
            didDebugOpenPin = true
            debugSelectMarker("-maps-open-post \(wanted)") { annotations in
                annotations.compactMap { $0 as? MapAnnotation }
                    .first { $0.pin.postID.rawValue == wanted }
            }
            return
        }
        // `-maps-open-place-id <placeID>` ("country:kenya", "city:barcelona"):
        // taps the marker that IS that place, cluster or band single alike —
        // the place-page route of one named city or country, where the
        // cluster openers pick by size and never reach a one-post country.
        // Pair with `-maps-set-region` to frame the band it shows at.
        if let wanted = Self.debugArgumentValue("-maps-open-place-id") {
            guard !didDebugOpenPin,
                  views.contains(where: {
                      $0.annotation.flatMap(Self.hierarchyPlace(of:))?.id == wanted
                  })
            else { return }
            didDebugOpenPin = true
            debugSelectMarker("-maps-open-place-id \(wanted)", { annotations in
                annotations.first { Self.hierarchyPlace(of: $0)?.id == wanted }
            }, then: { tapped in
                print("[maps] place tap → \(wanted) posts=\(Self.postIDs(of: tapped).count)"
                    + " cluster=\(tapped is MapComputedCluster)")
            })
            return
        }
        let wantsText = arguments.contains("-maps-open-first-text-pin")
        guard !didDebugOpenPin,
              wantsText || arguments.contains("-maps-open-first-pin") else { return }
        let preferred: MapPin.Kind = wantsText ? .text : .video
        // The same pick at arm time and at fire time: by kind, then any pin
        // (media only). At fire time the post armed on is preferred, so a
        // re-cluster that kept it does not swap the subject under the run.
        let pick: @MainActor ([MapAnnotation]) -> MapAnnotation? = { annotations in
            annotations.first(where: { $0.pin.kind == preferred })
                ?? (wantsText ? nil : annotations.first)
        }
        guard let armed = pick(views.compactMap { $0.annotation as? MapAnnotation }) else { return }
        didDebugOpenPin = true
        let armedID = armed.pin.postID
        debugSelectMarker(wantsText ? "-maps-open-first-text-pin" : "-maps-open-first-pin") { annotations in
            let pins = annotations.compactMap { $0 as? MapAnnotation }
            return pins.first { $0.pin.postID == armedID } ?? pick(pins)
        }
    }

    /// Taps the marker `resolve` picks from the map's CURRENT annotations,
    /// once there is one the map could open.
    ///
    /// ⚠️ RE-RESOLVED AT FIRE TIME, NEVER CAPTURED. The openers used to keep
    /// the annotation `didAdd` handed them and select it a second later. A
    /// query response landing in that second re-clusters the map, the
    /// captured object is no longer in `mapView.annotations`, the select is a
    /// no-op — and the one-shot latch (`didDebugOpenPin`) forbids a retry, so
    /// the run opened nothing and said nothing. This picks again from what is
    /// on the map when it fires (the soak's own rule, `advanceSoakIfNeeded`),
    /// waits for the pick to have a view and the gate to be open, and prints
    /// a GAVE UP line if that never happens.
    ///
    /// The 1 s before the first look is pacing, not a readiness guess: the
    /// marker's pop-in lands before it is tapped, so the flight leaves from a
    /// settled marker rather than one still scaling up.
    private func debugSelectMarker(
        _ label: String,
        _ resolve: @escaping @MainActor ([any MKAnnotation]) -> (any MKAnnotation)?,
        then willSelect: (@MainActor (any MKAnnotation) -> Void)? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Picked among the markers that have a VIEW — what the old
            // `didAdd` batch was, and what a flight can leave from. Resolved
            // in the check and again in the action: the action runs in the
            // same turn the check passed, so both see the same map.
            let shown: @MainActor (MKMapView) -> [any MKAnnotation] = { mapView in
                mapView.annotations.filter { mapView.view(for: $0) != nil }
            }
            QAWait.until(label, timeout: 20, { [weak self] in
                guard let self else { return true }
                guard openGate.canOpen, view.window != nil else { return false }
                return resolve(shown(mapView)) != nil
            }) { [weak self] in
                guard let self, let target = resolve(shown(mapView)) else { return }
                // `-maps-open-delay <ms>`: the map rests that long before the
                // tap — the idle preroll's window, measurable (#654).
                if let delay = Self.debugArgumentValue("-maps-open-delay").flatMap(Double.init), delay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { [weak self] in
                        guard let self, let target = resolve(shown(mapView)) else { return }
                        willSelect?(target)
                        mapView.selectAnnotation(target, animated: true)
                    }
                    return
                }
                willSelect?(target)
                // `-maps-touch-lead <ms>`: a finger rests on the marker that
                // long before the tap — the touch-down warm, measurable (#646).
                if let lead = Self.debugArgumentValue("-maps-touch-lead").flatMap(Double.init),
                   let pin = target as? MapAnnotation {
                    debugBeginPlaybackWarm(for: pin)
                    DispatchQueue.main.asyncAfter(deadline: .now() + lead / 1000) { [weak self] in
                        self?.mapView.selectAnnotation(target, animated: true)
                    }
                    return
                }
                mapView.selectAnnotation(target, animated: true)
            }
        }
    }

    /// `-maps-open-first-cluster`: taps the biggest CLUSTER on screen and
    /// prints what it hands the feed. `-maps-open-first-text-cluster` picks the
    /// biggest cluster wearing the TEXT face instead — the case that answers
    /// "does tapping a text marker open more than one post".
    ///
    /// Clusters exist at the opening zoom now that the mock seeds venues
    /// (`MockGeoDiscoveryService.venueAssignments`); `-maps-wide-region` still
    /// makes the big ones, since a pinch cannot be injected in the sim.
    ///
    /// It prints, because "the whole group opens" is invisible to a screenshot:
    /// the feed's first page looks the same whether it was handed one post or
    /// nine, and the difference only shows up when a finger swipes. The line is
    /// the corpus the tap actually passed on.
    func debugOpenFirstClusterIfRequested(among views: [MKAnnotationView]) {
        let arguments = ProcessInfo.processInfo.arguments
        let wantsText = arguments.contains("-maps-open-first-text-cluster")
        // `-maps-open-first-media-cluster`: the biggest MEDIA-faced cluster —
        // the hero-presented kind, which is also what the semantic-cluster
        // gallery flow rides (places seed by default in mock mode).
        let wantsMedia = arguments.contains("-maps-open-first-media-cluster")
        guard !didDebugOpenPin,
              wantsText || wantsMedia || arguments.contains("-maps-open-first-cluster")
        else { return }
        // `-maps-open-place` only has an answer on a HIERARCHY marker: a city or
        // a country is a place before it is a photograph, and only those carry a
        // place page beneath their feed. Asking for the biggest cluster of any
        // kind picked a proximity one, whose `placePage` is nil — and the flag
        // then did nothing at all, silently.
        // `-maps-open-hierarchy-cluster` asks for the same marker WITHOUT the
        // direct push, so a run can take the real route: tap a city, get the
        // feed, and dismiss vertically onto the place page beneath. That
        // dismissal is the one landing this page has that nothing else
        // exercises — and a vertical drag on a TEXT post opens its comments
        // instead, which is why the media filter matters here too.
        let wantsPlace = arguments.contains("-maps-open-place")
            || arguments.contains("-maps-open-hierarchy-cluster")
        // The same pick at arm time (this batch) and at fire time (the whole
        // map, see `debugSelectMarker`).
        let pick: @MainActor ([MapComputedCluster]) -> MapComputedCluster? = { candidates in
            candidates
                .filter {
                    $0.memberIDs.count > 1
                        && (!wantsText || $0.representative.isText)
                        && (!wantsMedia || !$0.representative.isText)
                        && (!wantsPlace || $0.isHierarchyMarker)
                }
                .max(by: { $0.memberIDs.count < $1.memberIDs.count })
        }
        guard let cluster = pick(views.compactMap { $0.annotation as? MapComputedCluster })
        else {
            if wantsPlace {
                print("[maps] -maps-open-place found NO hierarchy marker on screen"
                    + " — pass -maps-mock-semantic-clusters, and a region wide"
                    + " enough for a city or country to form")
            }
            return
        }
        didDebugOpenPin = true
        // The marker armed on is preferred while it is still on the map
        // (clusters keep their identity through representative churn); a
        // re-cluster that retired it gets the same pick over what is there.
        // The line is printed at FIRE time, from the cluster actually tapped,
        // so it stays "the corpus the tap passed on" even after a re-cluster.
        debugSelectMarker("-maps-open-first-cluster", { annotations in
            let clusters = annotations.compactMap { $0 as? MapComputedCluster }
            return clusters.first { $0 === cluster } ?? pick(clusters)
        }, then: { tapped in
            guard let cluster = tapped as? MapComputedCluster else { return }
            let ids = Self.postIDs(of: cluster)
            let kind = cluster.representative.isText ? "text" : "media"
            print("[maps] cluster tap → representative=\(cluster.representative.postID.rawValue) "
                + "(\(kind), \(MapMarkerPresentation(face: Self.face(of: cluster)))) "
                + "opening \(ids.count) posts: \(ids.map(\.rawValue).joined(separator: ","))")
        })
    }

    /// `-text-swipe-demo`: drives the armed close from a script.
    func debugScriptCardCloseIfRequested(_ slide: InteractiveSlideDismissal) {
        // `-text-swipe-demo <peak>` (+ `-zoom-demo-grab-vertical` for the
        // axis): the same script the reveal path honours, on the driver that
        // is otherwise unreachable — this grab only exists for a post the
        // viewer has PAGED to, and the simulator injects neither the paging
        // nor the drag. Pair with `-snap-start-index N` to settle on a text
        // page first.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-text-swipe-demo"),
           position + 1 < arguments.count,
           let peak = Double(arguments[position + 1]) {
            let axis: ZoomDismissAxis = arguments.contains("-zoom-demo-grab-vertical")
                ? .vertical : .horizontal
            Task { @MainActor [weak slide] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let driven = await slide?.debugPerformSwipe(
                    peakProgress: CGFloat(peak), axis: axis
                )
                print("[card-close] peak=\(peak) axis=\(axis) driven=\(driven ?? false)")
                // `-text-swipe-demo-again <peak>`: a SECOND attempt, 2s after
                // the first — the cancel-then-close-again route. A first peak
                // under the release threshold springs back; this is the close
                // that follows it on the same driver.
                guard let again = arguments.firstIndex(of: "-text-swipe-demo-again"),
                      again + 1 < arguments.count,
                      let secondPeak = Double(arguments[again + 1]) else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let drivenAgain = await slide?.debugPerformSwipe(
                    peakProgress: CGFloat(secondPeak), axis: axis
                )
                print("[card-close] again peak=\(secondPeak) axis=\(axis) driven=\(drivenAgain ?? false)")
            }
        }
    }
}

// MARK: - Sweeps and the icon HUD

extension MapsViewController {
    /// `-maps-nav-drag`: step the camera in many small NON-animated increments,
    /// the way a finger does.
    ///
    /// `-maps-nav-sweep` uses `setRegion(animated: true)`, which fires
    /// `regionDidChangeAnimated` exactly ONCE per gesture — so it measured a
    /// world in which reconcile bursts cannot happen, and reported no duplicate
    /// reconciles because the workload could not produce one. A real pan fires
    /// the delegate on every step. Whether coalescing is worth anything is a
    /// question only this driver can answer.
    func installNavigationDrag() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-nav-drag") else { return }
        // Around `-maps-set-region`'s framing when one is given: panning a
        // continent of country markers is not the workload panning Paris is.
        let home = Self.debugSetRegion ?? Self.defaultRegion
        var step = 0
        // 60 Hz stepping: one region change per display frame, which is the
        // upper bound of what a finger can generate.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A slow lissajous over the seeded region: never repeats a frame,
            // never leaves the corpus, and keeps the span fixed so this measures
            // PAN only — zoom changes the marker population and would confound
            // the reconcile count with realisation work.
            // ⚠️ BURSTS, NOT A PERPETUAL PAN. A finger moves and then stops;
            // this driver did not, and `scheduleQuery`'s cancel-and-reschedule
            // debounce (by design: do not query while the camera is moving)
            // therefore never fired, so the map held ZERO markers and every
            // performance column looked excellent. Worse, the effect appeared
            // only once the reconcile throttle had made the settles cheap
            // enough to sustain 60 Hz from launch — the optimisation was fast
            // enough to starve the app's own query. 1.0s of motion, 0.5s still.
            let cycle = Double(step) / 60.0
            if cycle.truncatingRemainder(dividingBy: 1.5) >= 1.0 { step += 1; return }
            let t = Double(step) / 60.0
            step += 1
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: home.center.latitude + 0.22 * home.span.latitudeDelta * sin(t * 0.9),
                    longitude: home.center.longitude + 0.22 * home.span.longitudeDelta * sin(t * 1.4)
                ),
                span: home.span
            )
            self.mapView.setRegion(region, animated: false)
        }
    }

    /// `-maps-zoom-sweep`: zooms the camera from a city out to the widest
    /// view MapKit allows and back in, one animated step every 2.5s, each
    /// step a settle — the path a pinch takes, filmable in the sim where a
    /// pinch cannot be injected. Every settle runs the clustering, the query
    /// and the country badges at that distance.
    ///
    /// 40 000 km is past the standard map's ~26 300 km clamp on purpose: the
    /// step asks for more than MapKit gives, as a finger pinching out keeps
    /// doing. At the widest view the camera also crosses to the Pacific and
    /// back — a viewport across the antimeridian (`MapViewport.make`).
    func installZoomSweep() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-zoom-sweep") else { return }
        // `.stay` keeps the camera where it is; `.home` is where it was at
        // the first step (read then: this runs before the opening region).
        enum Centre { case stay, pacific, home }
        let steps: [(distance: CLLocationDistance, centre: Centre)] = [
            (300_000, .stay), (3_000_000, .stay), (14_000_000, .stay), (25_000_000, .stay),
            (40_000_000, .stay), (40_000_000, .pacific), (40_000_000, .home),
            (10_000_000, .stay), (3_000_000, .stay), (300_000, .stay),
        ]
        var step = 0
        var home: CLLocationCoordinate2D?
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] timer in
            guard let self, step < steps.count else { timer.invalidate(); return }
            let camera = self.mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
            if home == nil { home = camera.centerCoordinate }
            camera.centerCoordinateDistance = steps[step].distance
            switch steps[step].centre {
            case .stay: break
            case .pacific: camera.centerCoordinate = CLLocationCoordinate2D(latitude: -17, longitude: 179)
            case .home: if let home { camera.centerCoordinate = home }
            }
            print(String(
                format: "[maps-camera] sweep step %d -> %.0f at %.2f,%.2f", step, steps[step].distance,
                camera.centerCoordinate.latitude, camera.centerCoordinate.longitude
            ))
            step += 1
            self.mapView.setCamera(camera, animated: true)
        }
    }

    /// `-maps-nav-sweep`: pan and zoom the map on a fixed schedule, forever.
    ///
    /// The static field is the EASY case. Every earlier measurement on this
    /// feature said the same thing — animation is nearly free and navigation is
    /// what costs, because a pan re-runs clustering, re-reconciles annotations,
    /// and re-attaches artwork to recycled views. Reporting "144 markers at
    /// 16.67 ms" while the map sat still would be reporting the wrong number.
    ///
    /// Scripted rather than driven by injected gestures: CGEvent swipes land on
    /// whichever window is frontmost and vanish silently when one overlaps, so
    /// a flaky driver would show up as a performance result.
    func installNavigationSweep() {
        guard ProcessInfo.processInfo.arguments.contains("-maps-nav-sweep") else { return }
        let home = Self.defaultRegion
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            // A six-phase cycle: four pans around the seeded region, then a zoom
            // in and back out. Zoom is included because it changes the marker
            // POPULATION, which is the expensive half — a pure pan only moves
            // views that already exist.
            let dLat = home.span.latitudeDelta, dLon = home.span.longitudeDelta
            let offsets: [(Double, Double, Double)] = [
                (0.30, 0, 1), (0, 0.30, 1), (-0.30, 0, 1),
                (0, -0.30, 1), (0, 0, 0.45), (0, 0, 1)
            ]
            let (oLat, oLon, zoom) = offsets[step % offsets.count]
            step += 1
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: home.center.latitude + oLat * dLat,
                    longitude: home.center.longitude + oLon * dLon
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: dLat * zoom, longitudeDelta: dLon * zoom
                )
            )
            self.mapView.setRegion(region, animated: true)
        }
    }

    /// The animated-icon instrument, over the real map — `-map-icon-hud`.
    ///
    /// It replaces the standalone bench screen, and the swap is the point: a
    /// synthetic lattice could not tell you what MapKit, clustering, tile
    /// loading and the app's own working set cost around the feature. Only the
    /// shipping screen can.
    func installIconDebugHUD() {
        // `-map-icon-policy full|reduced|still` pins the motion state from
        // launch. Read even without the HUD: an A/B that depends on tapping a
        // control is an A/B whose two arms were run by hand, and the arm you
        // tapped second is the one whose viewport had already drifted.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-map-icon-policy"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let policy = AnimatedIconView.MotionPolicy(
               rawValue: ProcessInfo.processInfo.arguments[index + 1]
           ) {
            AnimatedIconView.forcedPolicy = policy
        }
        guard ProcessInfo.processInfo.arguments.contains("-map-icon-hud") else { return }
        let hud = MapIconDebugHUD(
            mapView: mapView, catalog: iconCatalog as? AnimatedIconCatalog, previews: previewCatalog, pool: videoPool
        )
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.onPolicyChange = { [weak self] in
            guard let self else { return }
            for annotation in self.mapView.annotations {
                (self.mapView.view(for: annotation) as? MapAnnotationView)?.redressIcon()
                (self.mapView.view(for: annotation) as? MapClusterAnnotationView)?.redressIcon()
            }
        }
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
        iconDebugHUD = hud
        hud.start()
    }
}

// MARK: - Arrival invariants

extension MapsViewController: ArrivalInvariantReporting {
    /// Back on the map, no flight is held and no marker is still concealed.
    public func arrivalFacts() -> [(name: String, holds: Bool)] {
        let hidden = mapView.annotations.compactMap { mapView.view(for: $0) }.filter(\.isHidden).count
        return [
            ("maps.activeTransition", activeTransition == nil),
            ("maps.hiddenMarkers=\(hidden)", hidden == 0),
        ]
    }
}
#endif
