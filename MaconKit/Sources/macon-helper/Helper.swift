//
//  Helper.swift
//  macon-helper  (root LaunchDaemon — scaffold)
//
//  Runs the companion server in the system context so it's reachable at the
//  login window, and routes typed characters to a virtual HID keyboard so the
//  password can be entered remotely. Pairs separately from the app (its store
//  lives under root's Application Support).
//
//  Screen capture at the login window is the remaining integration point — see
//  the TODO below and ARCHITECTURE.md.
//

import Foundation
import MaconKit

/// Nonisolated so it can be called from the server's background callbacks.
private func log(_ s: String) { print("[macon-helper] \(s)") }

@main
struct Helper {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let port: UInt16 = 8900
        let store = PairingStore()
        let keyboard = VirtualKeyboard()
        let screen = ScreenBroadcaster()        // TODO: attach a login-window screen capturer

        log(keyboard.isReady
            ? "Virtual keyboard ready."
            : "⚠︎ Virtual keyboard unavailable — need root + com.apple.developer.hid.virtual.device (see SETUP.md).")

        let service = CompanionService(
            runners: { [] },                    // unlock helper serves no CI pipelines
            runnerName: "\(Host.current().localizedName ?? "Mac") (login)",
            port: port,
            store: store,
            screen: screen,
            control: { event in
                // Route input to the virtual keyboard so it lands at the login window.
                switch event.t {
                case "text":
                    if let s = event.s { keyboard.type(s) }
                case "key":
                    switch event.code {
                    case 51: keyboard.tap(usage: 0x2A)      // delete → Backspace
                    case 36: keyboard.tap(usage: 0x28)      // return → Return
                    case 48: keyboard.tap(usage: 0x2B)      // tab
                    case 53: keyboard.tap(usage: 0x29)      // esc
                    default: break
                    }
                default:
                    break                                   // move/click need a loginwindow cursor — later
                }
            },
            onLog: { log($0) })

        service.start()

        if store.deviceCount == 0 {
            let code = store.mintCode(ttl: 3600)            // 1h window on first boot
            log("Pair the iPad with this login helper — address <host>:\(port), code \(code)")
        } else {
            log("\(store.deviceCount) device(s) paired · listening on :\(port)")
        }

        // Keep alive alongside the server's own queues.
        _ = service
        RunLoop.main.run()
    }
}
