//
//  CompanionPairingView.swift
//  MacON
//
//  Sheet shown from Settings: displays the address + one-time code (and a QR)
//  to pair an iPhone/iPad, and lists paired devices with a revoke action.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import MaconKit

struct CompanionPairingView: View {
    @EnvironmentObject private var companion: CompanionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a device").font(.title2.bold())

            if !companion.isRunning {
                ContentUnavailableView("Server is off",
                                       systemImage: "wifi.slash",
                                       description: Text("Turn on the companion app in Settings first."))
            } else if let code = companion.pairingCode {
                if let qr = Self.qrImage(companion.pairingURL ?? code) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 176, height: 176)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 6) {
                    labeled("Address", companion.address)
                    labeled("Code", code, mono: true)
                }

                Text("In the MacOn app on your iPhone or iPad: tap **Add runner**, then enter the address and code. Same Wi‑Fi as this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Generate a new code") { companion.newCode() }
                    .buttonStyle(.link)
            } else {
                // Server is up and no code is active (e.g. a device is already
                // paired). Offer to mint one to add another device.
                VStack(spacing: 12) {
                    Image(systemName: "plus.circle").font(.system(size: 40)).foregroundStyle(.blue)
                    Text("Add another device").font(.headline)
                    Text("Listening on \(companion.address).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Create a pairing code") { companion.newCode() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if !companion.devices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paired devices").font(.headline)
                    ForEach(companion.devices, id: \.token) { device in
                        HStack {
                            Image(systemName: "ipad.and.iphone").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                Text("token \(device.tokenShort)…").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { companion.revoke(device) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await watchForPairing() }   // clear the code once a device pairs
    }

    // MARK: Helpers

    @ViewBuilder
    private func labeled(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.title3, design: .monospaced).weight(.semibold) : .headline)
                .textSelection(.enabled)
        }
    }

    /// Poll the (shared, in-memory) store; when a new device appears, drop the code.
    private func watchForPairing() async {
        let baseline = companion.devices.count
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            companion.refreshDevices()
            if companion.devices.count > baseline, companion.pairingCode != nil {
                companion.clearCode()
            }
        }
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 176, height: 176))
    }
}
