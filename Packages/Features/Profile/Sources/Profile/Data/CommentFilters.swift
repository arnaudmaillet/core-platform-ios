import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

/// What the active profile hides from the comments on its posts (#404,
/// backend #728). Matching comments are hidden from everyone but their
/// author — who isn't told.
public struct CommentFilterSettings: Equatable, Sendable {
    public static let maximumWords = 200
    public static let maximumWordLength = 64

    /// Lowercased, de-duplicated and sorted, as the server stores them.
    public var hiddenWords: [String]
    /// Hides comments with commonly reported offensive terms. On by default.
    public var filtersOffensive: Bool

    public init(hiddenWords: [String] = [], filtersOffensive: Bool = true) {
        self.hiddenWords = hiddenWords
        self.filtersOffensive = filtersOffensive
    }

    /// The server's normalisation, so the screen shows what will be stored.
    public static func normalized(_ words: [String]) -> [String] {
        Array(Set(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    init(_ proto: Profile_V1_CommentFilters) {
        self.init(hiddenWords: proto.hiddenWords, filtersOffensive: proto.filterOffensive)
    }

    var proto: Profile_V1_CommentFilters {
        var proto = Profile_V1_CommentFilters()
        proto.hiddenWords = hiddenWords
        proto.filterOffensive = filtersOffensive
        return proto
    }
}

public enum CommentFiltersError: Error, Equatable {
    /// PRF-9001: more than 200 words, or one longer than 64 characters.
    case tooMany
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension CommentFiltersError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// Settings → Safety → Hidden Words.
public protocol CommentFiltersManaging: Sendable {
    func commentFilters() async throws -> CommentFilterSettings
    /// Replaces the filters; returns them as stored.
    func setCommentFilters(_ filters: CommentFilterSettings) async throws -> CommentFilterSettings
}

extension ProfileRepository: CommentFiltersManaging {
    public func commentFilters() async throws -> CommentFilterSettings {
        // Owner-only on the view: the active profile reading itself. An
        // unset record reads as the defaults (offensive filter on).
        let view = try await fetchProfileView(id: try await resolveViewerProfileID())
        return view.hasCommentFilters ? CommentFilterSettings(view.commentFilters) : CommentFilterSettings()
    }

    public func setCommentFilters(_ filters: CommentFilterSettings) async throws -> CommentFilterSettings {
        var stored = filters
        stored.hiddenWords = CommentFilterSettings.normalized(filters.hiddenWords)
        var request = Profile_V1_SetCommentFiltersRequest()
        request.profileID = try await resolveViewerProfileID(forWrite: "setCommentFilters").rawValue
        request.filters = stored.proto
        let response = await profileClient.setCommentFilters(request: request, headers: [:])
        if let error = response.error {
            if (error.message ?? "").contains("PRF-9001") { throw CommentFiltersError.tooMany }
            throw CommentFiltersError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
        return stored
    }
}
