import Foundation

/// Where the repository is, for the guards that read it.
public enum RepoRoot {
    /// The repository's root: this file sits at
    /// `Packages/Tools/RepoGuards/Sources/RepoGuards/RepoRoot.swift`.
    public static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RepoGuards
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // RepoGuards
            .deletingLastPathComponent() // Tools
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .resolvingSymlinksInPath()
    }
}
