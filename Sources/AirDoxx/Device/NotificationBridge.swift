import AppKit
import UserNotifications

/// Shows the phone's notifications as macOS notifications (like Phone Link on Windows).
/// It reads `dumpsys notification` over adb every few seconds, forwards new alerts (not ongoing /
/// silent / summary ones), and opens the app on the phone when a Mac notification is clicked.
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    struct PhoneNotification {
        var key = ""
        var pkg = ""
        var title = ""
        var text = ""
        var when = ""
        var flags = ""
        var importance = ""
    }

    /// Called (main thread) when the user clicks a forwarded notification.
    var onOpen: ((_ package: String) -> Void)?
    /// Called (main thread) when a one-time verification code is detected in a notification.
    var onCode: ((_ code: String, _ app: String) -> Void)?
    var copyCodes = true

    private var serial: String?
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var seen: [String: String] = [:]   // key -> fingerprint (when + text)
    private var primed = false
    private let lock = NSLock()

    /// Privacy-safe diagnostics (counts and package names only): ~/Library/Logs/AirDoxx/notifications.log
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AirDoxx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notifications.log")
    }()

    static func log(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Opens AirDoxx's own page in System Settings › Notifications.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.shanmuckh.airdoxx"
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension"]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// true when macOS has notifications turned off for AirDoxx (it won't ask again).
    static func isDenied(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus == .denied) }
        }
    }

    static func permissionStatus(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus == .authorized) }
        }
    }

    func start(serial: String) {
        lock.lock()
        let same = self.serial == serial
        self.serial = serial
        if !same { seen = [:]; primed = false }
        lock.unlock()
        Self.log("bridge start for \(serial)")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Self.log("mac notification permission: \(settings.authorizationStatus.rawValue) (2=authorized) alerts=\(settings.alertSetting.rawValue)")
        }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 4)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Posts a notification on the phone (via adb) to check the whole phone -> Mac path.
    static func sendTestNotification(serial: String) {
        DispatchQueue.global().async {
            _ = try? ADB.shared.run(["shell", "cmd", "notification", "post", "-t", "'AirDoxx'", "airdoxx_test_\(Int(Date().timeIntervalSince1970))",
                                     "'Notifications from your phone will appear here.'"], serial: serial, timeout: 8)
            log("test notification posted on phone")
        }
    }

    private func poll() {
        lock.lock()
        guard !busy, let serial else { lock.unlock(); return }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }

        // Filter on the phone so only the relevant lines cross the network.
        let pattern = "NotificationRecord\\(|^      flags=|^      mImportance=|^            when=|android\\.(title|text|bigText)="
        guard let out = try? ADB.shared.run(["shell", "dumpsys notification --noredact | grep -E '\(pattern)'"],
                                            serial: serial, timeout: 8) else {
            Self.log("poll failed (adb)")
            return
        }
        let records = Self.parse(out)

        lock.lock()
        let firstPass = !primed
        primed = true
        var fresh: [PhoneNotification] = []
        var current: [String: String] = [:]
        for n in records {
            let fingerprint = n.when + "|" + n.text
            current[n.key] = fingerprint
            if !firstPass, seen[n.key] != fingerprint, Self.shouldForward(n) { fresh.append(n) }
        }
        seen = current
        lock.unlock()

        if firstPass { Self.log("primed with \(records.count) existing notifications") }
        if !fresh.isEmpty { Self.log("forwarding \(fresh.count): \(fresh.map(\.pkg).joined(separator: ", "))") }
        for n in fresh {
            if copyCodes, let code = Self.extractCode(from: "\(n.title) \(n.text)") {
                let app = Self.appName(for: n.pkg)
                DispatchQueue.main.async { self.onCode?(code, app) }
            }
            post(n)
        }
    }

    static func shouldForward(_ n: PhoneNotification) -> Bool {
        if n.title.isEmpty && n.text.isEmpty { return false }
        let skipFlags = ["ONGOING_EVENT", "FOREGROUND_SERVICE", "GROUP_SUMMARY", "SILENT"]
        if skipFlags.contains(where: { n.flags.contains($0) }) { return false }
        if ["MIN", "LOW", "NONE"].contains(n.importance) { return false }
        let systemPackages = ["android", "com.android.systemui"]
        return !systemPackages.contains(n.pkg)
    }

    static func parse(_ dump: String) -> [PhoneNotification] {
        var records: [PhoneNotification] = []
        var cur: PhoneNotification?
        func value(after marker: String, in line: Substring) -> String? {
            guard let r = line.range(of: marker) else { return nil }
            return String(line[r.upperBound...])
        }
        for line in dump.split(separator: "\n") {
            if line.contains("NotificationRecord(") {
                if let c = cur { records.append(c) }
                var n = PhoneNotification()
                if let pkg = value(after: "pkg=", in: line) { n.pkg = String(pkg.prefix { $0 != " " }) }
                if let key = value(after: " key=", in: line) {
                    n.key = String(key.prefix { $0 != " " && $0 != ":" })
                } else {
                    // Long tags (e.g. WhatsApp) wrap the header before "key=": build one from pkg/id/tag.
                    let id = value(after: " id=", in: line).map { String($0.prefix { $0 != " " }) } ?? "?"
                    let tag = value(after: " tag=", in: line).map { String($0.prefix { $0 != " " }) } ?? ""
                    n.key = "\(n.pkg)|\(id)|\(tag)"
                }
                cur = n
            } else if cur != nil {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("flags=") { cur!.flags = String(t.dropFirst(6)) }
                else if t.hasPrefix("mImportance=") { cur!.importance = String(t.dropFirst(12)) }
                else if t.hasPrefix("when=") { cur!.when = String(t.dropFirst(5)) }
                else if t.hasPrefix("android.title="), cur!.title.isEmpty { cur!.title = extract(t.dropFirst(14)) }
                else if t.hasPrefix("android.bigText=") { cur!.text = extract(t.dropFirst(16)) }
                else if t.hasPrefix("android.text="), cur!.text.isEmpty { cur!.text = extract(t.dropFirst(13)) }
            }
        }
        if let c = cur { records.append(c) }
        return records.filter { !$0.key.isEmpty }
    }

    /// "String (Hello)" / "SpannableString (Hello)" -> "Hello"
    private static func extract(_ raw: Substring) -> String {
        var s = String(raw)
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            s = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        }
        return s == "null" ? "" : s
    }

    private func post(_ n: PhoneNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title.isEmpty ? Self.appName(for: n.pkg) : n.title
        content.subtitle = n.title.isEmpty ? "" : Self.appName(for: n.pkg)
        content.body = n.text
        content.sound = .default
        content.threadIdentifier = n.pkg
        content.userInfo = ["pkg": n.pkg]
        let request = UNNotificationRequest(identifier: "phone-\(n.key)-\(n.when)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log("post failed for \(n.pkg): \(error.localizedDescription)") }
        }
    }

    /// Finds a one-time passcode (OTP) in notification text: a 4–8 digit run near a word like
    /// "code", "OTP", "verification", "password", or "PIN". Avoids plain amounts and phone numbers.
    static func extractCode(from text: String) -> String? {
        let lower = text.lowercased()
        let cues = ["otp", "code", "verification", "verify", "one-time", "one time", "passcode",
                    "password", "2fa", "pin", "login", "sign-in", "sign in", "authenticat"]
        guard cues.contains(where: { lower.contains($0) }) else { return nil }
        // Candidate codes: standalone 4–8 digit groups (optionally with a dash, e.g. 123-456).
        let pattern = "(?<![0-9])([0-9]{3}[- ]?[0-9]{3}|[0-9]{4,8})(?![0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let code = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            // Skip years and obvious non-codes.
            if code.count == 4, let y = Int(code), (1900...2100).contains(y), !lower.contains("code") && !lower.contains("otp") { continue }
            if (4...8).contains(code.count) { return code }
        }
        return nil
    }

    static func appName(for pkg: String) -> String {
        let known: [String: String] = [
            "com.whatsapp": "WhatsApp", "com.whatsapp.w4b": "WhatsApp Business",
            "com.instagram.android": "Instagram", "com.google.android.gm": "Gmail",
            "com.google.android.apps.messaging": "Messages", "com.android.mms": "Messages",
            "com.google.android.dialer": "Phone", "com.android.incallui": "Phone",
            "com.linkedin.android": "LinkedIn", "com.google.android.youtube": "YouTube",
            "org.telegram.messenger": "Telegram", "com.snapchat.android": "Snapchat",
            "com.facebook.katana": "Facebook", "com.facebook.orca": "Messenger",
            "com.twitter.android": "X", "com.spotify.music": "Spotify",
            "com.google.android.calendar": "Calendar", "com.android.deskclock": "Clock",
            "com.google.android.apps.nbu.paisa.user": "Google Pay", "com.phonepe.app": "PhonePe",
            "net.one97.paytm": "Paytm", "com.amazon.mShop.android.shopping": "Amazon",
            "in.swiggy.android": "Swiggy", "com.application.zomato": "Zomato",
            "com.jio.myjio": "MyJio", "com.chess": "Chess.com", "com.leetcode.android": "LeetCode",
            "com.google.android.googlequicksearchbox": "Google", "com.discord": "Discord",
            "com.slack": "Slack", "com.microsoft.teams": "Teams", "com.truecaller": "Truecaller",
        ]
        if let name = known[pkg] { return name }
        let last = pkg.split(separator: ".").last.map(String.init) ?? pkg
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pkg = response.notification.request.content.userInfo["pkg"] as? String {
            DispatchQueue.main.async { self.onOpen?(pkg) }
        }
        completionHandler()
    }
}
