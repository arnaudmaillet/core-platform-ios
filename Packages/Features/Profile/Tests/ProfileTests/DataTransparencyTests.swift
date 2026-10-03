import Foundation
import UIKit
import Testing
@testable import Profile

/// Your Data and Permissions (#414) and the app's privacy manifest it reads.
@MainActor
struct DataTransparencyTests {
    /// The app's real manifest, read from the repository: it must parse,
    /// declare no tracking, and name a person-readable title for every type
    /// it lists (a raw key on screen means the title table fell behind).
    @Test func theShippedManifestParsesAndNeverTracks() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ProfileTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Profile
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("App/PrivacyInfo.xcprivacy")
        let manifest = try #require(PrivacyManifest(data: try Data(contentsOf: url)))
        #expect(manifest.tracks == false)
        #expect(!manifest.collectedData.isEmpty)
        for data in manifest.collectedData {
            #expect(!data.isUsedForTracking, "\(data.type) is declared as tracking")
            #expect(!data.title.hasPrefix("NSPrivacy"), "no title for \(data.type)")
            #expect(data.purposeText == "Running the app")
        }
    }

    @Test func notAManifestIsNil() {
        #expect(PrivacyManifest(data: Data("not a plist".utf8)) == nil)
    }

    @Test func theDetailSaysWhatIsUnusual() {
        let usual = PrivacyManifest.CollectedData(
            type: "NSPrivacyCollectedDataTypeEmailAddress", isLinkedToYou: true, isUsedForTracking: false,
            purposes: ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        )
        #expect(DataTransparencyViewController.detail(for: usual) == "Running the app")
        let unusual = PrivacyManifest.CollectedData(
            type: "NSPrivacyCollectedDataTypeDeviceID", isLinkedToYou: false, isUsedForTracking: true,
            purposes: ["NSPrivacyCollectedDataTypePurposeAnalytics"]
        )
        #expect(DataTransparencyViewController.detail(for: unusual) == "Analytics · Not linked to you · Used for tracking")
    }

    @Test func theScreenListsManifestThirdPartiesAndPermissions() throws {
        let manifest = PrivacyManifest(tracks: false, collectedData: [
            .init(type: "NSPrivacyCollectedDataTypeName", isLinkedToYou: true, isUsedForTracking: false, purposes: [])
        ])
        let screen = DataTransparencyViewController(manifest: manifest, permissions: {
            [.init(title: "Camera", symbolName: "camera", purpose: "Record", state: .denied)]
        })
        screen.loadViewIfNeeded()
        let list = try #require(screen.view.subviews.compactMap { $0 as? UICollectionView }.first)
        #expect(list.numberOfSections == 3)
        #expect(list.numberOfItems(inSection: 0) == 1)
        #expect(list.numberOfItems(inSection: 1) == DataTransparencyViewController.thirdPartyLibraries.count)
        #expect(list.numberOfItems(inSection: 2) == 2) // Camera + Open iOS Settings
    }
}
