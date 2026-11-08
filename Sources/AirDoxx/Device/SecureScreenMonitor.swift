import Foundation

/// Watches the phone for two states that need its own screen:
/// - the lock screen (so the phone's fingerprint sensor / PIN pad can be used), and
/// - protected windows (payments, banking, PIN prompts), which Android shows as black to any
///   screen capture by design.
final class SecureScreenMonitor {
    struct State: Equatable {
        var locked = false   // keyguard (lock screen) is showing
        var secure = false   // frontmost window is marked secure
    }

    var onChange: ((State) -> Void)?   // main thread
    private let serial: String
    private var timer: DispatchSourceTimer?
    private var busy = false
    private var last = State()

    init(serial: String) { self.serial = serial }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // Filter on the phone to keep the transfer small over Wi-Fi.
        guard let out = try? ADB.shared.run(
            ["shell", "dumpsys window | grep -E 'mCurrentFocus=Window|^  Window #|^ +fl=|isKeyguardShowing='"],
            serial: serial, timeout: 5) else { return }
        let state = State(locked: out.contains("isKeyguardShowing=true"),
                          secure: Self.focusedWindowIsSecure(out))
        guard state != last else { return }
        last = state
        DispatchQueue.main.async { self.onChange?(state) }
    }

    static func focusedWindowIsSecure(_ dump: String) -> Bool {
        // mCurrentFocus=Window{1b78f9 u0 com.example/...}  -> token "1b78f9"
        var focusToken: String?
        for line in dump.split(separator: "\n") where line.contains("mCurrentFocus=Window{") {
            if let r = line.range(of: "Window{") {
                let token = line[r.upperBound...].prefix(while: { $0 != " " && $0 != "}" })
                if !token.isEmpty { focusToken = String(token) }
            }
        }
        guard let focusToken else { return false }
        var inFocused = false
        for line in dump.split(separator: "\n") {
            if line.hasPrefix("  Window #") {
                inFocused = line.contains("Window{\(focusToken) ")
            } else if inFocused,
                      line.trimmingCharacters(in: .whitespaces).hasPrefix("fl="),
                      (" " + line.split(separator: "=", maxSplits: 1).last.map(String.init)! + " ").contains(" SECURE ") {
                return true
            }
        }
        return false
    }
}
