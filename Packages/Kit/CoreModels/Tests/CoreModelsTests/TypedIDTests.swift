import Foundation
import Testing
@testable import CoreModels

struct TypedIDTests {
    @Test func equalityIsByRawValueWithinSameTag() {
        #expect(AccountID("a") == AccountID("a"))
        #expect(AccountID("a") != AccountID("b"))
    }

    @Test func encodesAsBareString() throws {
        let data = try JSONEncoder().encode(PostID("0197-abc"))
        #expect(String(data: data, encoding: .utf8) == "\"0197-abc\"")
    }

    @Test func decodesFromBareString() throws {
        let id = try JSONDecoder().decode(ProfileID.self, from: Data("\"p-1\"".utf8))
        #expect(id.rawValue == "p-1")
    }
}
