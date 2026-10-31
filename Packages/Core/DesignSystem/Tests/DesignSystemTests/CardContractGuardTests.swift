import Foundation
import Testing

/// ⚠️ A REPO-WIDE GUARD (#1497), like `RawHueGuardTests`: every card follows
/// one contract — `Surface.dressCard`, the card's tone (lighter than its
/// page), the For You card's corner and its edge (#1494). A hand-made card
/// drew its own: a radius of 12, 16 or 18, on a fill that reads DARKER than
/// its page (`tertiarySystemFill`).
///
/// It scans every source file under `App/` and `Packages/` (tests excluded)
/// for a literal `cornerRadius = <number>` within a few lines of a card-like
/// fill. Such a file dresses its card with `Surface.dressCard`, or keeps the
/// shape with a reason on the list below — a tile, a thumbnail, a badge, a
/// control, debug art.
///
/// CI only runs this in DesignSystem's lane, which a change elsewhere does
/// not select: drawing a card anywhere, run DesignSystem's tests too.
struct CardContractGuardTests {
    /// File name → why its rounded fill is not a card.
    static let allowed: [String: String] = [
        "LensLab.swift": "the DEBUG lens bench's sample shapes",
        "HapticCatalogViewController.swift": "the DEBUG haptic catalog's strips",
        "WalletHowItWorksViewController.swift": "a step's number badge, a disc",
        "WalletSheetViews.swift": "the streak's progress track and fill, 4 pt high",
        "TextCompletionStrip.swift": "the emote suggestions' chips: a control, not a card",
    ]

    /// Fills a hand-made card used as its ground.
    static let cardFills = [
        "tertiarySystemFill", "secondarySystemFill", "quaternarySystemFill", "systemGray6",
        "secondarySystemBackground", "tertiarySystemBackground", "secondarySystemGroupedBackground",
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

    /// The lines of `text` that round a card-like fill by hand: a literal
    /// corner within six lines of a card fill.
    static func handMadeCards(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        var found: [Int] = []
        for (index, line) in lines.enumerated() where Self.roundsByHand(line) {
            let window = lines[max(0, index - 6)...min(lines.count - 1, index + 6)].joined(separator: "\n")
            if cardFills.contains(where: { window.contains($0) }) { found.append(index + 1) }
        }
        return found
    }

    /// Whether `line` sets a corner to a number, not to a named radius.
    static func roundsByHand(_ line: String) -> Bool {
        let code = line.drop { $0 == " " || $0 == "\t" }
        guard !code.hasPrefix("//"), let range = code.range(of: "cornerRadius = ") else { return false }
        return code[range.upperBound...].first?.isNumber == true
    }

    @Test func theGuardSeesAHandMadeCard() {
        #expect(Self.handMadeCards(in: "card.backgroundColor = .tertiarySystemFill\ncard.layer.cornerRadius = 12") == [2])
        #expect(Self.handMadeCards(in: "card.backgroundColor = .tertiarySystemFill\ncard.layer.cornerRadius = Self.radius").isEmpty)
        #expect(Self.handMadeCards(in: "badge.backgroundColor = .systemRed\nbadge.layer.cornerRadius = 9").isEmpty)
        #expect(Self.handMadeCards(in: "// cornerRadius = 12 on tertiarySystemFill").isEmpty)
    }

    @Test func everyCardFollowsTheContract() {
        var found: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(
                at: Self.root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/Tests/"), !path.contains("/.build/"),
                      Self.allowed[url.lastPathComponent] == nil,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found += Self.handMadeCards(in: text).map { "\(url.lastPathComponent):\($0)" }
            }
        }
        #expect(found.isEmpty, "hand-made cards — dress them with Surface.dressCard (#1497): \(found)")
    }
}
