import CoreModels
import UIKit

/// One entry of a place's Activity stream: someone did something HERE, at a
/// moment — the chronological counterpart to the Gallery's popularity order.
///
/// Derived client-side from the place's member posts (the kind decides the
/// verb: words are a check-in, stills are shared, videos are posted) because
/// no activity contract exists on the wire — the same mock-era footing as the
/// places themselves (`dev/BACKEND_GAPS.md` §18). When a real activity feed
/// ships, this value is the projection it hydrates into and the list below
/// does not change.
struct PlaceActivityEvent: Equatable {
    enum Kind: Equatable {
        case checkIn
        case photo
        case short

        var verb: String {
            switch self {
            case .checkIn: "checked in"
            case .photo: "shared a photo"
            case .short: "posted a short"
            }
        }

        var symbolName: String {
            switch self {
            case .checkIn: "mappin.circle.fill"
            case .photo: "photo.circle.fill"
            case .short: "play.circle.fill"
            }
        }
    }

    let id: PostID
    let authorName: String
    let kind: Kind
    let timestampMS: Int64
}

/// The Activity tab: a plain newest-first list. A table rather than a third
/// grid on purpose — activity is a STREAM of sentences ("Ava checked in ·
/// 2d"), and tiles would dress events up as content.
final class PlaceActivityListView: UIView {
    private(set) var events: [PlaceActivityEvent] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tableView.dataSource = self
        tableView.allowsSelection = false
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "activity")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        emptyLabel.text = "Nothing has happened here yet"
        emptyLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ events: [PlaceActivityEvent]) {
        self.events = events
        emptyLabel.isHidden = !events.isEmpty
        tableView.reloadData()
    }

    /// "3d" / "5w" — the feed's own relative vocabulary, shortest form.
    static func relativeAge(ofMS timestampMS: Int64, now: Date = Date()) -> String {
        let posted = Date(timeIntervalSince1970: TimeInterval(timestampMS) / 1000)
        let seconds = max(0, now.timeIntervalSince(posted))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return "\(days / 7)w"
    }
}

extension PlaceActivityListView: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        events.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "activity", for: indexPath)
        guard let event = events[safe: indexPath.row] else { return cell }
        var content = cell.defaultContentConfiguration()
        content.image = UIImage(systemName: event.kind.symbolName)
        content.imageProperties.tintColor = .secondaryLabel
        content.text = "\(event.authorName) \(event.kind.verb)"
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryText = Self.relativeAge(ofMS: event.timestampMS)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
