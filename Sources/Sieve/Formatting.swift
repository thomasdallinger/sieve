import AppKit
import SieveCore
import UniformTypeIdentifiers

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()
    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    static func size(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    /// "Today 14:02", "Yesterday 09:10", "3 Mar 2024".
    static func date(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: seconds)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today " + timeFormatter.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday " + timeFormatter.string(from: date) }
        return dateFormatter.string(from: date)
    }

    static func longDate(_ seconds: Double) -> String {
        seconds > 0 ? longFormatter.string(from: Date(timeIntervalSince1970: seconds)) : "—"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    private static var kindCache: [String: String] = [:]
    /// Names UTType gets wrong or leaves as "data" for everyday developer files.
    private static let developerKinds: [String: String] = [
        "ts": "TypeScript", "tsx": "TypeScript JSX", "mts": "TypeScript", "cts": "TypeScript", "jsx": "JavaScript JSX",
        "svelte": "Svelte component", "vue": "Vue component", "astro": "Astro component", "lock": "Lockfile",
        "env": "Environment file", "toml": "TOML", "rs": "Rust source", "go": "Go source", "kt": "Kotlin source",
    ]

    /// Finder-style kind name ("PDF document", "Folder", "Application").
    static func kind(_ item: FileItem) -> String {
        if item.isContainer { return item.type == .symlink ? "Symbolic Link" : "Folder" }
        let key = item.ext + (item.isPackage ? "/pkg" : "")
        if let hit = kindCache[key] { return hit }
        if let name = developerKinds[item.ext] { return name }
        let type = item.ext.isEmpty ? (item.isPackage ? UTType.package : .data)
            : UTType(filenameExtension: item.ext, conformingTo: item.isPackage ? .package : .data) ?? .data
        let name = type.localizedDescription ?? (item.ext.uppercased() + " file")
        kindCache[key] = name
        return name
    }

    /// Path shown relative to the home folder ("~/Documents/Taxes").
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
