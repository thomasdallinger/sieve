import AppKit

/// Makes Sieve the app macOS reveals files in, through the global `NSFileViewer` default. It covers `open -R`
/// and "Show in Finder" in apps that reveal one item at a time. Each reveal arrives as an ordinary open-documents
/// event, which the app delegate handles.
///
/// Finder stays the app that opens folders: macOS refuses to change the default handler for `public.folder`
/// (LaunchServices answers paramErr), so this is the only switch there is.
enum DefaultFileViewer {
    private static let key = "NSFileViewer" as CFString
    static let finderID = "com.apple.finder"

    /// Nil when running a bare `swift build` binary, which LaunchServices can't launch by bundle id.
    static var bundleID: String? { Bundle.main.bundleIdentifier }

    static var isEnabled: Bool {
        guard let bundleID else { return false }
        return current == bundleID
    }

    /// The app other apps reveal files in, if it isn't Finder.
    static var current: String? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static func setEnabled(_ enabled: Bool) {
        guard let bundleID else { return }
        // Turning it off only clears Sieve's own entry, never another file viewer the user picked since.
        if !enabled, current != bundleID { return }
        let value = enabled ? bundleID as CFString : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Reveals `urls` in Finder itself. NSWorkspace would hand a reveal straight back to Sieve while Sieve is the
    /// file viewer, so this asks Finder directly (macOS asks once for permission to control Finder). If that is
    /// denied, Finder still opens the enclosing folder, just without the selection.
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let finder = NSAppleEventDescriptor(bundleIdentifier: finderID)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAEMiscStandards), eventID: AEEventID(kAEMakeObjectsVisible),
                                           targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for url in urls { list.insert(NSAppleEventDescriptor(fileURL: url), at: 0) }
        event.setParam(list, forKeyword: keyDirectObject)
        // Sending blocks while the permission prompt is up.
        DispatchQueue.global(qos: .userInitiated).async {
            let revealed = (try? event.sendEvent(options: [.waitForReply], timeout: 60)) != nil
            DispatchQueue.main.async {
                if revealed {
                    NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first?.activate()
                } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) {
                    let folder = urls[0].deletingLastPathComponent()
                    NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }
}
