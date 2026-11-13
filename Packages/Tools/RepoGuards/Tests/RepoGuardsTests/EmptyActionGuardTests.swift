import Foundation
import Testing

/// A control is shown only if it does something (#801).
struct EmptyActionGuardTests {
    /// The empty-handler actions in `source` that pretend to do something.
    ///
    /// Line comments go first, so a comment quoting `{ _ in }` can neither
    /// fail the scan nor start a match. Then each `UIAction` is read on its
    /// own: its argument list (balanced parentheses, strings skipped), then
    /// its trailing closure, which offends when it holds nothing but `_ in`,
    /// with or without a capture list.
    ///
    /// Two kinds of empty handler are honest and pass — judged inside THAT
    /// action's own arguments, never across statements: a `.disabled` row,
    /// which reads rather than acts (a stake line, a "Coming soon"
    /// audience), and the CHOSEN row of a single-choice menu (`state: .on`),
    /// where choosing it again changes nothing.
    static func offendingActions(in source: String) throws -> [String] {
        let code = strippingLineComments(source)
        let name = try Regex(#"\bUIAction\b"#)
        let emptyBody = try Regex(#"\s*\{\s*(\[[^\]]*\]\s*)?_\s+in\s*\}"#)
        var offenders: [String] = []
        for match in code.matches(of: name) {
            var index = code[match.range.upperBound...].drop(while: \.isWhitespace).startIndex
            var arguments = Substring("")
            if index < code.endIndex, code[index] == "(" {
                guard let close = closingParenthesis(in: code, openingAt: index) else { continue }
                arguments = code[index...close]
                index = code.index(after: close)
            }
            guard let body = code[index...].prefixMatch(of: emptyBody) else { continue }
            if arguments.contains(".disabled") || arguments.contains("state: .on") { continue }
            offenders.append(String(code[match.range.lowerBound..<body.range.upperBound]))
        }
        return offenders
    }

    /// `source` without its `//` comments (doc comments included). A `//`
    /// inside a string literal — a URL — is kept.
    static func strippingLineComments(_ source: String) -> String {
        var output = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var inString = false
            var previous: Character?
            var cut = line.endIndex
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if character == "\"", previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" {
                    cut = line.index(before: index)
                    break
                }
                previous = character
                index = line.index(after: index)
            }
            output += line[..<cut]
            output += "\n"
        }
        return output
    }

    /// The `)` closing the `(` at `open`, skipping parentheses in strings.
    private static func closingParenthesis(in code: String, openingAt open: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var previous: Character?
        var index = open
        while index < code.endIndex {
            let character = code[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            previous = character
            index = code.index(after: index)
        }
        return nil
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

    /// The guard catches what it is for, and nothing that does work or
    /// says honestly that it does not.
    @Test func theGuardTellsAnEmptyHandlerFromAnHonestOne() throws {
        #expect(try Self.offendingActions(in: #"UIAction(title: "Report", image: UIImage(systemName: "flag")) { _ in }"#).count == 1)
        #expect(try Self.offendingActions(in: "UIAction(title: \"Block\") { [weak self] _ in\n}").count == 1)
        #expect(try Self.offendingActions(in: #"UIAction { _ in }"#).count == 1)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Report") { _ in report() }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Share") { [weak self] _ in self?.share() }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Friends", attributes: .disabled) { _ in }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Everyone", state: .on) { _ in }"#).isEmpty)
        #expect(try Self.offendingActions(in: #"UIAction(title: "Buy (now)") { _ in }"#).count == 1, "a ) in a string ended the arguments")
    }

    /// ⚠️ Comments neither fail the scan nor open a match, and an honest
    /// marker in ANOTHER statement excuses nothing.
    @Test func commentsAndNeighboursAreNotTheAction() throws {
        #expect(try Self.offendingActions(in: "// UIAction(title: \"x\") { _ in }\nlet a = 1").isEmpty)
        #expect(try Self.offendingActions(in: "/// A `UIAction` doc comment\nlet done = { _ in }").isEmpty)
        let neighbours = """
        let shown = UIAction(title: "Stake", attributes: .disabled) { _ in }
        let report = UIAction(title: "Report") { _ in }
        """
        #expect(try Self.offendingActions(in: neighbours).count == 1, "the row above excused the Report")
        #expect(Self.strippingLineComments("let url = \"https://x.dev\" // note") == "let url = \"https://x.dev\" \n")
    }
}
