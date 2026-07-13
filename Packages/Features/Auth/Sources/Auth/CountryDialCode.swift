import Foundation

/// A curated dial-code entry powering the phone sign-in screen: prefix
/// selection, live digit grouping, and national-number validation. Enough
/// countries to exercise the UX; extend the list as markets open.
struct CountryDialCode: Equatable, Sendable, Identifiable {
    /// ISO region identifier ("FR").
    let id: String
    let flag: String
    let name: String
    /// Dial prefix including the plus ("+33").
    let prefix: String
    /// Accepted national-number digit counts.
    let nationalDigits: ClosedRange<Int>
    /// Digit grouping applied while typing; digits beyond the pattern trail
    /// as one final group.
    let grouping: [Int]

    static let all: [CountryDialCode] = [
        .init(id: "FR", flag: "\u{1F1EB}\u{1F1F7}", name: "France", prefix: "+33", nationalDigits: 9...9, grouping: [1, 2, 2, 2, 2]),
        .init(id: "US", flag: "\u{1F1FA}\u{1F1F8}", name: "United States", prefix: "+1", nationalDigits: 10...10, grouping: [3, 3, 4]),
        .init(id: "GB", flag: "\u{1F1EC}\u{1F1E7}", name: "United Kingdom", prefix: "+44", nationalDigits: 10...10, grouping: [4, 6]),
        .init(id: "DE", flag: "\u{1F1E9}\u{1F1EA}", name: "Germany", prefix: "+49", nationalDigits: 10...11, grouping: [3, 4, 4]),
        .init(id: "ES", flag: "\u{1F1EA}\u{1F1F8}", name: "Spain", prefix: "+34", nationalDigits: 9...9, grouping: [3, 3, 3])
    ]

    /// The device region's entry, falling back to the first curated country.
    static var deviceDefault: CountryDialCode {
        let region = Locale.current.region?.identifier
        return all.first { $0.id == region } ?? all[0]
    }

    /// Menu row title: "🇫🇷 France (+33)".
    var displayName: String { "\(flag) \(name) (\(prefix))" }
    /// Prefix-button title: "🇫🇷 +33".
    var buttonTitle: String { "\(flag) \(prefix)" }

    var maxNationalDigits: Int { nationalDigits.upperBound }

    /// Live formatting: digits regrouped with spaces per `grouping`.
    /// Pure — callers cap input at `maxNationalDigits` before formatting.
    func format(_ digits: String) -> String {
        var groups: [String] = []
        var remaining = Substring(digits)
        for size in grouping {
            guard !remaining.isEmpty else { break }
            groups.append(String(remaining.prefix(size)))
            remaining = remaining.dropFirst(size)
        }
        if !remaining.isEmpty {
            groups.append(String(remaining))
        }
        return groups.joined(separator: " ")
    }

    func isValidNationalNumber(_ digits: String) -> Bool {
        nationalDigits.contains(digits.count)
    }

    /// The E.164 token forwarded to the backend.
    func e164(_ digits: String) -> String {
        prefix + digits
    }
}
