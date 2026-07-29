// GDL90 receiver simulator: unicasts synthesized GDL90 over UDP so the
// app can be exercised without ADS-B hardware. The iOS simulator shares
// the host network stack, so the default 127.0.0.1:4000 reaches it.
//
//   swift run gdl90sim [--host 127.0.0.1] [--port 4000] [--no-gps]
//                      [--stop-after N] [--traffic N]
//
// Every frame is built with GDL90Deframer.frame() and the FBFISB
// encoders, so a run doubles as an encoder↔decoder integration test.

import Foundation
import FBGDL90
import FBFISB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Arguments

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 4000
    var gpsValid = true
    var stopAfter: Int?
    var trafficCount = 6

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--host": options.host = iterator.next() ?? options.host
            case "--port": options.port = UInt16(iterator.next() ?? "") ?? options.port
            case "--no-gps": options.gpsValid = false
            case "--stop-after": options.stopAfter = Int(iterator.next() ?? "")
            case "--traffic": options.trafficCount = Int(iterator.next() ?? "") ?? options.trafficCount
            default:
                print("Unknown argument: \(argument)")
                exit(64)
            }
        }
        return options
    }
}

// MARK: - UDP sender

struct UDPSender {
    private let socketFD: Int32
    private var address = sockaddr_in()

    init?(host: String, port: UInt16) {
        socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return nil }
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
    }

    func send(_ bytes: [UInt8]) {
        var address = self.address
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(socketFD, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - GDL90 encoders (sim-side; the package only decodes)

func heartbeatPayload(gpsValid: Bool) -> [UInt8] {
    let secondsSinceMidnight = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400))
    var status1: UInt8 = 0x01  // UTC timing valid
    if gpsValid { status1 |= 0x80 }
    let status2: UInt8 = UInt8((secondsSinceMidnight >> 16) & 0x01) << 7
    return [
        0x00, status1, status2,
        UInt8(secondsSinceMidnight & 0xFF),
        UInt8((secondsSinceMidnight >> 8) & 0xFF),
        0x00, 0x00,
    ]
}

func semicircleBytes(_ degrees: Double) -> [UInt8] {
    var value = Int32((degrees * 8_388_608.0 / 180.0).rounded())
    if value < 0 { value += 0x1000000 }
    return [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

struct SimAircraft {
    var address: UInt32
    var callsign: String
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusNM: Double
    var altitudeFeet: Int
    var groundSpeedKt: Int
    var verticalVelocityFpm: Int
    var airborne: Bool
    var phase: Double  // radians, initial position on the orbit

    /// Position and true track after `seconds` of orbiting.
    func state(at seconds: Double) -> (latitude: Double, longitude: Double, track: Double) {
        guard airborne, radiusNM > 0 else {
            return (centerLatitude, centerLongitude, 0)
        }
        let radiusMeters = radiusNM * 1852
        let speedMS = Double(groundSpeedKt) * 0.514444
        let theta = phase + speedMS / radiusMeters * seconds
        let latitude = centerLatitude + radiusMeters * sin(theta) / 111_320
        let longitude = centerLongitude + radiusMeters * cos(theta) / (111_320 * cos(centerLatitude * .pi / 180))
        // Velocity direction: d/dθ(sin, cos) → north ∝ cos θ, east ∝ −sin θ.
        let track = (atan2(-sin(theta), cos(theta)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (latitude, longitude, track)
    }

    func reportPayload(messageID: UInt8, at seconds: Double) -> [UInt8] {
        let (latitude, longitude, track) = state(at: seconds)
        var payload: [UInt8] = [messageID]
        payload += [0x00]  // no alert, ADS-B ICAO address
        payload += [UInt8((address >> 16) & 0xFF), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
        payload += semicircleBytes(latitude)
        payload += semicircleBytes(longitude)
        let altitudeBits = UInt16(clamping: (altitudeFeet + 1000) / 25)
        let misc: UInt8 = airborne ? 0x09 : 0x01  // true-track, airborne flag
        payload += [UInt8(altitudeBits >> 4), UInt8((altitudeBits & 0x0F) << 4) | misc]
        payload += [0xA9]  // NIC 10 / NACp 9
        let speedBits = UInt16(groundSpeedKt)
        let verticalBits = UInt16(bitPattern: Int16(verticalVelocityFpm / 64)) & 0x0FFF
        payload += [
            UInt8(speedBits >> 4),
            UInt8((speedBits & 0x0F) << 4) | UInt8(verticalBits >> 8),
            UInt8(verticalBits & 0xFF),
        ]
        payload += [UInt8((track / 360 * 256).rounded(.down))]
        payload += [0x01]  // emitter: light
        payload += Array(callsign.padding(toLength: 8, withPad: " ", startingAt: 0).utf8)
        payload += [0x00]
        return payload
    }
}

func geoAltitudePayload(feet: Int) -> [UInt8] {
    let raw = Int16(clamping: feet / 5)
    return [0x0B, UInt8(bitPattern: Int8(truncatingIfNeeded: raw >> 8)), UInt8(truncatingIfNeeded: raw), 0x00, 0x0A]
}

func uplinkPayload(infoFrames: [[UInt8]]) -> [UInt8] {
    [0x07, 0x00, 0x00, 0x00] + FISBEncoding.uplinkFrame(infoFrames: infoFrames)
}

// MARK: - Scenario

let options = Options.parse(CommandLine.arguments)
guard let sender = UDPSender(host: options.host, port: options.port) else {
    print("Could not open UDP socket for \(options.host):\(options.port)")
    exit(1)
}

// Ownship: left-hand circuit 3 NM around KAUS at 110 kt.
let ownship = SimAircraft(
    address: 0xA0_00_01, callsign: "N123FB",
    centerLatitude: 30.1945, centerLongitude: -97.6699,
    radiusNM: 3, altitudeFeet: 2500, groundSpeedKt: 110,
    verticalVelocityFpm: 0, airborne: true, phase: 0
)

var traffic: [SimAircraft] = []
for index in 0..<max(0, options.trafficCount) {
    let angle = Double(index) * 2 * .pi / Double(max(options.trafficCount, 1))
    if index == 0 {
        // One target taxiing at the field.
        traffic.append(SimAircraft(
            address: 0xB0_00_00, callsign: "N700GT",
            centerLatitude: 30.2020, centerLongitude: -97.6680,
            radiusNM: 0, altitudeFeet: 500, groundSpeedKt: 12,
            verticalVelocityFpm: 0, airborne: false, phase: 0
        ))
    } else {
        traffic.append(SimAircraft(
            address: 0xB0_00_00 + UInt32(index), callsign: "N70\(index)GT",
            centerLatitude: 30.1945 + 0.12 * sin(angle),
            centerLongitude: -97.6699 + 0.14 * cos(angle),
            radiusNM: 2 + Double(index % 3), altitudeFeet: 2000 + index * 700,
            groundSpeedKt: 90 + index * 15,
            verticalVelocityFpm: [0, 500, -400][index % 3],
            airborne: true, phase: angle
        ))
    }
}

let metarText = "METAR KAUS 151953Z 18010KT 10SM SCT045 33/17 A3002\u{1E}"
    + "TAF KAUS 151740Z 1518/1618 17012KT P6SM SCT050\u{1E}"
    + "METAR KDAL 151953Z 17012G18KT 10SM FEW060 34/16 A2999\u{1E}"
    + "TAF KDAL 151740Z 1518/1618 18014KT P6SM SKC"

/// FIS-B product 8. Same DLAC text encoding as the weather products — only
/// the product ID and the leading series token differ.
let notamText = "NOTAM-D KAUS 01/005 TWY A CLSD BTN TWY B AND TWY F\u{1E}"
    + "NOTAM-D KAUS 01/006 OBST CRANE ERECTED 1.2NM SW APCH END RWY 18L (ASR 1234567) 620FT AGL\u{1E}"
    + "NOTAM-FDC KAUS 1/2345 SPECIAL SECURITY INSTRUCTIONS IN EFFECT\u{1E}"
    + "NOTAM-D KDAL 02/001 RWY 13L/31R CLSD"

/// A small storm cell painted over blocks near the ownship circuit,
/// drifting east one block every broadcast.
func nexradFrames(tick: Int) -> [[UInt8]] {
    let baseBlock = 204_627 + (tick / 10) % 5
    var frames: [[UInt8]] = []
    for (offset, peak) in [(0, UInt8(3)), (1, UInt8(6)), (450, UInt8(4))] {
        var bins = [UInt8](repeating: 0, count: NEXRADGlobalBlock.binsPerBlock)
        for index in bins.indices {
            let column = index % NEXRADGlobalBlock.binsWide
            let distance = abs(column - 16)
            bins[index] = distance < 10 ? UInt8(max(0, Int(peak) - distance / 3)) : 0
        }
        if let payload = FISBEncoding.nexradRLE(blockNumber: baseBlock + offset, scaleFactor: 0, intensities: bins) {
            frames.append(FISBEncoding.infoFrame(body: FISBEncoding.apdu(
                productID: 63, hours: 19, minutes: 55, payload: payload
            )))
        }
    }
    return frames
}

print("gdl90sim → \(options.host):\(options.port)  (traffic: \(traffic.count), gps: \(options.gpsValid ? "valid" : "INVALID"))")

var tick = 0
while true {
    if let stopAfter = options.stopAfter, tick >= stopAfter {
        print("Stopping after \(tick) s")
        break
    }
    let seconds = Double(tick)

    sender.send(GDL90Deframer.frame(heartbeatPayload(gpsValid: options.gpsValid)))
    if options.gpsValid {
        sender.send(GDL90Deframer.frame(ownship.reportPayload(messageID: 0x0A, at: seconds)))
        sender.send(GDL90Deframer.frame(geoAltitudePayload(feet: ownship.altitudeFeet + 80)))
    }
    for target in traffic {
        sender.send(GDL90Deframer.frame(target.reportPayload(messageID: 0x14, at: seconds)))
    }
    if tick % 5 == 0 {
        let textFrame = FISBEncoding.infoFrame(body: FISBEncoding.apdu(
            productID: 413, hours: 19, minutes: 53, payload: DLAC.encode(metarText)
        ))
        sender.send(GDL90Deframer.frame(uplinkPayload(infoFrames: [textFrame])))
    }
    // NOTAMs uplink less often than weather, as they do in the real service.
    if tick % 15 == 0 {
        let notamFrame = FISBEncoding.infoFrame(body: FISBEncoding.apdu(
            productID: 8, hours: 19, minutes: 53, payload: DLAC.encode(notamText)
        ))
        sender.send(GDL90Deframer.frame(uplinkPayload(infoFrames: [notamFrame])))
    }
    if tick % 10 == 0 {
        for frame in nexradFrames(tick: tick) {
            sender.send(GDL90Deframer.frame(uplinkPayload(infoFrames: [frame])))
        }
    }

    tick += 1
    Thread.sleep(forTimeInterval: 1.0)
}
