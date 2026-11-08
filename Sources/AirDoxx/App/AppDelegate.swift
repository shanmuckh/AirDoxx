import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = AppModel()
    var windowController: MirrorWindowController!
    let keyInterceptor = MacKeyInterceptor()
    var hub: HubWindowController!
    private var presentationObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = MirrorWindowController(model: model)
        model.windowController = windowController
        NSApp.mainMenu = buildMenu()
        windowController.onToggleScreenMode = { [weak self] in self?.model.toggleScreenMode() }
        windowController.onRotate = { [weak self] in self?.model.rotatePhone() }
        windowController.onDisconnect = { [weak self] in self?.model.disconnect() }
        windowController.onForget = { [weak self] in self?.model.forgetPhone() }
        windowController.updateScreenModeButton(macOnly: model.turnScreenOff)
        windowController.showMirroring(false)
        hub = HubWindowController(app: model)
        presentationObserver = model.$presentation.removeDuplicates().sink { [weak self] p in
            DispatchQueue.main.async { self?.present(p) }
        }
        model.onShowPhone = { [weak self] in self?.present(.phone) }
        model.start()
        setUpMacKeys()

        // Preview aid: AM_PAGE=welcome|permissions|phoneSetup|connect|unavailable opens that page.
        if let raw = ProcessInfo.processInfo.environment["AM_PAGE"] {
            let pages: [String: HubModel.Page] = ["welcome": .welcome, "permissions": .permissions,
                                                  "phoneSetup": .phoneSetup, "connect": .connect,
                                                  "unavailable": .unavailable]
            if let page = pages[raw] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.windowController.window?.orderOut(nil)
                    self?.hub.show(page: page)
                }
            }
        }

        #if DEBUG
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let now = ProcessInfo.processInfo.systemUptime
            let hit = event.window?.contentView?.hitTest(event.locationInWindow)
            FileHandle.standardError.write(Data(String(format: "[monitor %.3f] %@ clicks=%d hwlag=%.0fms hit=%@\n",
                now, event.type == .leftMouseDown ? "DOWN" : "UP", event.clickCount,
                (now - event.timestamp) * 1000, hit.map { String(describing: type(of: $0)) } ?? "nil").utf8))
            return event
        }
        #endif

        // Debug aid: AM_SNAPSHOT=/path/out.png renders the front window to a PNG after launch
        // (AM_SNAPSHOT_DELAY seconds, default 2.5).
        if let path = ProcessInfo.processInfo.environment["AM_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["AM_SNAPSHOT_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                let front = self?.hub.window?.isVisible == true ? self?.hub.window : self?.windowController.window
                guard let view = front?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the phone window quits, like iPhone Mirroring. (The wireless panel doesn't count.)
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.syncClipboardToPhone()
    }

    // MARK: - Windows

    /// Shows the window for the current step, like iPhone Mirroring: setup flow, the phone itself,
    /// or the wide "Unable to Connect" window.
    private func present(_ p: Presentation) {
        switch p {
        case .setup:
            windowController.window?.orderOut(nil)
            hub.show(page: model.setupComplete ? .connect : .welcome)
        case .phone:
            hub.hide()
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .unavailable(let detail):
            windowController.window?.orderOut(nil)
            hub.show(page: .unavailable, detail: detail)
        case .disconnected(let name):
            windowController.window?.orderOut(nil)
            hub.show(page: .disconnected, detail: name)
        }
    }

    @objc private func setUpPhone() { model.beginSetup() }

    // MARK: - Mac special keys

    private func setUpMacKeys() {
        keyInterceptor.handler = { [weak self] key, down, isRepeat in
            guard let self, NSApp.isActive, self.model.isMirroring,
                  NSApp.keyWindow === self.windowController.window else { return false }
            self.model.handleMacKey(key, down: down, isRepeat: isRepeat)
            return true
        }
        keyInterceptor.start()
    }

    /// Opens AirDoxx's own permissions page (no hunting through System Settings).
    @objc private func requestMacKeys() {
        keyInterceptor.start()
        windowController.window?.orderOut(nil)
        hub.show(page: .permissions)
    }

    @objc private func testNotification() {
        guard let serial = model.session?.device.serial else { return }
        NotificationBridge.sendTestNotification(serial: serial)
        windowController.showToast("Sent a test notification from your phone")
    }

    @objc private func showWelcome() {
        windowController.window?.orderOut(nil)
        hub.show(page: .welcome)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AirDoxx", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AirDoxx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AirDoxx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "AirDoxx"))

        // File / Connection
        let file = NSMenu(title: "Connection")
        file.addItem(item("Connect Over Wi-Fi Automatically", #selector(toggleAutoWireless), ""))
        file.addItem(item("Set Up or Pair a Phone…", #selector(setUpPhone), "n"))
        file.addItem(item("Pair with Code…", #selector(showWireless), "k"))
        file.addItem(item("Disconnect", #selector(disconnect), "d", [.command, .shift]))
        file.addItem(item("Disconnect Permanently…", #selector(forgetPhone), ""))
        file.addItem(item("Universal Clipboard", #selector(toggleClipboard), ""))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil))
        main.addItem(submenu(file, title: "Connection"))

        // Edit
        let edit = NSMenu(title: "Edit")
        // Standard responder-chain actions: the phone screen view handles them while mirroring,
        // text fields (e.g. in the wireless window) handle them normally.
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Larger", #selector(larger), "+"))
        view.addItem(item("Actual Size", #selector(actualSize), "0"))
        view.addItem(item("Smaller", #selector(smaller), "-"))
        view.addItem(.separator())
        let quality = NSMenu(title: "Quality")
        for q in StreamQuality.allCases {
            let i = item(q.title, #selector(setQuality(_:)), "")
            i.representedObject = q.rawValue
            quality.addItem(i)
        }
        view.addItem(submenu(quality, title: "Stream Quality"))
        main.addItem(submenu(view, title: "View"))

        // Phone
        let phone = NSMenu(title: "Phone")
        phone.addItem(item("Home Screen", #selector(home), "1"))
        phone.addItem(item("App Switcher", #selector(recents), "2"))
        phone.addItem(item("Notifications", #selector(notifications), "3"))
        phone.addItem(item("Quick Settings", #selector(quickSettings), "4"))
        phone.addItem(item("Back", #selector(back), "["))
        phone.addItem(.separator())
        phone.addItem(item("Volume Up", #selector(volumeUp), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        phone.addItem(item("Volume Down", #selector(volumeDown), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        phone.addItem(item("Rotate", #selector(rotate), "r"))
        phone.addItem(item("Lock / Power Button", #selector(power), "l"))
        phone.addItem(.separator())
        phone.addItem(.separator())
        phone.addItem(item("Do Not Disturb On/Off", #selector(toggleDND), "d", [.command, .option]))
        phone.addItem(item("Take Screenshot", #selector(screenshot), "s", [.command, .shift]))
        phone.addItem(.separator())
        phone.addItem(item("Show on Mac Only (Phone Screen Off)", #selector(toggleScreenOffSetting), "p", [.command, .shift]))
        phone.addItem(item("Play Phone Audio on Mac", #selector(toggleAudio), ""))
        phone.addItem(item("Permissions…", #selector(requestMacKeys), ""))
        phone.addItem(item("Send Test Notification", #selector(testNotification), ""))
        main.addItem(submenu(phone, title: "Phone"))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome to AirDoxx…", #selector(showWelcome), ""))
        help.addItem(item("AirDoxx Website & Setup Guide", #selector(usbHelp), ""))
        main.addItem(submenu(help, title: "Help"))

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        i.submenu = menu
        return i
    }

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target ?? (action == #selector(NSWindow.performClose(_:)) ? nil : self)
        return i
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setQuality(_:)):
            menuItem.state = (menuItem.representedObject as? String) == model.quality.rawValue ? .on : .off
            return true
        case #selector(toggleScreenOffSetting):
            menuItem.state = model.turnScreenOff ? .on : .off
            return true
        case #selector(toggleClipboard):
            menuItem.state = model.universalClipboard ? .on : .off
            return true
        case #selector(toggleAutoWireless):
            menuItem.state = model.autoWireless ? .on : .off
            return true
        case #selector(requestMacKeys):
            return true
        case #selector(toggleAudio):
            menuItem.state = model.audioEnabled ? .on : .off
            return true
        case #selector(showWireless), #selector(usbHelp), #selector(setUpPhone), #selector(showWelcome), #selector(larger), #selector(smaller), #selector(actualSize):
            return true
        default:
            return model.isMirroring
        }
    }

    // MARK: - Actions

    @objc private func showWireless() { model.showWirelessSheet() }
    @objc private func disconnect() { model.disconnect() }
    @objc private func forgetPhone() { model.forgetPhone() }
    @objc private func toggleClipboard() { model.universalClipboard.toggle() }
    @objc private func usbHelp() { model.showUSBDebuggingHelp() }

    @objc private func larger() { windowController.larger() }
    @objc private func smaller() { windowController.smaller() }
    @objc private func actualSize() { windowController.actualSize() }
    @objc private func setQuality(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = StreamQuality(rawValue: raw) { model.quality = q }
    }

    @objc private func home() { model.pressKey(AndroidKey.home) }
    @objc private func recents() { model.pressKey(AndroidKey.appSwitch) }
    @objc private func back() { model.pressKey(AndroidKey.back) }
    @objc private func notifications() { model.send(ControlMessage.expandNotificationPanel) }
    @objc private func quickSettings() { model.send(ControlMessage.expandSettingsPanel) }
    @objc private func volumeUp() { model.pressKey(AndroidKey.volumeUp) }
    @objc private func volumeDown() { model.pressKey(AndroidKey.volumeDown) }
    @objc private func rotate() { model.rotatePhone() }
    @objc private func power() { model.pressKey(AndroidKey.power) }
    @objc private func screenshot() { model.takeScreenshot() }
    @objc private func toggleScreenOffSetting() { model.turnScreenOff.toggle() }
    @objc private func toggleAudio() { model.audioEnabled.toggle() }
    @objc private func toggleDND() { model.toggleDoNotDisturb() }
    @objc private func toggleAutoWireless() { model.autoWireless.toggle() }
}
