#if DEBUG || SCENARIO
import AppKit
import SieveCore

/// Debug-only scenario runner for verifying the UI without Screen Recording permission.
///
///     SIEVE_SCENARIO=steps.txt .build/debug/Sieve
///
/// One command per line: `wait <s>`, `go <path>`, `search <text>`, `mode columns|list`, `key <name>`
/// (down, up, left, right, return, space, escape), `select <path>`, `recents`, `filter <kind|none>`,
/// `sort <key>`, `action <selector>` (menu action, e.g. newFolder), `type <text>` (into the active text field),
/// `appearance light|dark`, `fileviewer on|off` (Sieve as the default file viewer), `index <path>`, `bench <path>`,
/// `dump`, `shot <file.png>` (renders the window in-process), `shotwin <title> <file.png>` (any window by title), `quit`.
enum DebugScenario {
    static func runIfRequested() {
        guard let file = ProcessInfo.processInfo.environment["SIEVE_SCENARIO"],
              let text = try? String(contentsOfFile: file) else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        run(steps[...])
    }

    private static func run(_ steps: ArraySlice<String>) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0], arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.35
        let controller = NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.first
        print("▶ \(step)")
        switch command {
        case "wait": delay = Double(arg) ?? 1
        case "go": controller?.navigate(to: (arg as NSString).expandingTildeInPath)
        case "search": controller?.setSearchText(arg)
        case "mode": controller?.setViewMode(arg == "list" ? .list : .columns, focus: true)
        case "recents": controller?.showRecents()
        case "filter":
            Preferences.shared.filter.categories = FileCategory(rawValue: arg).map { [$0] } ?? []
        case "hidden": Preferences.shared.filter.showHidden = arg == "on"
        case "fileviewer":
            DefaultFileViewer.setEnabled(arg == "on")
            print("  NSFileViewer = \(DefaultFileViewer.current ?? "Finder") enabled \(DefaultFileViewer.isEnabled)")
        case "sort":
            if let key = SortKey(rawValue: arg) { Preferences.shared.sort.select(key) }
        case "searchsort":
            if let key = SortKey(rawValue: arg) { Preferences.shared.searchSort.select(key) }
        case "focus": controller?.current.focusContent()
        case "appearance": NSApp.appearance = NSAppearance(named: arg == "light" ? .aqua : .darkAqua)
        case "action":
            // Destructive actions only ever run on scratch files under /tmp or /private/tmp.
            let destructive = ["moveToTrash", "pasteMove", "duplicate", "paste", "newFolder"].contains(arg)
            let paths = (controller?.current.selectedItems.map(\.path) ?? []) + [controller?.current.targetDirectory ?? ""]
            if destructive && !paths.allSatisfy({ $0.hasPrefix("/private/tmp/") || $0.hasPrefix("/tmp/") }) {
                print("  refused: \(arg) outside /tmp (\(paths))")
            } else {
                NSApp.sendAction(Selector(arg + ":"), to: nil, from: nil)
            }
        case "type":
            if let editor = controller?.window?.firstResponder as? NSTextView { editor.insertText(arg, replacementRange: editor.selectedRange()) }
        case "select":
            if let path = Optional((arg as NSString).expandingTildeInPath), let c = controller, c.current === c.columns {
                c.navigate(to: path); c.current.focusContent()
            }
        case "key": sendKey(arg, to: controller?.window)
        case "bench":
            let start = CFAbsoluteTimeGetCurrent()
            controller?.navigate(to: (arg as NSString).expandingTildeInPath)
            controller?.window?.contentView?.layoutSubtreeIfNeeded()
            controller?.window?.displayIfNeeded()
            print(String(format: "  navigate + layout + draw: %.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        case "index":
            if let manager = (NSApp.delegate as? AppDelegate)?.indexManager {
                let path = (arg as NSString).expandingTildeInPath
                print("  entries \(manager.main.count) building \(manager.main.isBuilding) id(\(path)) = \(String(describing: manager.main.id(forDirectory: path)))")
            }
        case "windows":
            let browsers = NSApp.windows.filter { $0.windowController is BrowserWindowController }
            print("  browser windows: \(browsers.count), tabs in key group: \(NSApp.keyWindow?.tabbedWindows?.count ?? 1)")
        case "dump": dump(controller)
        case "shot": shot(controller?.window, to: arg)
        case "shotwin":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            shot(NSApp.windows.first { $0.title.contains(parts[0]) && $0.isVisible }, to: parts.count > 1 ? parts[1] : "/tmp/window.png")
        case "quit": NSApp.terminate(nil); return
        default: print("  unknown command")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(rest) }
    }

    private static func sendKey(_ name: String, to window: NSWindow?) {
        let codes: [String: (UInt16, String)] = [
            "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
            "return": (36, "\r"), "space": (49, " "), "escape": (53, "\u{1B}"),
        ]
        guard let window, let (code, chars) = codes[name],
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    private static func dump(_ c: BrowserWindowController?) {
        guard let c else { print("  no window"); return }
        print("  title: \(c.window?.title ?? "")")
        print("  content: \(type(of: c.current)) · first responder: \(type(of: c.window?.firstResponder as Any))")
        print("  status: \(c.statusBar.status.stringValue)")
        print("  selected: \(c.current.selectedItems.map(\.name))")
        print("  location: \(c.location) back: \(c.back.map { $0.selected ?? $0.root })")
        if c.current === c.columns {
            for column in c.columns.columns {
                let names = column.items.prefix(8).map(\.name).joined(separator: ", ")
                print("  column \(Format.displayPath(column.path)) [\(column.items.count)] sel=\(column.selectedItems.map(\.name)): \(names)")
            }
        }
        if let table = findTable(in: c.current.view) {
            var lines: [String] = []
            for row in 0..<min(table.numberOfRows, 14) {
                let views = (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: row, makeIfNecessary: true) }
                let text = views.flatMap(texts).filter { !$0.isEmpty }.joined(separator: " | ")
                lines.append("    \(row): \(text)")
            }
            print("  rows (\(table.numberOfRows)):\n" + lines.joined(separator: "\n"))
        }
    }

    private static func texts(_ view: NSView) -> [String] {
        if let f = view as? NSTextField, !f.isHidden { return [f.stringValue] }
        if let b = view as? NSButton, !b.isHidden { return ["[\(b.title)]"] }
        return view.subviews.flatMap(texts)
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView, !t.isHiddenOrHasHiddenAncestor { return t }
        for sub in view.subviews { if let t = findTable(in: sub) { return t } }
        return nil
    }

    private static func shot(_ window: NSWindow?, to path: String) {
        guard let frameView = window?.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }
}
#endif
