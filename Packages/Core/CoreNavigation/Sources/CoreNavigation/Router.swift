/// Cross-feature navigation contract. Features hold a `Router` and ask for
/// destinations by route; only the app layer knows which coordinator answers.
@MainActor
public protocol Router: AnyObject {
    func route(to route: AppRoute)
}
