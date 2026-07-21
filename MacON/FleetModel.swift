//
//  FleetModel.swift
//  MacON
//
//  The fleet map's wire shapes: this Mac plus every paired device, with the
//  liveness the authorize hook records (a device that's talking to the
//  server right now is "live"). Served to the companion at GET /devices and
//  read directly by the Mac's own FleetView. CompanionJSON coding — keys
//  stay single-word so the snake_case strategy can't mangle them.
//

import Foundation

nonisolated struct FleetDeviceDTO: Codable, Identifiable, Hashable {
    var name: String
    var kind: String               // "iphone" | "ipad"
    var seconds: Int?              // since last seen; nil = quiet since launch
    var live: Bool
    var short: String              // token prefix — stable id, revoke handle
    var id: String { short }
}

nonisolated struct FleetDevicesDTO: Codable {
    var mac: String                // this Mac's name (the center of the map)
    var devices: [FleetDeviceDTO]
}
