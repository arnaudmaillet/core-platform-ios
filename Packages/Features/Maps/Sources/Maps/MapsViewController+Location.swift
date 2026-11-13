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

// Location, guest mode §3.1 (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Location (guest mode §3.1)

    /// The card while nothing is open and location isn't allowed — the one
    /// thing that would open a country; the locate button otherwise.
    func updateLocationControls() {
        locationControls.apply(Self.locationControlsFace(
            permission: locator?.permission, guestLocked: isGuestLocked,
            hasNoOpenCountry: countryAccess?.hasNoOpenCountry
        ))
    }

    /// The controls' face. The guest without location's way out is the bar's
    /// "Allow location" now (#1907, `GuestLocationOffering`): no card for
    /// them; a member with no open country keeps it. Pure, for tests.
    static func locationControlsFace(
        permission: LocationPermission?, guestLocked: Bool, hasNoOpenCountry: Bool?
    ) -> MapLocationControlsView.Face {
        guard let permission, !guestLocked, let hasNoOpenCountry else { return .none }
        return hasNoOpenCountry && permission != .allowed ? .card(permission) : .button(permission)
    }

    /// Asks in context — the only place location is ever asked for — or, once
    /// denied, sends the person to Settings, the only place it can change.
    func locationControlTapped(_ permission: LocationPermission) {
        switch permission {
        case .denied:
            guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settings)
        case .notAsked:
            fliesToCurrentCountry = true
            locator?.requestPermission()
        case .allowed:
            if let code = locator?.currentCountry {
                showCountry(code)
            } else {
                // No fix yet (#1775): the button waits with the loader until
                // the country is known, and says so if it never is.
                fliesToCurrentCountry = true
                waitForFix()
            }
            locator?.requestPermission()
        }
    }

    /// Whether a viewer sees the locked guest showcase: a guest whose location
    /// is not allowed. Members are never locked, and neither is a map with no
    /// locator (`permission` nil): without the card there would be no way out.
    /// Pure, for tests.
    static func guestLocationLocked(isMember: Bool, permission: LocationPermission?) -> Bool {
        guard !isMember, let permission else { return false }
        return permission != .allowed
    }

    /// The map's interaction: only an open transition makes it inert. The
    /// guest without location moves it too since #1907, within the country
    /// band (`MapDepthClamp`). Pure, for tests.
    static func mapIsInteractive(inert: Bool, guestLocked: Bool) -> Bool {
        !inert
    }

    /// Re-reads the lock and applies it: the veil, the world view, the map's
    /// interaction, the pills and the compass. Unlocking fades the veil out
    /// and flies to the current country once it is known.
    func updateGuestLock(animated: Bool) {
        let locked = Self.guestLocationLocked(isMember: isMember(), permission: locator?.permission)
        // The ceiling, whatever else changed (#1907): a guest without location
        // roams the world at country level; everyone else is unlocked.
        depthClamp.ceiling = locked ? .country : .unlocked
        guard locked != isGuestLocked else { return }
        let wasLocked = isGuestLocked
        isGuestLocked = locked
        applyMapInteraction()
        // The guest moves the map now (#1907): the compass follows it.
        mapView.showsCompass = true
        // They filter posts the guest cannot see.
        filterBar.isHidden = locked
        updateTextBubble(animated: view.window != nil)
        if locked {
            subFilterBar.isHidden = true
            pendingQuery?.cancel()
            needsWorldView = true
            frameWorldIfNeeded()
        }
        updateLocationControls()
        onGuestLocationOfferChange?(locked)
        guard wasLocked, !locked else { return }
        // Unlocked: to the viewer's country, as the card promised.
        if let code = locator?.currentCountry {
            fliesToCurrentCountry = false
            showCountry(code)
        } else {
            fliesToCurrentCountry = true
            scheduleQuery()
        }
    }

    /// The whole world, without animation — on the first frame, so a locked
    /// map never flashes Paris first.
    func frameWorldIfNeeded() {
        guard needsWorldView, isGuestLocked, mapView.bounds.width > 0 else { return }
        needsWorldView = false
        mapView.setVisibleMapRect(.world, animated: false)
    }

    @objc func currentCountryChanged() {
        updateGuestLock(animated: true)
        updateLocationControls()
        // The country left behind closes again (decision 10): it no longer
        // stands selected as if it were open — unless its offer is up.
        if let selected = countryLayer.selectedCode, selected != locator?.currentCountry,
           countryAccess?.isUnlocked(selected) == false, presentedViewController == nil {
            countryLayer.select(nil)
        }
        guard fliesToCurrentCountry, let code = locator?.currentCountry else { return }
        fliesToCurrentCountry = false
        locationControls.setLocating(false)
        showCountry(code)
    }

    /// The locate button waits for the first fix; past `takingLonger` the
    /// wait ends and the viewer is told (the controls' `LoadingClock`).
    private func waitForFix() {
        locationControls.setLocating(true) { [weak self] in
            guard let self else { return }
            fliesToCurrentCountry = false
            Feedback.failure(Self.noFixMessage, from: self)
        }
    }

    static let noFixMessage = "Couldn't find where you are. Try again."


    /// Whether `pin`'s post is OPEN to the viewer: its country is unlocked (or
    /// there is nothing locked at all). A pin just offshore is its coast's
    /// (`CountryAtlas.country(owning:)`); one on the open sea is open.
    ///
    /// A post in a locked country is still on the map — its country's markers
    /// wear its busiest posts, darkened under a lock — but it never opens.
    func isInUnlockedCountry(_ pin: MapPin) -> Bool {
        guard let countryAccess else { return true }
        let code = countryCode(of: pin)
        return code.isEmpty || countryAccess.isUnlocked(code)
    }

    /// The country `pin`'s post stands in (ISO alpha-2), "" at sea. Cached per
    /// post: the point-in-polygon walk is the expensive half of the question,
    /// and a reconcile asks it of every pin.
    func countryCode(of pin: MapPin) -> String {
        if let cached = pinCountries[pin.postID] { return cached }
        let coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        let code = CountryAtlas.shared.country(owning: coordinate)?.code ?? ""
        pinCountries[pin.postID] = code
        return code
    }

    /// The country `annotation`'s marker speaks for (ISO alpha-2, "" at sea):
    /// its REPRESENTATIVE's — a city's is its country's, as its flag border.
    func countryCode(of annotation: any MKAnnotation) -> String {
        let cluster = annotation as? MapComputedCluster
        guard let pin = cluster?.representative ?? (annotation as? MapAnnotation)?.pin else { return "" }
        return countryCode(of: pin)
    }

    /// What `annotation`'s marker wears around its face: the flag border and
    /// badge of the place it speaks for, and the lock of a locked country —
    /// see `MapMarkerDress`. The country is the REPRESENTATIVE's: a city's
    /// border wears its country's flag, and every member of a locked marker is
    /// locked (`reconcileClusters` never lays out open and locked posts
    /// together).
    func dress(for annotation: any MKAnnotation) -> MapMarkerDress {
        let cluster = annotation as? MapComputedCluster
        guard let pin = cluster?.representative ?? (annotation as? MapAnnotation)?.pin else { return .neutral }
        let code = countryCode(of: pin)
        return MapMarkerDress.resolve(
            kind: Self.dressKind(of: annotation),
            countryCode: code,
            isLocked: !isInUnlockedCountry(pin)
        )
    }

    /// The hierarchy depth `annotation`'s dress speaks for, or nil for a
    /// local marker. A band's group of one (a lone `MapAnnotation`) speaks
    /// for its place exactly like a band cluster: at a band, every marker
    /// wears a place's dress — at the country band only countries, at the
    /// city band only cities.
    static func dressKind(of annotation: any MKAnnotation) -> MapPlace.Kind? {
        hierarchyPlace(of: annotation)?.kind
    }

    /// The city or country `annotation`'s marker IS, or nil for a local one —
    /// the ONE answer both presentations (`openAnnotation`'s reveal and
    /// `presentSnapFeed`'s hero) and the dress ask, so "does this marker have
    /// a place page" and "does it wear a place's dress" can never disagree.
    ///
    /// ⚠️ A BAND'S GROUP OF ONE COUNTS. Both routes used to ask
    /// `annotation as? MapComputedCluster` alone, so a country or city with a
    /// single post in view — dressed as its place, the mock world's ninety-four
    /// one-post countries among them — opened as a plain pin, and its vertical
    /// dismissal landed on the map where Paris's lands on its page.
    static func hierarchyPlace(of annotation: any MKAnnotation) -> MapPlace? {
        switch annotation {
        case let cluster as MapComputedCluster: cluster.hierarchyPlace
        case let single as MapAnnotation: single.hierarchyPlace
        default: nil
        }
    }

    /// What a tap on a marker does: open its posts, or — for a locked
    /// country's — offer the country. Pure, so the routing is pinned without
    /// a live map.
    enum MarkerTap: Equatable {
        case open
        case offer(countryCode: String)
    }

    static func markerTap(for dress: MapMarkerDress, countryCode: String) -> MarkerTap {
        dress.isLocked && !countryCode.isEmpty ? .offer(countryCode: countryCode) : .open
    }

    func configureFilterBar() {
        barsStack.axis = .vertical
        barsStack.spacing = Spacing.xs
        barsStack.clipsToBounds = false
        view.addSubview(barsStack)
        barsStack.translatesAutoresizingMaskIntoConstraints = false
        // Pinned to the view's RAW bottom with a constant this screen owns, not to
        // `safeAreaLayoutGuide.bottomAnchor`. The safe area animates through a pop
        // — measured here climbing 34 -> 64 -> 76.33 before settling at 83 — and
        // anything tied to it rides that animation and then corrects, which showed
        // up as the bars landing at 741.67 and snapping to 735.00. `syncBarsPosition`
        // tracks the safe area only while nothing is flying, so the constant in
        // force during a gesture is always a resting measurement. The resting
        // geometry is unchanged: the safe-area bottom still sits above the floating
        // tab bar, which is what rests the pills directly over it.
        barsBottomConstraint = barsStack.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -Spacing.sm
        )
        NSLayoutConstraint.activate([
            barsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barsBottomConstraint,
            subFilterBar.heightAnchor.constraint(equalToConstant: MapSubFilterBarView.barHeight),
            filterBar.heightAnchor.constraint(equalToConstant: MapFilterBarView.barHeight)
        ])
        barsStack.addArrangedSubview(locationControls)
        barsStack.addArrangedSubview(subFilterBar)
        barsStack.addArrangedSubview(filterBar)
        locationControls.onTap = { [weak self] permission in self?.locationControlTapped(permission) }
        // Resting state: no refinement row until a primary that has one.
        subFilterBar.isHidden = true
        subFilterBar.alpha = 0

        filterBar.onFilterChanged = { [weak self] filter in
            self?.viewModel.filterChanged(filter)
            self?.updateSubFilterBar(for: filter)
        }
        subFilterBar.imagePipeline = imagePipeline
        subFilterBar.onSubFiltersChanged = { [weak self] subFilters in
            self?.viewModel.subFiltersChanged(subFilters)
        }
        subFilterBar.onExpandTapped = { [weak self] in
            self?.presentSubFilterSheet()
        }
        // The pill long-press menu. Every destination is resolved here — the
        // bar reports which verb was chosen and knows nothing beyond that.
        subFilterBar.onViewProfile = { [weak self] favorite in
            self?.openProfile(favorite)
        }
        // The thread opens titled with the favourite (#1860), as its profile
        // does with its stub.
        subFilterBar.onSendMessage = { [weak self] favorite in
            self?.openConversation(favorite.profileID, Self.stub(of: favorite))
        }
        subFilterBar.isMuted = { [weak self] profileID in
            self?.subFilterMemory.isMuted(profileID) ?? false
        }
        subFilterBar.onToggleMute = { [weak self] favorite in
            self?.subFilterMemory.toggleMute(favorite.profileID)
        }
        subFilterBar.onViewDetails = { [weak self] category in
            self?.isolateSubFilter(.placeCategory(category))
        }
        subFilterBar.onShare = { [weak self] option in
            self?.presentShareSheet(for: option)
        }
        subFilterBar.onUnpinSubFilter = { [weak self] subFilter in
            self?.removeSubFilterFromRow(subFilter)
        }
    }
}
