import Connect
import CoreContracts
import DesignSystem
import Foundation

/// `@` and `#` completions for every composer (#524), from `search.v1.Suggest`
/// — handles for a mention, tags for a hashtag. Found by the composers up
/// their responder chain (`ShellTabBarController` is the
/// `TextCompletionSource`), so Feed and Upload need no dependency on Search.
///
/// Silent on failure: a completion that cannot be fetched is no completion,
/// and typing goes on.
struct TextCompletionService: TextCompletionProviding {
    let searchClient: any Search_V1_SearchServiceClientInterface
    var limit: Int32 = 8

    func completions(for kind: TextEntity.Kind, prefix: String) async -> [TextCompletion] {
        let bare = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "@# ")).lowercased()
        guard !bare.isEmpty else { return [] }
        var request = Search_V1_SuggestRequest()
        request.prefix = bare
        request.entityTypes = [kind == .mention ? .profile : .hashtag]
        request.limit = limit
        guard let body = await searchClient.suggest(request: request, headers: [:]).message else { return [] }
        let wanted: Search_V1_SearchEntityType = kind == .mention ? .profile : .hashtag
        var seen = Set<String>()
        return body.suggestions.compactMap { suggestion in
            let value = suggestion.text.trimmingCharacters(in: CharacterSet(charactersIn: "@# ")).lowercased()
            guard suggestion.entityType == wanted, !value.isEmpty, seen.insert(value).inserted else { return nil }
            return TextCompletion(kind: kind, value: value)
        }
    }
}
