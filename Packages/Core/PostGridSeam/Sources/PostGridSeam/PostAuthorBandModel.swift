import CoreModels
import DesignSystem
import Foundation

/// Everything the band draws, so a row and a transition prop are configured
/// from one value rather than from two readings of a post.
///
/// ⚠️ `PostAuthorBandView.Model` is this type: it moved here from the band
/// (PostGrid) so the text reveal's origin can carry it without MediaCore
/// (#2380). Hosts still spell it `PostAuthorBandView.Model`.
public struct PostAuthorBandModel: Equatable, Sendable {
    /// The display name, or nil for a BARE band that names nobody.
    public let name: String?
    public let handle: String
    public let avatarURL: URL?
    public let monogram: String
    /// The post's compact age, as the band shows it. Carried on the model
    /// rather than derived at draw time: a compact age is a function of
    /// the clock, and the row and the prop that copies it must agree.
    public let age: String
    /// The relation mark the face wears (#2300): the author's, as the
    /// host's binding drew it — `.none` from a post alone. Carried on the
    /// model so a reveal's prop, configured from the row's reading, wears
    /// the row's mark and nothing pops in at the landing.
    public private(set) var relationMark: PersonRelationBadge = .none

    /// Whether the band draws a person at all.
    public var showsIdentity: Bool { name != nil }

    /// - Parameter showsIdentity: false for a surface where the author is
    ///   the screen itself. A post that carries no author at all is bare
    ///   whatever the caller asks — there is nobody to draw.
    /// - Parameter age: the age to show, or nil to work it out from the
    ///   post now.
    public init(post: GalleryPost, showsIdentity: Bool = true, age: String? = nil) {
        let name = post.authorName?.trimmingCharacters(in: .whitespaces) ?? ""
        let handle = post.authorHandle?.trimmingCharacters(in: .whitespaces) ?? ""
        self.age = age ?? PostMetadata.compactAge(ofMillis: post.publishedAtMS)
        // Either half is enough to draw an identity, and neither is enough
        // to draw one without the other's absence showing — so the band
        // shows a person for a post that has ANY of them and each label
        // carries what it has.
        guard showsIdentity, !name.isEmpty || !handle.isEmpty else {
            self.name = nil
            self.handle = ""
            avatarURL = nil
            monogram = ""
            return
        }
        self.name = name.isEmpty ? handle : name
        self.handle = handle
        avatarURL = post.authorAvatarURL
        monogram = MonogramAvatarView.monogram(name: name, handle: handle)
    }

    /// The same band with a different date — what a stand-in does to show
    /// the row's own reading rather than this instant's.
    public func withAge(_ age: String) -> PostAuthorBandModel {
        var model = PostAuthorBandModel(name: name, handle: handle, avatarURL: avatarURL, monogram: monogram, age: age)
        model.relationMark = relationMark
        return model
    }

    /// The same band wearing `mark` (#2300) — nothing for a bare band,
    /// which draws no face.
    public func withRelationMark(_ mark: PersonRelationBadge) -> PostAuthorBandModel {
        var model = self
        model.relationMark = showsIdentity ? mark : .none
        return model
    }

    private init(name: String?, handle: String, avatarURL: URL?, monogram: String, age: String) {
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.monogram = monogram
        self.age = age
    }
}
