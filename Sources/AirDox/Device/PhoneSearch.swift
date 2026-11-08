import Foundation

/// F4 / Spotlight key behaviour on the phone:
/// - an app is open and shows a search box/button -> tap it (in-app search)
/// - home screen, or the app has no visible search -> open the phone's app/global search
enum PhoneSearch {
    private static var homePackages: [String: String] = [:]
    private static let lock = NSLock()

    static func run(serial: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let message = search(serial: serial)
            DispatchQueue.main.async { completion(message) }
        }
    }

    private static func search(serial: String) -> String {
        let focused = focusedPackage(serial: serial)
        let home = homePackage(serial: serial)
        if let focused, focused != home, focused != "com.android.systemui",
           let point = findSearchControl(serial: serial) {
            _ = try? ADB.shared.run(["shell", "input", "tap", "\(point.x)", "\(point.y)"], serial: serial, timeout: 5)
            return "Search"
        }
        return openAppSearch(serial: serial)
    }

    private static func focusedPackage(serial: String) -> String? {
        guard let out = try? ADB.shared.run(["shell", "dumpsys", "window"], serial: serial, timeout: 5) else { return nil }
        var result: String?
        for line in out.split(separator: "\n") where line.contains("mCurrentFocus=Window{") {
            // mCurrentFocus=Window{1b78f9 u0 com.example.app/com.example.MainActivity}
            let parts = line.split(separator: " ")
            if let comp = parts.last(where: { $0.contains("/") }) {
                result = String(comp.split(separator: "/").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "}"))
            } else if let last = parts.last {
                result = String(last).trimmingCharacters(in: CharacterSet(charactersIn: "}"))
            }
        }
        return result
    }

    private static func homePackage(serial: String) -> String? {
        lock.lock()
        if let cached = homePackages[serial] { lock.unlock(); return cached }
        lock.unlock()
        guard let out = try? ADB.shared.run(["shell", "cmd", "package", "resolve-activity", "--brief",
                                             "-c", "android.intent.category.HOME",
                                             "-a", "android.intent.action.MAIN"], serial: serial, timeout: 5),
              let last = out.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces),
              let pkg = last.split(separator: "/").first.map(String.init) else { return nil }
        lock.lock(); homePackages[serial] = pkg; lock.unlock()
        return pkg
    }

    /// Dumps the current UI and returns the centre (in physical screen pixels) of the best
    /// search field or search button, if there is one.
    private static func findSearchControl(serial: String) -> (x: Int, y: Int)? {
        let path = "/data/local/tmp/am_ui.xml"
        guard (try? ADB.shared.run(["shell", "uiautomator", "dump", "--compressed", path], serial: serial, timeout: 8)) != nil,
              let xml = try? ADB.shared.run(["shell", "cat", path], serial: serial, timeout: 5) else { return nil }

        struct Candidate { let score: Int; let x: Int; let y: Int }
        var best: Candidate?
        for raw in xml.components(separatedBy: "<node ").dropFirst() {
            let node = String(raw.prefix(while: { $0 != ">" }))
            func attr(_ name: String) -> String {
                guard let r = node.range(of: "\(name)=\"") else { return "" }
                return String(node[r.upperBound...].prefix(while: { $0 != "\"" }))
            }
            let id = attr("resource-id").lowercased()
            let desc = attr("content-desc").lowercased()
            let text = attr("text").lowercased()
            let cls = attr("class")
            let isEditText = cls.hasSuffix("EditText") || cls.contains("SearchView") || cls.contains("AutoCompleteTextView")
            let mentionsSearch = id.contains("search") || desc.contains("search") || text.hasPrefix("search")
            guard mentionsSearch, attr("enabled") != "false" else { continue }
            guard attr("clickable") == "true" || isEditText else { continue }
            guard let bounds = parseBounds(attr("bounds")), bounds.w > 4, bounds.h > 4 else { continue }

            var score = 1
            if isEditText { score += 4 }
            if desc == "search" || text == "search" { score += 3 }
            if id.hasSuffix("search") || id.contains("search_bar") || id.contains("search_box") || id.contains("search_button") { score += 2 }
            if id.contains("voice") || desc.contains("voice") || id.contains("clear") { score -= 5 }
            // Prefer controls near the top of the screen, where search usually lives.
            if bounds.y < 600 { score += 1 }
            if best == nil || score > best!.score {
                best = Candidate(score: score, x: bounds.x + bounds.w / 2, y: bounds.y + bounds.h / 2)
            }
        }
        guard let best, best.score > 0 else { return nil }
        return (best.x, best.y)
    }

    private static func parseBounds(_ s: String) -> (x: Int, y: Int, w: Int, h: Int)? {
        // "[x1,y1][x2,y2]"
        let nums = s.split(whereSeparator: { "[],".contains($0) }).compactMap { Int($0) }
        guard nums.count == 4 else { return nil }
        return (nums[0], nums[1], nums[2] - nums[0], nums[3] - nums[1])
    }

    /// Opens the phone's own search (which also finds installed apps).
    private static func openAppSearch(serial: String) -> String {
        let adb = ADB.shared
        if let out = try? adb.run(["shell", "am", "start", "-a", "android.search.action.GLOBAL_SEARCH"],
                                  serial: serial, timeout: 6),
           !out.contains("Error") {
            return "Search apps"
        }
        _ = try? adb.run(["shell", "input", "keyevent", "KEYCODE_SEARCH"], serial: serial, timeout: 5)
        return "Search"
    }
}
