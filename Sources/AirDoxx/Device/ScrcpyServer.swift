import Foundation

/// Locates the scrcpy server binary (pushed to the phone) and figures out its exact version,
/// which must be passed as the first server argument.
struct ScrcpyServer {
    let url: URL
    let version: String

    static let remotePath = "/data/local/tmp/scrcpy-server.jar"

    static func locate() -> ScrcpyServer? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        if let p = env["SCRCPY_SERVER_PATH"], fm.fileExists(atPath: p) {
            let url = URL(fileURLWithPath: p)
            if let v = env["SCRCPY_SERVER_VERSION"] ?? versionFromPath(url) {
                return ScrcpyServer(url: url, version: v)
            }
        }

        if let res = Bundle.main.resourceURL {
            let url = res.appendingPathComponent("scrcpy-server")
            let versionURL = res.appendingPathComponent("scrcpy-server.version")
            if fm.fileExists(atPath: url.path),
               let v = try? String(contentsOf: versionURL, encoding: .utf8).trimmed, !v.isEmpty {
                return ScrcpyServer(url: url, version: v)
            }
        }

        for p in ["/opt/homebrew/share/scrcpy/scrcpy-server", "/usr/local/share/scrcpy/scrcpy-server"] {
            let url = URL(fileURLWithPath: p)
            guard fm.fileExists(atPath: p) else { continue }
            if let v = versionFromPath(url) { return ScrcpyServer(url: url, version: v) }
        }
        return nil
    }

    /// Homebrew installs into .../Cellar/scrcpy/<version>[_<revision>]/share/scrcpy/scrcpy-server.
    private static func versionFromPath(_ url: URL) -> String? {
        let comps = url.resolvingSymlinksInPath().pathComponents
        guard let i = comps.firstIndex(of: "scrcpy"), i > 0, comps[i - 1] == "Cellar", i + 1 < comps.count else {
            return nil
        }
        var v = comps[i + 1]
        if let underscore = v.firstIndex(of: "_") { v = String(v[..<underscore]) }
        return v
    }
}
