import DesignSystem
import Foundation
import Testing
import UIKit
@testable import MediaCore

/// ONE MEDIA GROUND (#1771): a media slot's host paints nothing under its
/// bone but `Surface.mediaGround` (or its on-dark variant), so a picture
/// that is loading, missing or failed wears one grey — the bone's own — and
/// two greys never meet. The owner's question (2026-10-27): a host keeping
/// its own fill under a grey skeleton made a double ground, and a failed
/// picture showed a colour the loading one never had.
///
/// ⚠️ A REPO-WIDE GUARD IN MEDIACORE'S LANE: touching a media host anywhere,
/// run MediaCore's tests.
@MainActor
struct MediaGroundGuardTests {
    @Test func theMediaGroundIsTheBonesGrey() {
        #expect(Surface.mediaGround == Surface.skeleton)
        #expect(Surface.mediaGroundOnDark == Surface.skeletonOnDark)
        #expect(SkeletonBoneView().fill == Surface.mediaGround)
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MediaCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MediaCore
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// The grounds `text` paints under a cover slot's view: every
    /// `<view>.backgroundColor = …` for a view handed to `CoverSlot(view:`,
    /// whose value is not the media ground.
    static func strayGrounds(in text: String) -> [String] {
        // A cover's view, or an `ImageContentView` (the slot is the view).
        let hosts = [
            #"CoverSlot\(\s*view:\s*([A-Za-z_][\w]*)"#,
            #"\b([A-Za-z_][\w]*)\s*(?::\s*ImageContentView\s*)?=\s*ImageContentView\("#,
        ].map { try! NSRegularExpression(pattern: $0) }
        let range = NSRange(text.startIndex..., in: text)
        let views = Set(hosts.flatMap { $0.matches(in: text, range: range) }.compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
        var stray: [String] = []
        for view in views {
            let ground = try! NSRegularExpression(pattern: #"\b\#(view)\.backgroundColor\s*=\s*([^\n]+)"#)
            for match in ground.matches(in: text, range: range) {
                guard let value = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { continue }
                if !value.contains("mediaGround") { stray.append("\(view) = \(value.trimmingCharacters(in: .whitespaces))") }
            }
        }
        return stray
    }

    /// Hosts whose cover view keeps another ground, and why.
    static let allowed: [String: String] = [
        // The pin's media card is black by design (the last rung of a video
        // marker's ladder, `PinCardView`); its bone wears the on-dark ground.
        "PinCardView.swift": "a video marker's black card; the bone is on-dark",
        // A collection row's box is the CARD the pages lie on (chrome): its
        // own cover is reset, with no bone, while the carousel shows.
        "PostGridCells.swift": "a collection row's box is the card behind its pages",
    ]

    @Test func noCoverHostPaintsAnotherGround() {
        var found: [String: [String]] = [:]
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                guard text.contains("CoverSlot(") || text.contains("ImageContentView(") else { continue }
                let stray = Self.strayGrounds(in: text)
                if !stray.isEmpty { found[url.lastPathComponent] = stray }
            }
        }
        let unexplained = found.filter { Self.allowed[$0.key] == nil }
        #expect(unexplained.isEmpty, "paint Surface.mediaGround under a cover's bone, or argue the case: \(unexplained)")
        let stale = Set(Self.allowed.keys).subtracting(found.keys)
        #expect(stale.isEmpty, "these no longer paint another ground — drop them: \(stale.sorted())")
    }

    /// The slots built bare — not through `CoverSlot`, `AvatarView` or
    /// `ImageContentView`, whose hosts the check above reads — and the ground
    /// each one keeps. A new one fails here until its ground is argued.
    static let bareSlots: [String: String] = [
        "HeroBannerView.swift": "paints Surface.mediaGround (HeroBannerGroundTests)",
        "PinCardView.swift": "a text marker's face bone, on the card's black",
        "SnapMediaCardView.swift": "full screen: no bone, the centred loader on black (#1764)",
        // The wrappers themselves.
        "CoverSlot.swift": "the cover's slot",
        "AvatarView.swift": "the disc's slot; its plate is the media ground",
        "ImageContentView.swift": "the view's own slot",
    ]

    @Test func everyBareSlotIsKnown() {
        var found: Set<String> = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if text.contains("MediaSlot(size:") { found.insert(url.lastPathComponent) }
            }
        }
        let unknown = found.subtracting(Self.bareSlots.keys)
        #expect(unknown.isEmpty, "a bare MediaSlot: give its host the media ground, then list it: \(unknown.sorted())")
        let stale = Set(Self.bareSlots.keys).subtracting(found)
        #expect(stale.isEmpty, "no longer builds a bare slot — drop it: \(stale.sorted())")
    }

    /// A face that never arrives sits on the bone's grey: the initials'
    /// plate is the media ground.
    @Test func anAvatarsPlateIsTheMediaGround() throws {
        let avatar = AvatarView(diameter: 40, size: .avatar)
        let plate = try #require(avatar.monogram.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let expected = Surface.mediaGround.resolvedColor(with: avatar.monogram.traitCollection).cgColor
        #expect(plate.fillColor == expected)
    }

    @Test func thePatternFindsTheShape() {
        let host = """
        let slot = CoverSlot(view: imageView, size: .full)
        imageView.backgroundColor = .tertiarySystemFill
        """
        #expect(Self.strayGrounds(in: host) == ["imageView = .tertiarySystemFill"])
        let good = """
        let slot = CoverSlot(view: imageView, size: .full)
        imageView.backgroundColor = Surface.mediaGround
        """
        #expect(Self.strayGrounds(in: good).isEmpty)
        let content = """
        private let face = ImageContentView(size: .avatar)
        face.backgroundColor = .secondarySystemFill
        """
        #expect(Self.strayGrounds(in: content) == ["face = .secondarySystemFill"])
    }
}
