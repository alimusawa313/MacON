//
//  CloudLink.swift
//  MacON
//
//  Optional iCloud (CloudKit) layer — off by default. When enabled, the Mac
//  publishes a "beacon" record to its private CloudKit database describing how
//  to reach it (current tunnel URL, LAN address, port) plus a compact status
//  and power state, and republishes it whenever any of that changes. A paired
//  device on the same Apple ID reads that beacon and re-points itself
//  automatically — so when the Cloudflare tunnel URL rotates, nobody has to
//  touch the Mac. It also watches a "command" record the device writes, so
//  wake/unlock can arrive over iCloud instead of the LAN.
//
//  Everything is gated on the iCloud account being available, so with the
//  toggle off (or the iCloud capability not provisioned) this stays dormant
//  and the app behaves exactly as before. See CloudSchema for the setup notes.
//

import Foundation
import Combine
import CloudKit

@MainActor
final class CloudLink: ObservableObject {
    /// Whether the iCloud account is usable (signed in + entitlement present).
    @Published private(set) var available = false
    /// Whether we're actively publishing.
    @Published private(set) var active = false
    /// Last successful beacon publish, for the UI.
    @Published private(set) var lastPublish: Date?

    /// Invoked when the device posts a new command ("wake" | "unlock").
    var onCommand: ((String) -> Void)?

    // Lazy: never instantiate CloudKit unless the user opts in, so the default
    // (off) path is untouched on machines without the capability provisioned.
    private lazy var container = CKContainer(identifier: CloudSchema.container)
    private var db: CKDatabase { container.privateCloudDatabase }

    private var beaconRecord: CKRecord?      // cached for cheap change-only saves
    private var lastCommandNonce: String?
    private var pending: CloudSchema.Beacon?
    private var pollTimer: Timer?

    // MARK: Lifecycle

    /// Check the account and, if usable, begin publishing + watching commands.
    func start() {
        container.accountStatus { [weak self] status, _ in
            Task { @MainActor in
                guard let self else { return }
                self.available = (status == .available)
                guard self.available else { self.active = false; return }
                self.active = true
                if let beacon = self.pending { self.publish(beacon) }
                self.startPolling()
            }
        }
    }

    func stop() {
        active = false
        pollTimer?.invalidate(); pollTimer = nil
    }

    // MARK: Publish

    /// Publish (or update) the beacon. Cheap to call often — it only writes
    /// when a field actually changed. Held until the account check completes.
    func publish(_ beacon: CloudSchema.Beacon) {
        pending = beacon
        guard active else { return }
        applyAndSave(beacon)
    }

    private func applyAndSave(_ beacon: CloudSchema.Beacon) {
        func write(into record: CKRecord) {
            beacon.apply(to: record)
            db.save(record) { [weak self] saved, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let saved { self.beaconRecord = saved; self.lastPublish = Date() }
                    else if let ck = error as? CKError, ck.code == .serverRecordChanged,
                            let server = ck.serverRecord {
                        // Someone else's copy won — adopt it and retry once.
                        self.beaconRecord = server
                        beacon.apply(to: server)
                        self.db.save(server) { s, _ in
                            Task { @MainActor in if let s { self.beaconRecord = s; self.lastPublish = Date() } }
                        }
                    }
                }
            }
        }

        if let record = beaconRecord {
            write(into: record)
        } else {
            let id = CKRecord.ID(recordName: CloudSchema.beaconRecordName)
            db.fetch(withRecordID: id) { [weak self] fetched, _ in
                Task { @MainActor in
                    guard let self else { return }
                    write(into: fetched ?? CKRecord(recordType: CloudSchema.beaconType, recordID: id))
                }
            }
        }
    }

    // MARK: Commands (device → Mac)

    private func startPolling() {
        pollTimer?.invalidate()
        // Republish the pending beacon periodically (keeps `updatedAt` fresh so
        // the device can tell we're alive) and check for a new command.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCommand() }
        }
        pollCommand()
    }

    private func pollCommand() {
        let id = CKRecord.ID(recordName: CloudSchema.commandRecordName)
        db.fetch(withRecordID: id) { [weak self] record, _ in
            Task { @MainActor in
                guard let self, let record,
                      let nonce = record[CloudSchema.CommandKey.nonce] as? String,
                      let kind = record[CloudSchema.CommandKey.kind] as? String else { return }
                // Ignore the one we've already run, and anything stale (>60s old).
                guard nonce != self.lastCommandNonce else { return }
                self.lastCommandNonce = nonce
                if let issued = record[CloudSchema.CommandKey.issuedAt] as? Date,
                   Date().timeIntervalSince(issued) > 60 { return }
                self.onCommand?(kind)
            }
        }
    }
}
