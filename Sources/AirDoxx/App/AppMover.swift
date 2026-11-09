import AppKit

/// First launch from a downloaded DMG / Downloads folder: offer to move AirDoxx into /Applications,
/// then relaunch from there (and eject the disk image it came from).
enum AppMover {
    static func offerMoveIfNeeded() {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path
        let defaults = UserDefaults.standard
        guard path.hasSuffix(".app"),
              !path.hasPrefix("/Applications/"),
              !isDevelopmentBuild(bundleURL),
              !defaults.bool(forKey: "moveToApplicationsSuppressed") else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move AirDoxx to the Applications folder?"
        alert.informativeText = "AirDoxx works best from Applications – it'll stay up to date there and show up in Launchpad and Spotlight."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: "moveToApplicationsSuppressed") }
        guard response == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                // Quit a copy that's already running from Applications, then put the old one in the Trash.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                where app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                    app.terminate()
                }
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't move AirDoxx"
            fail.informativeText = "Drag AirDoxx into the Applications folder in Finder instead.\n\n\(error.localizedDescription)"
            fail.runModal()
            return
        }

        let volume = mountedVolume(for: bundleURL)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async {
                if let volume { try? NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                NSApp.terminate(nil)
            }
        }
    }

    /// Builds run from the project folder (build/ or .build/) never ask.
    private static func isDevelopmentBuild(_ url: URL) -> Bool {
        if ProcessInfo.processInfo.environment["AIRDOXX_DEV"] != nil { return true }
        let parent = url.deletingLastPathComponent()
        let project = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path)
            || url.path.contains("/.build/")
    }

    /// The disk image volume the app is running from, if any (so it can be ejected after moving).
    private static func mountedVolume(for url: URL) -> URL? {
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count > 2, comps[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(comps[2])")
    }
}
