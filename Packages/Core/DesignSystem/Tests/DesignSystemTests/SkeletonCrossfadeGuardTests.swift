import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1769): a skeleton leaves through `SkeletonCrossfade`
/// — `fadeOutSkeleton`, `crossfadeSkeleton(to:)`,
/// `crossfadeSkeleton(swapping:)`, `UIView.revealRedacted` — at one duration,
/// never through a `UIView.transition` or `UIView.animate` written around it.
/// Eight screens had written their own, at 0.2, 0.3 and 0.35 s.
///
/// The scan reads each animation's own lines (the call and the nine after
/// it, comments left out) for a skeleton, a bone or a redaction.
///
/// CI only runs this in DesignSystem's lane: adding a skeleton anywhere, run
/// DesignSystem's tests too.
struct SkeletonCrossfadeGuardTests {
    /// Files allowed to animate a skeleton by hand, and why.
    static let allowed: [String: String] = [
        "SkeletonCrossfade.swift": "the helpers themselves",
        "EmoteSkeleton.swift": "an emote's bone hands over to the emote's own arrival animation, at its duration",
        "CommentStream.swift": "the comments' bone ghosts fade under the staged reveal they are timed with",
    ]

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    /// Whether `text` animates a skeleton by hand: an animation call whose
    /// own lines name a skeleton, a bone or a redaction.
    static func animatesASkeleton(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let code = lines.map { $0.hasPrefix("//") ? "" : $0 }
        for (index, line) in code.enumerated()
        where line.contains("UIView.transition(") || line.contains("UIView.animate(") {
            let body = code[index..<min(code.count, index + 10)].joined(separator: "\n").lowercased()
            if body.contains("skeleton") || body.contains("bone") || body.contains("redact") { return true }
        }
        return false
    }

    @Test func noSkeletonLeavesByHand() {
        var found: Set<String> = []
        var scanned = 0
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                scanned += 1
                guard Self.allowed[url.lastPathComponent] == nil else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if Self.animatesASkeleton(text) { found.insert(url.lastPathComponent) }
            }
        }
        #expect(scanned > 100, "the scan found no source at all: \(Self.root.path)")
        #expect(found.isEmpty, "let the skeleton leave through SkeletonCrossfade (fadeOutSkeleton, crossfadeSkeleton, revealRedacted): \(found.sorted())")
    }

    @Test func theScanFindsTheShape() {
        #expect(Self.animatesASkeleton("""
            UIView.transition(with: collectionView, duration: 0.3, options: .transitionCrossDissolve) {
                self.skeletonView.alpha = 0
            }
            """))
        #expect(Self.animatesASkeleton("""
            UIView.animate(withDuration: 0.35) {
                reveal()
            } completion: { _ in
                guard !self.isRedacted else { return }
            }
            """))
        #expect(!Self.animatesASkeleton("""
            UIView.animate(withDuration: 0.3) {
                self.badge.alpha = 1
            }
            """))
        #expect(!Self.animatesASkeleton("""
            // UIView.animate(withDuration: 0.3) { skeleton.alpha = 0 }
            """))
    }
}
