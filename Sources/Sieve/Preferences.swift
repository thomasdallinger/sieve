import AppKit
import Combine
import SieveCore

enum ViewMode: String, CaseIterable {
    case columns, list

    var title: String { self == .columns ? "Columns" : "List" }
    var symbol: String { self == .columns ? "rectangle.split.3x1" : "list.bullet" }
}

/// App-wide view options. Sorting and filtering are global on purpose: one rule everywhere, no per-folder
/// surprises like Finder's hidden .DS_Store view settings.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var sort: SortRule { didSet { save(sort, "sort") } }
    /// Separate order for search results, so searching never rewrites how folders are sorted.
    @Published var searchSort: SortRule { didSet { save(searchSort, "searchSort") } }
    @Published var filter: FilterOptions { didSet { save(filter, "filter") } }
    @Published var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: "viewMode") } }
    @Published var showFilterBar: Bool { didSet { defaults.set(showFilterBar, forKey: "showFilterBar") } }
    @Published var showPreview: Bool { didSet { defaults.set(showPreview, forKey: "showPreview") } }
    @Published var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var modelName: String { didSet { defaults.set(modelName, forKey: "modelName") } }
    @Published var favorites: [String] { didSet { defaults.set(favorites, forKey: "favorites") } }
    @Published var excludedNames: [String] { didSet { defaults.set(excludedNames, forKey: "excludedNames") } }
    @Published var columnWidth: Double { didSet { defaults.set(columnWidth, forKey: "columnWidth") } }

    private init() {
        sort = Self.load("sort") ?? SortRule()
        searchSort = Self.load("searchSort") ?? SortRule(key: .relevance, ascending: true, foldersFirst: false)
        filter = Self.load("filter") ?? FilterOptions()
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .columns
        showFilterBar = defaults.object(forKey: "showFilterBar") as? Bool ?? true
        showPreview = defaults.object(forKey: "showPreview") as? Bool ?? true
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        modelName = defaults.string(forKey: "modelName") ?? LocalModel.defaultModel
        let home = NSHomeDirectory()
        favorites = defaults.stringArray(forKey: "favorites")
            ?? [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        excludedNames = defaults.stringArray(forKey: "excludedNames") ?? IndexExclusions.defaultNames.sorted()
        columnWidth = defaults.object(forKey: "columnWidth") as? Double ?? 248
    }

    var exclusions: IndexExclusions {
        IndexExclusions(names: Set(excludedNames), paths: IndexExclusions.standard().paths)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
