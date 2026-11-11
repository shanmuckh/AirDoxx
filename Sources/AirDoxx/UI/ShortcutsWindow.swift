import AppKit
import SwiftUI

/// A key combination for a menu command. An empty key means "no shortcut".
struct Shortcut: Equatable {
    var key: String
    var mods: UInt

    static let none = Shortcut(key: "", mods: 0)
    static let allowedMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods).intersection(Self.allowedMods) }

    init(key: String, mods: UInt) {
        self.key = key
        self.mods = NSEvent.ModifierFlags(rawValue: mods).intersection(Self.allowedMods).rawValue
    }

    init(item: NSMenuItem) {
        self.init(key: item.keyEquivalent, mods: item.keyEquivalentModifierMask.rawValue)
    }

    var display: String {
        guard !key.isEmpty else { return "None" }
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(key)
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSF1FunctionKey...NSF20FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        case 0x20: return "Space"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        default: return key.uppercased()
        }
    }
}

/// The customisable keyboard shortcuts. Shortcuts live on menu items, so this keeps each
/// command's menu item, its built-in default and the user's override (saved in UserDefaults).
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    struct Action: Identifiable {
        let id: String
        let title: String
        let group: String
        let standard: Shortcut
    }

    @Published private(set) var actions: [Action] = []
    @Published private(set) var overrides: [String: Shortcut] = [:]
    @Published var recording: String?
    @Published var message = ""

    private var items: [String: NSMenuItem] = [:]
    private var monitor: Any?
    private let defaultsKey = "shortcuts"

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
        for (id, value) in saved {
            guard let key = value["key"] as? String, let mods = value["mods"] as? Int else { continue }
            overrides[id] = Shortcut(key: key, mods: UInt(mods))
        }
    }

    /// Registers a menu item as customisable and gives it the user's shortcut, if any.
    @discardableResult
    func register(_ id: String, _ item: NSMenuItem, group: String, title: String? = nil) -> NSMenuItem {
        items[id] = item
        actions.append(Action(id: id, title: title ?? item.title, group: group, standard: Shortcut(item: item)))
        apply(id)
        return item
    }

    var groups: [String] {
        var seen: [String] = []
        for a in actions where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    func shortcut(for id: String) -> Shortcut {
        overrides[id] ?? actions.first { $0.id == id }?.standard ?? .none
    }

    func isCustom(_ id: String) -> Bool { overrides[id] != nil }

    func set(_ id: String, _ shortcut: Shortcut) {
        // One combination, one command: take it away from whoever had it.
        if !shortcut.key.isEmpty {
            for other in actions where other.id != id && self.shortcut(for: other.id) == shortcut {
                overrides[other.id] = Shortcut.none
                apply(other.id)
                message = "\(shortcut.display) moved from “\(other.title)”."
            }
        }
        if shortcut == actions.first(where: { $0.id == id })?.standard {
            overrides[id] = nil
        } else {
            overrides[id] = shortcut
        }
        apply(id)
        save()
    }

    func reset(_ id: String) {
        guard let standard = actions.first(where: { $0.id == id })?.standard else { return }
        set(id, standard)
    }

    func resetAll() {
        overrides = [:]
        for a in actions { apply(a.id) }
        save()
        message = "Shortcuts restored."
    }

    private func apply(_ id: String) {
        guard let item = items[id] else { return }
        let s = shortcut(for: id)
        item.keyEquivalent = s.key
        item.keyEquivalentModifierMask = s.key.isEmpty ? [] : s.flags
    }

    private func save() {
        var out: [String: [String: Any]] = [:]
        for (id, s) in overrides { out[id] = ["key": s.key, "mods": Int(s.mods)] }
        UserDefaults.standard.set(out, forKey: defaultsKey)
    }

    // MARK: - Recording a new combination

    func beginRecording(_ id: String) {
        endRecording()
        recording = id
        message = "Press the new shortcut. Esc cancels, Delete removes it."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let id = self.recording else { return event }
            self.capture(event, for: id)
            return nil   // never let the keystroke reach the menus or the phone
        }
    }

    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func capture(_ event: NSEvent, for id: String) {
        let flags = event.modifierFlags.intersection(Shortcut.allowedMods)
        switch event.keyCode {
        case 53: // esc
            endRecording(); message = ""
            return
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // delete
            set(id, .none)
            endRecording(); message = "Shortcut removed."
            return
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let key = chars.lowercased()
        let isFunctionKey = (chars.unicodeScalars.first.map { Int($0.value) } ?? 0) >= NSF1FunctionKey
            && (chars.unicodeScalars.first.map { Int($0.value) } ?? 0) <= NSF20FunctionKey
        guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else {
            message = "Include ⌘, ⌃ or ⌥ – plain keys are typed on the phone."
            return
        }
        let candidate = Shortcut(key: key, mods: flags.rawValue)
        if let owner = reservedOwner(of: candidate) {
            message = "\(candidate.display) is used by “\(owner)”."
            return
        }
        message = ""
        set(id, candidate)
        endRecording()
    }

    /// A menu command that isn't customisable (Quit, Copy, Paste…) already using this combination.
    private func reservedOwner(of shortcut: Shortcut) -> String? {
        let mine = Set(items.values.map(ObjectIdentifier.init))
        func search(_ menu: NSMenu) -> String? {
            for item in menu.items {
                if let sub = item.submenu, let hit = search(sub) { return hit }
                if !mine.contains(ObjectIdentifier(item)), !item.keyEquivalent.isEmpty,
                   Shortcut(item: item) == shortcut { return item.title }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }
}

struct ShortcutsView: View {
    @ObservedObject var store: ShortcutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.uppercased())
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            ForEach(store.actions.filter { $0.group == group }) { action in
                                row(action)
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(store.message)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Restore Defaults") { store.endRecording(); store.resetAll() }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 560)
    }

    private func row(_ action: ShortcutStore.Action) -> some View {
        let recording = store.recording == action.id
        return HStack(spacing: 10) {
            Text(action.title)
            Spacer()
            if store.isCustom(action.id) && !recording {
                Button {
                    store.reset(action.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Back to \(action.standard.display)")
            }
            Button {
                if recording { store.endRecording(); store.message = "" } else { store.beginRecording(action.id) }
            } label: {
                Text(recording ? "Press keys…" : store.shortcut(for: action.id).display)
                    .font(.system(.body, design: .rounded))
                    .frame(minWidth: 92)
            }
            .controlSize(.regular)
            .tint(recording ? .accentColor : nil)
        }
        .padding(.vertical, 7)
    }
}

final class ShortcutsWindowController: NSObject, NSWindowDelegate {
    static let shared = ShortcutsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Keyboard Shortcuts"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: ShortcutsView(store: .shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        ShortcutStore.shared.endRecording()
        ShortcutStore.shared.message = ""
    }
}
