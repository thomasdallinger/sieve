import Foundation

public enum SortKey: String, CaseIterable, Codable, Sendable {
    case relevance, name, kind, modified, created, added, size

    public var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .added: return "Date Added"
        case .size: return "Size"
        }
    }

    /// The direction people expect when they first pick a key: names A→Z, dates newest first, sizes largest first.
    public var naturalAscending: Bool {
        switch self {
        case .name, .kind, .relevance: return true
        case .modified, .created, .added, .size: return false
        }
    }

    /// Short label for the direction button, phrased in the key's own terms.
    public func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name, .kind: return ascending ? "A → Z" : "Z → A"
        case .modified, .created, .added: return ascending ? "Oldest first" : "Newest first"
        case .size: return ascending ? "Smallest first" : "Largest first"
        case .relevance: return "Best first"
        }
    }

    public static let browsingKeys: [SortKey] = [.name, .kind, .modified, .created, .added, .size]
}

public struct SortRule: Codable, Equatable, Sendable {
    public var key: SortKey
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: SortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// Picking the key that is already active flips direction; picking a new key uses its natural direction.
    public mutating func select(_ newKey: SortKey) {
        if newKey == key { ascending.toggle() } else { key = newKey; ascending = newKey.naturalAscending }
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        let key = self.key == .relevance ? .name : self.key
        let asc = ascending, foldersFirst = self.foldersFirst
        return items.sorted { a, b in
            if foldersFirst && a.isContainer != b.isContainer { return a.isContainer }
            let c = Self.compare(a, b, key)
            if c != 0 { return asc ? c < 0 : c > 0 }
            // Ties always fall back to name A→Z so the order is stable and predictable.
            return TextFold.naturalCompare(a.folded, b.folded) < 0
        }
    }

    static func compare(_ a: FileItem, _ b: FileItem, _ key: SortKey) -> Int {
        switch key {
        case .name, .relevance: return TextFold.naturalCompare(a.folded, b.folded)
        case .kind:
            let ka = a.isContainer ? "" : a.ext, kb = b.isContainer ? "" : b.ext
            return ka == kb ? 0 : (ka < kb ? -1 : 1)
        case .modified: return cmp(a.modified, b.modified)
        case .created: return cmp(a.created, b.created)
        case .added: return cmp(a.added, b.added)
        case .size: return cmp(a.size, b.size)
        }
    }

    @inline(__always) static func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a == b ? 0 : (a < b ? -1 : 1) }
}

public enum DateFilter: String, CaseIterable, Codable, Sendable {
    case any, today, week, month, year, older

    public var title: String {
        switch self {
        case .any: return "Any time"
        case .today: return "Today"
        case .week: return "Past 7 days"
        case .month: return "Past 30 days"
        case .year: return "Past year"
        case .older: return "Older than a year"
        }
    }

    func matches(_ modified: Double, now: Double) -> Bool {
        switch self {
        case .any: return true
        case .today: return modified >= Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        case .week: return modified >= now - 7 * 86400
        case .month: return modified >= now - 30 * 86400
        case .year: return modified >= now - 365 * 86400
        case .older: return modified < now - 365 * 86400
        }
    }
}

public enum SizeFilter: String, CaseIterable, Codable, Sendable {
    case any, under1MB, over1MB, over100MB, over1GB

    public var title: String {
        switch self {
        case .any: return "Any size"
        case .under1MB: return "Under 1 MB"
        case .over1MB: return "Over 1 MB"
        case .over100MB: return "Over 100 MB"
        case .over1GB: return "Over 1 GB"
        }
    }

    func matches(_ size: Int64) -> Bool {
        switch self {
        case .any: return true
        case .under1MB: return size < 1_000_000
        case .over1MB: return size >= 1_000_000
        case .over100MB: return size >= 100_000_000
        case .over1GB: return size >= 1_000_000_000
        }
    }
}

public struct FilterOptions: Codable, Equatable, Sendable {
    /// Empty means every kind.
    public var categories: Set<FileCategory> = []
    public var date: DateFilter = .any
    public var size: SizeFilter = .any
    public var showHidden = false

    public init() {}

    /// Number of active constraints, shown as a badge on the filter button.
    public var activeCount: Int {
        (categories.isEmpty ? 0 : 1) + (date == .any ? 0 : 1) + (size == .any ? 0 : 1)
    }
    public var isActive: Bool { activeCount > 0 }

    public mutating func clear() {
        categories = []; date = .any; size = .any
    }

    /// While browsing, folders stay visible under kind/size filters so you can still drill into them;
    /// in search results they only appear when the Folders kind is selected (or no kind is).
    public func matches(_ item: FileItem, browsing: Bool, now: Double = Date().timeIntervalSince1970) -> Bool {
        if !showHidden && item.isHidden { return false }
        if item.isContainer {
            if browsing { return true }
            if !categories.isEmpty && !categories.contains(.folder) { return false }
            return date.matches(item.modified, now: now)
        }
        if !categories.isEmpty && categories.isDisjoint(with: item.categories) { return false }
        return date.matches(item.modified, now: now) && size.matches(item.size)
    }
}
