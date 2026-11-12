import Foundation

/// The app's `PrivacyInfo.xcprivacy`, read back at runtime so Settings shows
/// people exactly what the App Store is told (#414).
public struct PrivacyManifest: Equatable, Sendable {
    public struct CollectedData: Equatable, Sendable {
        /// The manifest key, e.g. `NSPrivacyCollectedDataTypeEmailAddress`.
        public let type: String
        public let isLinkedToYou: Bool
        public let isUsedForTracking: Bool
        public let purposes: [String]

        /// What a person calls it.
        public var title: String {
            Self.titles[type] ?? type.replacingOccurrences(of: "NSPrivacyCollectedDataType", with: "")
        }

        /// Purposes in plain words.
        public var purposeText: String {
            purposes.map { Self.purposeTitles[$0] ?? $0 }.joined(separator: ", ")
        }

        private static let titles: [String: String] = [
            "NSPrivacyCollectedDataTypeEmailAddress": "Email address",
            "NSPrivacyCollectedDataTypePhoneNumber": "Phone number",
            "NSPrivacyCollectedDataTypeName": "Name",
            "NSPrivacyCollectedDataTypeUserID": "Account and profile IDs",
            "NSPrivacyCollectedDataTypeDeviceID": "Device ID",
            "NSPrivacyCollectedDataTypePhotosorVideos": "Photos and videos you post",
            "NSPrivacyCollectedDataTypeAudioData": "Sound in videos you post",
            "NSPrivacyCollectedDataTypeEmailsOrTextMessages": "Messages",
            "NSPrivacyCollectedDataTypeOtherUserContent": "Posts and comments",
            "NSPrivacyCollectedDataTypePreciseLocation": "Precise location",
            "NSPrivacyCollectedDataTypeCoarseLocation": "Approximate location",
            "NSPrivacyCollectedDataTypePurchaseHistory": "Purchases"
        ]

        private static let purposeTitles: [String: String] = [
            "NSPrivacyCollectedDataTypePurposeAppFunctionality": "Running the app",
            "NSPrivacyCollectedDataTypePurposeAnalytics": "Analytics",
            "NSPrivacyCollectedDataTypePurposeProductPersonalization": "Personalisation",
            "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising": "Third-party advertising",
            "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising": "Our own advertising",
            "NSPrivacyCollectedDataTypePurposeOther": "Other"
        ]
    }

    public let tracks: Bool
    public let collectedData: [CollectedData]

    public init(tracks: Bool, collectedData: [CollectedData]) {
        self.tracks = tracks
        self.collectedData = collectedData
    }

    /// Parses manifest plist bytes; nil when they are not a manifest.
    public init?(data: Data) {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        tracks = root["NSPrivacyTracking"] as? Bool ?? false
        let entries = root["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        collectedData = entries.compactMap { entry in
            guard let type = entry["NSPrivacyCollectedDataType"] as? String else { return nil }
            return CollectedData(
                type: type,
                isLinkedToYou: entry["NSPrivacyCollectedDataTypeLinked"] as? Bool ?? false,
                isUsedForTracking: entry["NSPrivacyCollectedDataTypeTracking"] as? Bool ?? false,
                purposes: entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            )
        }
    }

    /// The manifest shipped in `bundle`, or nil when it has none.
    public static func load(from bundle: Bundle = .main) -> PrivacyManifest? {
        guard let url = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
              let data = try? Data(contentsOf: url) else { return nil }
        return PrivacyManifest(data: data)
    }
}
