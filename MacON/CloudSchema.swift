//
//  CloudSchema.swift
//  MacON
//
//  The CloudKit contract shared (by convention) with the companion app: the
//  container identifier, the two fixed record names, and their fields. Both
//  apps must agree on these strings — keep them identical to the companion's
//  copy of this file.
//
//  To activate iCloud sync you must, in Xcode, add the iCloud capability with
//  CloudKit to BOTH app targets, select (or create) the container below, and
//  sign both with the same paid-Developer team + Apple ID. Until then the
//  account check fails and the whole layer stays dormant.
//

import Foundation
import CloudKit

enum CloudSchema {
    /// The private-DB container. Change here + in the companion to match your
    /// team's container, then create it in the CloudKit dashboard.
    static let container = "iCloud.com.karar.MacON"

    // Single well-known records in the private DB (one Mac per Apple ID) — no
    // queries or dashboard indexes needed.
    static let beaconType = "RunnerBeacon"
    static let beaconRecordName = "runner"
    static let commandType = "Command"
    static let commandRecordName = "command"

    enum BeaconKey {
        static let name = "name"
        static let tunnelURL = "tunnelURL"
        static let lanHost = "lanHost"
        static let secure = "secure"
        static let locked = "locked"
        static let displayAsleep = "displayAsleep"
        static let keepAwake = "keepAwake"
        static let running = "running"
        static let failed = "failed"
        static let mac = "mac"
        static let broadcast = "broadcast"
        static let updatedAt = "updatedAt"
    }

    enum CommandKey {
        static let kind = "kind"       // "wake" | "unlock"
        static let nonce = "nonce"     // unique per issue, so each is run once
        static let issuedAt = "issuedAt"
    }

    /// The Mac's advertised reachability + status, written to the beacon record.
    struct Beacon {
        var name: String
        var tunnelURL: String?
        var lanHost: String
        var secure: Bool
        var locked: Bool
        var displayAsleep: Bool
        var keepAwake: Bool
        var running: Int
        var failed: Int
        var mac: String?
        var broadcast: String?

        func apply(to record: CKRecord) {
            record[BeaconKey.name] = name as CKRecordValue
            record[BeaconKey.tunnelURL] = (tunnelURL ?? "") as CKRecordValue
            record[BeaconKey.lanHost] = lanHost as CKRecordValue
            record[BeaconKey.secure] = (secure ? 1 : 0) as CKRecordValue
            record[BeaconKey.locked] = (locked ? 1 : 0) as CKRecordValue
            record[BeaconKey.displayAsleep] = (displayAsleep ? 1 : 0) as CKRecordValue
            record[BeaconKey.keepAwake] = (keepAwake ? 1 : 0) as CKRecordValue
            record[BeaconKey.running] = running as CKRecordValue
            record[BeaconKey.failed] = failed as CKRecordValue
            record[BeaconKey.mac] = (mac ?? "") as CKRecordValue
            record[BeaconKey.broadcast] = (broadcast ?? "") as CKRecordValue
            record[BeaconKey.updatedAt] = Date() as CKRecordValue
        }
    }
}
