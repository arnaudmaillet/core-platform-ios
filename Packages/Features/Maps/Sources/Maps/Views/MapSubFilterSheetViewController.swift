import CoreModels
import MediaCore
import UIKit

/// The sub-filter full-list sheet (the trailing bubble in the refinement
/// row): every friend / followed profile / place category as a searchable
/// table, presented as a native medium/large bottom sheet. Selecting a row
/// applies that refinement (tapping the active one clears it) and dismisses.
final class MapSubFilterSheetViewController: UIViewController {
    private let options: [MapSubFilterOption]
    private let selected: MapSubFilter?
    private let imagePipeline: ImagePipeline?
    private let onSelect: (MapSubFilter?) -> Void

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()
    private var filtered: [MapSubFilterOption]
    private static let cellIdentifier = "option"

    /// - Parameter title: the sheet's header, i.e. the primary it refines
    ///   ("Friends", "Following", "Places").
    init(
        title: String,
        options: [MapSubFilterOption],
        selected: MapSubFilter?,
        imagePipeline: ImagePipeline?,
        onSelect: @escaping (MapSubFilter?) -> Void
    ) {
        self.options = options
        self.selected = selected
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
        self.filtered = options
        super.init(nibName: nil, bundle: nil)
        self.title = title
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        searchBar.placeholder = "Search"
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        tableView.tableHeaderView = header()
        tableView.pin(to: view)
    }

    private func header() -> UIView {
        // A plain sized container: UITableView header views need an explicit
        // frame, they are not Auto Layout-driven.
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 56))
        searchBar.frame = container.bounds.insetBy(dx: 8, dy: 4)
        searchBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(searchBar)
        return container
    }
}

extension MapSubFilterSheetViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filtered.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        let option = filtered[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = option.sheetTitle
        content.image = UIImage(systemName: option.content.symbolName)
        content.imageProperties.tintColor = .label
        if option.favorite?.avatarURL != nil {
            // Reserve the avatar's slot so rows don't reflow when it lands.
            content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
            content.imageProperties.cornerRadius = 16
        }
        cell.contentConfiguration = content
        cell.accessoryType = option.subFilter == selected ? .checkmark : .none

        // Avatar loads are cache-hot after the pill row; a stale async land
        // on a reused cell is repaired by checking the row's identity.
        if let url = option.favorite?.avatarURL, let imagePipeline {
            let subFilter = option.subFilter
            Task { [weak self, weak cell] in
                guard let image = try? await imagePipeline.image(for: url),
                      let self, let cell,
                      let current = self.tableView.indexPath(for: cell),
                      current.row < self.filtered.count,
                      self.filtered[current.row].subFilter == subFilter else { return }
                var refreshed = cell.defaultContentConfiguration()
                refreshed.text = option.sheetTitle
                refreshed.image = image
                refreshed.imageProperties.maximumSize = CGSize(width: 32, height: 32)
                refreshed.imageProperties.cornerRadius = 16
                cell.contentConfiguration = refreshed
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let option = filtered[indexPath.row]
        // Selecting the active refinement clears it — same toggle language
        // as the pills.
        onSelect(option.subFilter == selected ? nil : option.subFilter)
        dismiss(animated: true)
    }
}

extension MapSubFilterSheetViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        filtered = query.isEmpty
            ? options
            : options.filter { $0.sheetTitle.localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
    }
}
