import AppKit
import SieveCore
import UniformTypeIdentifiers

/// Icons by type wherever possible (one lookup per extension), per-file only where macOS draws a custom icon:
/// apps, packages and the special folders. Per-file icons load off the main thread.
final class IconProvider {
    static let shared = IconProvider()
    static let didLoad = Notification.Name("SieveIconDidLoad")

    private var byType: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    /// Full-resolution icons for the preview pane and path bar.
    private let fullByPath = NSCache<NSString, NSImage>()
    private var pending = Set<String>()
    private let queue = DispatchQueue(label: "sieve.icons", qos: .userInitiated, attributes: .concurrent)
    private let folder: NSImage
    private let specialFolders: Set<String>

    private init() {
        folder = Self.rowBitmap(NSWorkspace.shared.icon(for: .folder))
        let home = NSHomeDirectory()
        specialFolders = Set(["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
                              "Library", "Sites", "Developer"].map { home + "/" + $0 } + [home, "/Applications", "/System",
                              "/Library", "/Users", "/System/Applications", "/Volumes"])
        byPath.countLimit = 2000
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isContainer && !specialFolders.contains(item.path) && !item.path.hasPrefix("/Volumes/") { return folder }
        if item.isContainer || item.isPackage || item.ext == "app" || item.path.hasPrefix("/Volumes/") && item.parentPath == "/Volumes" {
            return perFile(item)
        }
        let key = item.ext
        if let hit = byType[key] { return hit }
        let type = key.isEmpty ? UTType.data : UTType(filenameExtension: key) ?? .data
        let image = Self.rowBitmap(NSWorkspace.shared.icon(for: type))
        byType[key] = image
        return image
    }

    private func perFile(_ item: FileItem) -> NSImage {
        let key = item.path as NSString
        if let hit = byPath.object(forKey: key) { return hit }
        if !pending.contains(item.path) {
            pending.insert(item.path)
            let path = item.path
            queue.async { [weak self] in
                let icon = NSWorkspace.shared.icon(forFile: path)
                DispatchQueue.main.async {
                    let image = Self.rowBitmap(icon)
                    guard let self else { return }
                    self.byPath.setObject(image, forKey: key)
                    self.pending.remove(path)
                    NotificationCenter.default.post(name: Self.didLoad, object: path)
                }
            }
        }
        let placeholderKey = item.ext == "app" ? "/app" : "/package"
        if let hit = byType[placeholderKey] { return hit }
        let placeholder = Self.rowBitmap(NSWorkspace.shared.icon(for: item.ext == "app" ? .applicationBundle : .package))
        byType[placeholderKey] = placeholder
        return item.isContainer ? folder : placeholder
    }

    /// Workspace icons are multi-resolution "icon family" images; handing one to an image view makes AppKit
    /// resolve and composite it on every assignment. Rendering once into a small bitmap (row size at 1× and 2×)
    /// keeps scrolling through 20,000 rows smooth.
    static func rowBitmap(_ icon: NSImage, points: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2] as [CGFloat] {
            let pixels = Int(points * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    func icon(forPath path: String) -> NSImage {
        if let hit = fullByPath.object(forKey: path as NSString) { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        fullByPath.setObject(image, forKey: path as NSString)
        return image
    }
}
