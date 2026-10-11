import Foundation

/// Cache keys that survive what changes between two requests for the same
/// content.
public enum CacheKey {
    /// The key for a media URL: the URL without its signing query items and
    /// its fragment.
    ///
    /// A presigned URL changes on every request (new signature, new expiry)
    /// while the bytes behind it do not, so keying by the raw URL would cache
    /// the same image once per fetch. Until `post.v1` carries an `asset_id`
    /// (core-platform-backend#907), this is the media key. Strips AWS SigV4
    /// (`X-Amz-*`), Google (`X-Goog-*`) and CloudFront (`Expires`,
    /// `Signature`, `Key-Pair-Id`, `Policy`) parameters; every other query item
    /// stays, in order, since it may select a different rendition.
    public static func media(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        if let items = components.queryItems {
            let kept = items.filter { !isSigningParameter($0.name) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static let signingNames: Set<String> = ["expires", "signature", "key-pair-id", "policy"]

    static func isSigningParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("x-amz-") || lowered.hasPrefix("x-goog-") || signingNames.contains(lowered)
    }
}
