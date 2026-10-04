import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings → Your Activity (#489).
@MainActor
struct YourActivityTests {
    @Test func limitsReadAsOffOrADuration() {
        #expect(YourActivityViewController.limitTitle(nil) == "Off")
        #expect(YourActivityViewController.limitTitle(30).contains("30"))
        #expect(YourActivityViewController.limitTitle(90).contains("1"))
    }

    /// Only what needs a server stays "coming soon"; time limits are live.
    @Test func onlyServerFeaturesArePlanned() {
        #expect(YourActivityViewController.planned == ["Recently deleted", "Likes and history"])
    }

    @Test func thePageShowsTheStoresTime() throws {
        let store = ScreenTimeStore(defaults: UserDefaults(suiteName: "activity-\(UUID().uuidString)")!)
        let now = Date()
        store.record(from: now.addingTimeInterval(-25 * 60), to: now)
        let controller = YourActivityViewController(store: store, now: { now })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        let texts = controller.view.allSubviewTexts()
        #expect(texts.contains { $0.contains("25") })
        #expect(texts.contains("Daily Limit"))
    }
}

private extension UIView {
    func allSubviewTexts() -> [String] {
        var texts: [String] = []
        if let label = self as? UILabel, let text = label.text { texts.append(text) }
        if let cell = self as? UICollectionViewListCell, let content = cell.contentConfiguration as? UIListContentConfiguration {
            texts += [content.text, content.secondaryText].compactMap { $0 }
        }
        for subview in subviews { texts += subview.allSubviewTexts() }
        return texts
    }
}
