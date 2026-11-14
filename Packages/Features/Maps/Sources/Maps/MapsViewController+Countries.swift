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

// Countries (#2388, out of the map's file)
extension MapsViewController {
    // MARK: - Countries

    /// The world's borders, and picking a LOCKED country: a tap lifts it at
    /// once, then the map flies to it and its offer rises. An unlocked
    /// country does nothing under a tap — the map stays the map.
    func configureCountries() {
        countryLayer.access = countryAccess
        countryLayer.onMapTapped = { [weak self] country in self?.mapTapped(country) }
        countryLayer.onTouchDown = { [weak self] in self?.cancelPendingOffer() }
        countryLayer.onMapGesture = { [weak self] in self?.mapMovedByUser() }
        countryLayer.onLockedCountryTapped = { [weak self] country in self?.offer(country) }
        countryLayer.onCountryTapped = { [weak self] country in self?.showCountry(country.code) }
        countryLayer.install(on: mapView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(countryAccessChanged), name: .countryAccessDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(currentCountryChanged), name: .currentCountryDidChange, object: nil
        )
        updateGuestLock(animated: false)
        updateLocationControls()
        #if DEBUG
        runDebugCountryHooks()
        #endif
    }

    /// The Shop, PUSHED over the map — the QA hooks' way in since the
    /// Explore header lost its storefront (#1494): the Rewards sheet's Shop
    /// tile and the stake menu are the Shop's doors. A row takes you to its
    /// country: back to the map, then there.
    func presentCountryShop() {
        guard let countryAccess, presentedViewController == nil, let navigationController,
              navigationController.topViewController === self, transitionCoordinator == nil else { return }
        let media = ShopMedia(images: imagePipeline, videos: videoPool)
        let shop = CountryShopViewController.storefront(
            access: countryAccess, stakePacks: stakePacks, profileItems: profileItems, media: media
        ) {
            [weak self] code in
            guard let self, let navigationController = self.navigationController else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in self?.showCountry(code) }
            navigationController.popToViewController(self, animated: true)
            CATransaction.commit()
        }
        navigationController.pushViewController(shop, animated: true)
    }

    #if DEBUG
    /// `-maps-offer-country <CC>` (#1600): a country's offer, as the shop opens
    /// it — once, a beat after the map first appears.
    func debugOfferCountryIfRequested() {
        guard !didDebugOfferCountry, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-maps-offer-country"),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return }
        didDebugOfferCountry = true
        let code = ProcessInfo.processInfo.arguments[index + 1].uppercased()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showCountry(code) }
    }
    #endif

    /// Goes to a country from the shop: lifted and framed, and a locked one
    /// makes its offer (framed above the sheet).
    func showCountry(_ code: String) {
        guard let country = CountryAtlas.shared.country(code: code) else { return }
        if let countryAccess, !countryAccess.isUnlocked(code) {
            offer(country)
            return
        }
        countryLayer.select(code)
        frame(country, bottomInset: 0)
    }

    /// Frames a country's mainland in the part of the map left visible
    /// between the header and `bottomInset` from the bottom.
    private func frame(_ country: CountryAtlas.Country, bottomInset: CGFloat) {
        let box = country.mainlandBounds
        let corner = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon))
        let opposite = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon))
        let rect = MKMapRect(
            x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
            width: abs(opposite.x - corner.x), height: abs(opposite.y - corner.y)
        )
        let insets = UIEdgeInsets(
            top: view.safeAreaInsets.top + Spacing.xxl, left: Spacing.xxl,
            bottom: max(bottomInset, view.safeAreaInsets.bottom) + Spacing.xl, right: Spacing.xxl
        )
        // ⚠️ NOT `setVisibleMapRect(_:edgePadding:)`: with the sheet's tall
        // bottom padding it zoomed out ~3.7x too far (Spain above its offer
        // came out a third of the band it was given). The visible rect is
        // worked out here instead: the scale that fits the country in the
        // band, and the band's centre on the country's.
        let size = mapView.bounds.size
        let band = CGSize(
            width: max(size.width - insets.left - insets.right, 1),
            height: max(size.height - insets.top - insets.bottom, 1)
        )
        let scale = max(rect.width / band.width, rect.height / band.height)
        let visible = MKMapRect(
            x: rect.midX - (insets.left + band.width / 2) * scale,
            y: rect.midY - (insets.top + band.height / 2) * scale,
            width: size.width * scale, height: size.height * scale
        )
        mapView.setVisibleMapRect(visible, animated: true)
    }

    /// A tap on the map, not on a marker.
    ///
    /// - With an offer open, the tap closes it and the map goes back to where
    ///   it was: tapping away is "no thanks".
    /// - On a locked country: it lifts NOW, like a marker's selection, and the
    ///   flight and the offer follow `offerDelay` later unless another finger
    ///   lands first (`cancelPendingOffer`): the second tap of a double-tap
    ///   zoom, or the start of a pan, undoes the pick.
    /// - Anywhere else: whatever is lifted lowers.
    private func mapTapped(_ country: CountryAtlas.Country?) {
        if offerSheet != nil {
            closeOffer(returning: true)
            return
        }
        guard let country, let countryAccess, !countryAccess.isUnlocked(country.code) else {
            countryLayer.select(nil)
            return
        }
        countryLayer.select(country.code)
        let pending = DispatchWorkItem { [weak self] in
            self?.pendingOffer = nil
            self?.offer(country)
        }
        pendingOffer = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offerDelay, execute: pending)
    }

    /// Long enough for a double tap's second touch to land, short enough to
    /// read as one gesture: the lift is instant, the flight follows.
    private static let offerDelay: TimeInterval = 0.3

    /// A finger landed while a pick waited for its flight: it was the start
    /// of something else (a double-tap zoom, a pan). The pick is undone.
    private func cancelPendingOffer() {
        guard let pendingOffer else { return }
        pendingOffer.cancel()
        self.pendingOffer = nil
        countryLayer.select(nil)
    }

    /// The user moved the map. A waiting pick is dropped, and an open offer
    /// closes WHERE THE USER TOOK THE MAP: no flight back to the camera it
    /// left from, since the user has just chosen another place to look.
    private func mapMovedByUser() {
        cancelPendingOffer()
        if offerSheet != nil { closeOffer(returning: false) }
    }

    /// Lifts a locked country, flies the map to it above its sheet, and
    /// presents what unlocking it would open. The camera it left from is kept:
    /// closing the offer flies back to it.
    func offer(_ country: CountryAtlas.Country) {
        // ⚠️ FROM ONE LOCKED COUNTRY STRAIGHT TO ANOTHER (#760): the open
        // offer takes the new country in place — outline, camera, sheet — and
        // the camera it left from stays the first one's, so closing returns
        // home. It used to bail here, and MapKit's own selection then closed
        // the first offer: the second tap only reached neutral.
        if let open = offerSheet, !open.isLeaving {
            switchOffer(open, to: country)
            return
        }
        guard let countryAccess, presentedViewController == nil else { return }
        offerState.opening(from: { mapView.camera.copy() as? MKMapCamera })
        countryLayer.select(country.code)
        let sheet = CountryUnlockSheetViewController(country: country, access: countryAccess)
        // Wrapped BEFORE its view loads: the measure counts its toolbar.
        let presented = sheet.wrappedInSheet()
        // The country being sold stands ABOVE the sheet, not under it.
        sheet.loadViewIfNeeded()
        frame(country, bottomInset: offerBottomInset(sheet))
        bindOffer(sheet)
        offerSheet = sheet
        present(presented, animated: true)
    }

    /// The open offer's callbacks, for the country it shows NOW — read off
    /// the sheet, so a switch (`switchOffer`) never leaves them on the first.
    private func bindOffer(_ sheet: CountryUnlockSheetViewController) {
        sheet.onClosing = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerClosing(sheet.country)
        }
        sheet.onCloseCancelled = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerCloseCancelled(sheet.country, sheet: sheet)
        }
        sheet.onDismissed = { [weak self, weak sheet] in
            guard let sheet else { return }
            self?.offerDidClose(sheet.country)
        }
    }

    /// The open offer moves to `country` without closing (#760).
    private func switchOffer(_ sheet: CountryUnlockSheetViewController, to country: CountryAtlas.Country) {
        guard country.code != sheet.country.code else { return }
        #if DEBUG
        OfferLog.note("switch \(sheet.country.code) -> \(country.code)")
        #endif
        countryLayer.select(country.code)
        sheet.show(country)
        frame(country, bottomInset: offerBottomInset(sheet))
    }

    /// The band left above an offer's sheet, where its country is framed.
    private func offerBottomInset(_ sheet: CountryUnlockSheetViewController) -> CGFloat {
        sheet.sheetHeight + view.safeAreaInsets.bottom
    }

    /// Closes the open offer. `returning`: whether the map flies back to the
    /// camera it had before the offer.
    func closeOffer(returning: Bool) {
        // Already on its way down (and the map already on its way back): a
        // tap or a pan now is the user's, not a second close.
        guard let offerSheet, !offerSheet.isLeaving else { return }
        offerState.closeRequested(returning: returning)
        #if DEBUG
        OfferLog.note("close requested returning=\(returning)")
        #endif
        offerSheet.closePresentation()
    }

    /// The offer is closing — by a tap or a pan on the map, a swipe on its
    /// sheet, or an unlock — and the sheet has only just started down
    /// (`OfferCloseFlight`): what the map does runs alongside it.
    ///
    /// - Unlocked: nothing yet. The map stays on the country, whose posts are
    ///   the reward (`offerDidClose`).
    /// - Otherwise the country lowers, and the map flies back to where it was
    ///   (unless the user moved it away from the offer themselves).
    private func offerClosing(_ country: CountryAtlas.Country) {
        guard !(countryAccess?.isUnlocked(country.code) ?? false) else { return }
        countryLayer.select(nil)
        let home = offerState.closing()
        #if DEBUG
        OfferLog.note("closing: flying back=\(home != nil)")
        #endif
        guard let home else { return }
        mapView.setCamera(home, animated: true)
    }

    /// A close went out and the sheet came back up (`OfferCloseFlight`):
    /// the country lifts again, framed above it if the map had left.
    private func offerCloseCancelled(_ country: CountryAtlas.Country, sheet: CountryUnlockSheetViewController) {
        let reframes = offerState.closeCancelled()
        #if DEBUG
        OfferLog.note("close cancelled: reframing=\(reframes)")
        #endif
        countryLayer.select(country.code)
        if reframes { frame(country, bottomInset: offerBottomInset(sheet)) }
    }

    /// The offer is gone. Whatever the map does about it began at
    /// `offerClosing`; an unlocked country's lift fades once its posts have
    /// had a moment on screen.
    private func offerDidClose(_ country: CountryAtlas.Country) {
        offerSheet = nil
        offerState.closed()
        guard countryAccess?.isUnlocked(country.code) ?? false else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.countryLayer.selectedCode == country.code else { return }
            self?.countryLayer.select(nil)
        }
    }

    @objc private func countryAccessChanged() {
        countryLayer.refreshStyles()
        reconcileClusters()
        updateLocationControls()
    }
}
