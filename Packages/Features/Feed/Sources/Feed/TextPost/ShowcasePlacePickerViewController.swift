import DesignSystem
import FeedInterface
import MapKit
import UIKit

/// Where a showcase stands on the map (#2216): a search field and the places
/// it finds, pushed on the Text Post sheet's stack as its Drafts list is.
///
/// ⚠️ **THE SMALLEST PLACE STEP, AND THE APP'S FIRST.** Nothing in the app
/// picked a place before — the create request's `location` went unused —
/// so this is MapKit's own search (`MKLocalSearchCompleter` for the rows,
/// `MKLocalSearch` for the chosen one's point), with no map and no current
/// location: a typed "Bercy skatepark" is the whole job. A richer picker
/// (nearby places, a map to drop a pin on) can replace it behind
/// `onPick` without touching the composer.
final class ShowcasePlacePickerViewController: UIViewController {
    /// The place chosen: the host takes it and pops this screen.
    var onPick: ((TextPostPlace) -> Void)?

    private let completer = MKLocalSearchCompleter()
    private let field = UISearchTextField()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let statusLabel = UILabel()
    private var results: [MKLocalSearchCompletion] = []
    /// The search resolving a chosen row, so a second tap waits for it.
    private var resolving: MKLocalSearch?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Add a Place"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        completer.delegate = self
        // Places people go — a skatepark, a café, a street — not every
        // address a query could mean.
        completer.resultTypes = [.pointOfInterest, .address]

        field.placeholder = "Search for a place"
        field.font = .appFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.accessibilityLabel = "Search for a place"
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)

        statusLabel.font = .appFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = Self.idleText

        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.backgroundColor = .clear

        let stack = UIStackView(arrangedSubviews: [field, statusLabel])
        stack.axis = .vertical
        stack.spacing = Spacing.sm
        stack.constrain(in: view) { parent in
            stack.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.sm)
            stack.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            stack.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
        tableView.constrain(in: view) { parent in
            tableView.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Spacing.xs)
            tableView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            tableView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            tableView.bottomAnchor.constraint(equalTo: parent.keyboardLayoutGuide.topAnchor)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    static let cellID = "place"
    static let idleText = "Your post shows on the map at the place you choose."
    static let emptyText = "No places found."
    static let failedText = "Couldn't find that place. Try another search."

    private func queryChanged() {
        let query = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            results = []
            tableView.reloadData()
            statusLabel.text = Self.idleText
            statusLabel.isHidden = false
            completer.cancel()
            return
        }
        completer.queryFragment = query
    }

    /// Resolves the chosen row to its point, then hands it over.
    private func choose(_ completion: MKLocalSearchCompletion) {
        guard resolving == nil else { return }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        resolving = search
        let fallbackName = completion.title
        search.start { [weak self] response, _ in
            // Read here, where the answer is: only values cross to the
            // screen.
            let item = response?.mapItems.first
            let name: String = item?.name ?? fallbackName
            let coordinate: CLLocationCoordinate2D? = item?.location.coordinate
            let latitude: Double? = coordinate?.latitude
            let longitude: Double? = coordinate?.longitude
            Task { @MainActor [weak self] in
                self?.resolved(name: name, latitude: latitude, longitude: longitude)
            }
        }
    }

    private func resolved(name: String, latitude: Double?, longitude: Double?) {
        resolving = nil
        guard let latitude, let longitude else {
            statusLabel.text = Self.failedText
            statusLabel.isHidden = false
            return
        }
        onPick?(TextPostPlace(name: name, latitude: latitude, longitude: longitude))
    }
}

extension ShowcasePlacePickerViewController: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
        tableView.reloadData()
        statusLabel.text = Self.emptyText
        statusLabel.isHidden = !results.isEmpty
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        results = []
        tableView.reloadData()
        statusLabel.text = Self.failedText
        statusLabel.isHidden = false
    }
}

extension ShowcasePlacePickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let result = results[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = result.title
        content.secondaryText = result.subtitle.isEmpty ? nil : result.subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: "mappin.circle.fill")
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard results.indices.contains(indexPath.row) else { return }
        choose(results[indexPath.row])
    }
}

// MARK: - How it is left (#1144)

extension ShowcasePlacePickerViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
