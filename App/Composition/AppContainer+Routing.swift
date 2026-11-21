import ChatInterface
import CoreModels
#if MOCK_BACKEND
import CoreNetworkingMocks
#endif
import CoreStorage
import FeedInterface
import Foundation
import Maps
import PlaceInterface
import ProfileInterface
import SearchInterface
import SettingsInterface
import UIKit
import UploadInterface
import Wallet

// Routing (#2375): the route resolver. Its properties are declared in
// `AppContainer.swift`, since an extension holds no stored property; they are
// built here.
extension AppContainer {
    func makeRouteResolver() -> RouteResolver {
        RouteResolver(
            searchFeature: { [unowned self] in self.searchFeature },
            profileFeature: { [unowned self] in self.profileFeature },
            settingsFeature: { [unowned self] in self.settingsFeature },
            feedFeature: { [unowned self] in self.feedFeature },
            chatFeature: { [unowned self] in self.chatFeature },
            // The pushed profile's balance: the same store and the same sheet as
            // every root header's, on an installer that lives as long as the
            // screen it is attached to.
            attachBalance: { [unowned self] screen in
                // No balance for a guest (#1146).
                guard self.memberGate.isMember else { return }
                WalletBadgeInstaller.attach(
                    to: screen,
                    wallet: self.walletStore,
                    makeSheet: { [unowned self] in self.makeWalletSheet() }
                )
            },
            // A tapped `@handle`, a `core-platform.click/@handle` link (#524), a scanned QR
            // code and a `core-platform.click/s/<token>` link (#412).
            lookupProfile: { [weak self] reference in await self?.profileID(for: reference) ?? .unavailable },
            // A shared place link (#985).
            makePlacePage: { [unowned self] link in
                MapsFeatureBuilder.placePage(for: link, place: self.placeFeature, storageScope: self.storageScope)
            },
            // A channel's "Share as a Post" (#2216): the Text Post screen with
            // its card, publishing through the one pipeline.
            makeShowcaseComposer: { [unowned self] embed in self.uploadFeature.makeShowcaseComposer(attaching: embed) }
        )
    }
}
