import Foundation
import UniformTypeIdentifiers

/// The coarse buckets the filter bar offers. A file can be in several (a PDF is a Document and a PDF).
public enum FileCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case folder, document, pdf, image, video, audio, archive, code, app

    public var title: String {
        switch self {
        case .folder: return "Folders"
        case .document: return "Documents"
        case .pdf: return "PDFs"
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .archive: return "Archives"
        case .code: return "Code"
        case .app: return "Apps"
        }
    }

    public var symbol: String {
        switch self {
        case .folder: return "folder"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .app: return "app.dashed"
        }
    }

    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "go", "rs", "java", "kt", "kts", "scala", "py", "rb",
        "php", "js", "mjs", "cjs", "ts", "tsx", "jsx", "svelte", "vue", "astro", "css", "scss", "sass", "less", "html",
        "htm", "json", "jsonc", "yaml", "yml", "toml", "xml", "plist", "sh", "zsh", "bash", "fish", "sql", "graphql",
        "gql", "lua", "dart", "ex", "exs", "erl", "hs", "clj", "zig", "nim", "r", "pl", "gradle", "proto", "tf",
        "dockerfile", "makefile", "cmake", "ini", "env", "lock", "ipynb",
    ]
    private static let documentExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "pages", "odt", "xls", "xlsx", "numbers", "ods", "csv",
        "tsv", "ppt", "pptx", "key", "odp", "pdf", "epub", "tex", "log",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "zst", "lz4", "cab", "jar", "xip",
    ]

    private static let lock = NSLock()
    private static var cache: [String: Set<FileCategory>] = [:]

    /// Categories for a file with the given lowercase extension (folders are classified by the caller).
    public static func categories(forExtension ext: String) -> Set<FileCategory> {
        lock.lock()
        if let hit = cache[ext] { lock.unlock(); return hit }
        lock.unlock()
        let result = classify(ext)
        lock.lock(); cache[ext] = result; lock.unlock()
        return result
    }

    private static func classify(_ ext: String) -> Set<FileCategory> {
        var out: Set<FileCategory> = []
        if ext.isEmpty { return out }
        if codeExtensions.contains(ext) { out.insert(.code) }
        if documentExtensions.contains(ext) { out.insert(.document) }
        if ext == "pdf" { out.insert(.pdf) }
        if archiveExtensions.contains(ext) { out.insert(.archive) }
        if ext == "app" { out.insert(.app) }
        // In a file browser for people who write code, .ts is TypeScript, not an MPEG transport stream.
        if codeExtensions.contains(ext) && !["svg", "html", "htm"].contains(ext) { return out }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { out.insert(.image) }
            if type.conforms(to: .movie) || type.conforms(to: .video) { out.insert(.video) }
            if type.conforms(to: .audio) { out.insert(.audio) }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) { out.insert(.archive) }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { out.insert(.code) }
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { out.insert(.app) }
            if out.isEmpty, type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
                out.insert(.document)
            }
        }
        return out
    }

    /// Lowercase extension of a filename ("" for none, dot-files like ".zshrc" have none).
    public static func pathExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = name[name.index(after: dot)...]
        if ext.isEmpty || ext.count > 16 || ext.contains(" ") { return "" }
        return ext.lowercased()
    }
}

/// Directory extensions macOS shows as single files; we never descend into them when indexing.
public enum PackageTypes {
    private static let known: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "xcodeproj", "xcworkspace", "xcassets", "playground",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "pages",
        "numbers", "key", "rtfd", "sparsebundle", "lproj", "scptd", "prefpane", "qlgenerator", "mdimporter",
        "appex", "xpc", "dSYM", "dsym", "docarchive", "mlmodelc", "mlpackage", "xcarchive", "wdgt", "saver",
    ]
    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    public static func isPackage(extension ext: String) -> Bool {
        if ext.isEmpty { return false }
        if known.contains(ext) { return true }
        lock.lock()
        if let hit = cache[ext] { lock.unlock(); return hit }
        lock.unlock()
        let result = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        lock.lock(); cache[ext] = result; lock.unlock()
        return result
    }
}
