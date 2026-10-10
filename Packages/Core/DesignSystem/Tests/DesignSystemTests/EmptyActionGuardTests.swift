import Foundation
import Testing

/// A control is shown only if it does something (#801).
struct EmptyActionGuardTests {
    /// `UIAction(...)` up to its trailing closure — no braces in between —
    /// then a body holding nothing but `_ in`, with or without a capture list.
    private static let emptyHandler = #"\bUIAction\b[^{}]*\{\s*(\[[^\]]*\]\s*)?_\s+in\s*\}"#

    /// The empty-handler actions in `source` that pretend to do something.
    ///
    /// Two kinds of empty handler are honest and pass: a `.disabled` row,
    /// which reads rather than acts (a stake line, a "Coming soon"
    /// audience), and the CHOSEN row of a single-choice menu (`state: .on`),
    /// where choosing it again changes nothing.
    static func offendingActions(in source: String) throws -> [String] {
        let pattern = try Regex(emptyHandler)
        return source.matches(of: pattern)
            .map { String(source[$0.range]) }
            .filter { !$0.contains(".disabled") && !$0.contains("state: .on") }
    }

    /// ⚠️ NO `UIAction { _ in }`. A comment's Report and Block sat in a menu
    /// as empty handlers: for a safety action, the user believed something
    /// was filed. A row with nothing behind it is hidden, or answers honestly
    /// (disabled, with a reason). Scans the app's and the packages' sources,
    /// tests excluded.
    @Test func noMenuActionHasAnEmptyHandler() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystemTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
        var offenders: [String] = []
        for folder in ["App", "Packages"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                guard url.pathExtension == "swift", !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if try !Self.offendingActions(in: text).isEmpty { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "UIAction with an empty handler in: \(offenders)")
    }

    /// The pattern catches what it is for, and nothing that does work or
    /// says honestly that it does not.
    @Test func theGuardTellsAnEmptyHandlerFromAnHonestOne() throws {
        #expect(try Self.offendingActions(in: #"UIAction(title: "Report", image: UIImage(systemName: "flag")) { _ in }"#).count == 1)
        #expect(try Self.offendingActions(in: "UIAction(title: \"Block\") { [weak self] _ in\n}").count == 1)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Report") { _ in report() }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Share") { [weak self] _ in self?.share() }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Friends", attributes: .disabled) { _ in }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Everyone", state: .on) { _ in }"#).isEmpty)
    }
}
