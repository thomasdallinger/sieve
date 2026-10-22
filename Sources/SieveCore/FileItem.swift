import Darwin
import Foundation

/// One file or folder as the UI sees it. Immutable snapshot of the attributes read from disk.
public final class FileItem: Hashable, @unchecked Sendable {
    public let path: String
    public let name: String
    public let type: EntryType
    /// Directory you can open (a real folder, or a symlink that points at one). Packages such as .app are not.
    public let isContainer: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64
    public let created: Double
    public let modified: Double
    public let added: Double
    /// Lowercase extension, "" for none. Shown for every file, always.
    public let ext: String
    /// Folded name used for natural sorting and matching.
    public let folded: [UInt8]

    public init(path: String, name: String, type: EntryType, isContainer: Bool, isPackage: Bool, isHidden: Bool,
                size: Int64, created: Double, modified: Double, added: Double) {
        self.path = path
        self.name = name
        self.type = type
        self.isContainer = isContainer
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.created = created
        self.modified = modified
        self.added = added
        self.ext = FileCategory.pathExtension(of: name)
        self.folded = TextFold.fold(name)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: type == .directory) }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }
    public var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    public var createdDate: Date { Date(timeIntervalSince1970: created) }
    public var addedDate: Date? { added > 0 ? Date(timeIntervalSince1970: added) : nil }

    public lazy var categories: Set<FileCategory> = {
        if isContainer { return [.folder] }
        var c = FileCategory.categories(forExtension: ext)
        if isPackage && ext == "app" { c.insert(.app) }
        return c
    }()

    /// Name split for display: the stem in primary text and the extension (with its dot) in secondary text.
    /// Folders keep their whole name as the stem; dots inside a folder name are not an extension.
    public var displayParts: (stem: String, ext: String) {
        if isContainer || ext.isEmpty { return (name, "") }
        let cut = name.index(name.endIndex, offsetBy: -(ext.count + 1))
        return (String(name[..<cut]), String(name[cut...]))
    }

    public static func == (a: FileItem, b: FileItem) -> Bool { a.path == b.path }
    public func hash(into h: inout Hasher) { h.combine(path) }

    /// Reads the item at `path` (used for single files, e.g. after a rename or for search hits).
    public static func at(path: String) -> FileItem? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        let type: EntryType
        switch st.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFREG: type = .file
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        let ext = FileCategory.pathExtension(of: name)
        let isPackage = type == .directory && PackageTypes.isPackage(extension: ext)
        var isContainer = type == .directory && !isPackage
        if type == .symlink { isContainer = DirectoryListing.symlinkPointsToDirectory(path) }
        func secs(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        return FileItem(path: path, name: name, type: type, isContainer: isContainer, isPackage: isPackage,
                        isHidden: name.hasPrefix(".") || st.st_flags & UInt32(UF_HIDDEN) != 0,
                        size: type == .file ? Int64(st.st_size) : 0, created: secs(st.st_birthtimespec),
                        modified: secs(st.st_mtimespec), added: 0)
    }
}

public enum DirectoryListing {
    /// All entries of a directory, hidden ones included (the view decides whether to show them).
    public static func load(_ path: String) throws -> [FileItem] {
        var items: [FileItem] = []
        items.reserveCapacity(64)
        let base = path == "/" ? "" : path
        try DirectoryReader.scan(path) { raw in
            let name = String(decoding: raw.name, as: UTF8.self)
            let full = base + "/" + name
            let ext = FileCategory.pathExtension(of: name)
            let isPackage = raw.type == .directory && PackageTypes.isPackage(extension: ext)
            var isContainer = raw.type == .directory && !isPackage
            if raw.type == .symlink { isContainer = symlinkPointsToDirectory(full) }
            items.append(FileItem(path: full, name: name, type: raw.type, isContainer: isContainer, isPackage: isPackage,
                                  isHidden: raw.isHidden, size: raw.size, created: raw.created, modified: raw.modified,
                                  added: raw.added))
        }
        return items
    }

    static func symlinkPointsToDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }
}
