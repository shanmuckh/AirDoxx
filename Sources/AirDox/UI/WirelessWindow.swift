import AppKit
import SwiftUI

final class WirelessForm: ObservableObject {
    @Published var pairAddress = ""
    @Published var pairCode = ""
    @Published var connectAddress = ""
    @Published var message = ""
    @Published var busy = false
}

struct WirelessView: View {
    let model: AppModel
    @ObservedObject var form: WirelessForm

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your phone is plugged in with USB")
                        .font(.headline)
                    Text("Switch it to Wi-Fi in one click. The phone and this Mac must be on the same network.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Switch to Wi-Fi") {
                        run { done in model.switchToWireless(completion: done) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with Wireless debugging (Android 11+)")
                        .font(.headline)
                    Text("On the phone: Settings › Developer options › Wireless debugging › Pair device with pairing code.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("IP address & port, e.g. 192.168.1.20:37123", text: $form.pairAddress)
                        TextField("Code", text: $form.pairCode).frame(width: 90)
                        Button("Pair") {
                            run { done in model.pair(address: form.pairAddress, code: form.pairCode, completion: done) }
                        }
                        .disabled(form.pairAddress.isEmpty || form.pairCode.isEmpty)
                    }
                    Text("Then enter the address shown under “IP address & Port” on the Wireless debugging screen:")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("IP address & port, e.g. 192.168.1.20:41235", text: $form.connectAddress)
                        Button("Connect") {
                            run { done in model.connectWireless(address: form.connectAddress, completion: done) }
                        }
                        .disabled(form.connectAddress.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 8) {
                if form.busy { ProgressView().controlSize(.small) }
                Text(form.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(minHeight: 20)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if form.connectAddress.isEmpty { form.connectAddress = model.lastWirelessAddress ?? "" } }
    }

    private func run(_ action: (@escaping (String) -> Void) -> Void) {
        form.busy = true
        form.message = "Working…"
        let form = self.form
        action { result in
            form.busy = false
            form.message = result
        }
    }
}

final class WirelessWindowController {
    static let shared = WirelessWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Connect Wirelessly"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WirelessView(model: model, form: WirelessForm()))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
