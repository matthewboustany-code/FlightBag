import Foundation
import Network
import Observation
import FBGDL90
import FBFISB

/// Work pre-decoded on the UDP queue, delivered to the main actor in one
/// batch per datagram.
enum GDL90Event: Sendable {
    case message(GDL90Message)
    case fisb(productID: Int, FISBProduct)
}

/// Listens for GDL90 on UDP and fans decoded data out to the position
/// source, traffic store, and FIS-B consumers. Mainstream receivers
/// (Stratux, Sentry) unicast to each connected client, which needs no
/// entitlement; broadcast-only receivers additionally require the Apple
/// multicast entitlement.
@MainActor
@Observable
final class GDL90Receiver {
    enum ConnectionState: Equatable {
        case idle
        case listening
        case receiving
        case stale
        case failed(String)
    }

    private(set) var state: ConnectionState = .idle
    private(set) var lastHeartbeatAt: Date?
    private(set) var gpsPositionValid = false
    private(set) var messagesPerSecond = 0
    /// FIS-B product ID → APDUs seen, including products we don't decode —
    /// shown in Settings as a receiver-debugging aid.
    private(set) var fisbProductCounts: [Int: Int] = [:]

    /// Sinks; wired once by AppEnvironment.
    var onOwnship: ((GDL90Message.TrafficReport) -> Void)?
    var onOwnshipGeoAltitude: ((Int) -> Void)?
    var onTraffic: ((GDL90Message.TrafficReport) -> Void)?
    var onFISB: ((FISBProduct) -> Void)?
    /// 1 Hz while running; consumers use it for aging/staleness so views
    /// re-render even when no new data arrives.
    var onTick: ((Date) -> Void)?

    private var listener: GDL90UDPListener?
    private var tickTask: Task<Void, Never>?
    private var lastMessageAt: Date?
    private var messagesThisSecond = 0
    private static let staleAfterSeconds: TimeInterval = 5

    func start(port: UInt16 = 4000) {
        guard listener == nil else { return }
        state = .listening
        lastMessageAt = nil
        let listener = GDL90UDPListener(
            port: port,
            onEvents: { events in
                Task { @MainActor [weak self] in self?.apply(events) }
            },
            onFailure: { message in
                Task { @MainActor [weak self] in self?.fail(message) }
            }
        )
        self.listener = listener
        listener.start()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        listener?.stop()
        listener = nil
        state = .idle
        messagesPerSecond = 0
        gpsPositionValid = false
    }

    private func fail(_ message: String) {
        listener?.stop()
        listener = nil
        state = .failed(message)
    }

    private func apply(_ events: [GDL90Event]) {
        // A batch can land after stop(); don't resurrect state.
        guard listener != nil else { return }
        lastMessageAt = Date()
        messagesThisSecond += events.count
        state = .receiving
        for event in events {
            switch event {
            case .message(.heartbeat(let heartbeat)):
                lastHeartbeatAt = Date()
                gpsPositionValid = heartbeat.gpsPositionValid
            case .message(.ownship(let report)):
                onOwnship?(report)
            case .message(.ownshipGeometricAltitude(let feet)):
                onOwnshipGeoAltitude?(feet)
            case .message(.trafficReport(let report)):
                onTraffic?(report)
            case .message:
                break
            case .fisb(let productID, let product):
                fisbProductCounts[productID, default: 0] += 1
                onFISB?(product)
            }
        }
    }

    private func tick() {
        messagesPerSecond = messagesThisSecond
        messagesThisSecond = 0
        if state == .receiving, let last = lastMessageAt,
           Date().timeIntervalSince(last) > Self.staleAfterSeconds {
            state = .stale
        }
        onTick?(Date())
    }
}

/// Owns the NWListener and does all deframing/decoding on a dedicated
/// queue; only pre-decoded event batches cross to the main actor.
final class GDL90UDPListener: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.flightbag.gdl90")
    private let onEvents: @Sendable ([GDL90Event]) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var listener: NWListener?

    init(
        port: UInt16,
        onEvents: @escaping @Sendable ([GDL90Event]) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.port = port
        self.onEvents = onEvents
        self.onFailure = onFailure
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onFailure("Invalid port \(port)")
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp, on: nwPort)
        } catch {
            onFailure(error.localizedDescription)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [onFailure] state in
            if case .failed(let error) = state {
                onFailure(error.localizedDescription)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, deframer: GDL90Deframer())
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    /// One receive loop per remote endpoint, each with its own deframer so
    /// frames split across datagrams reassemble correctly.
    private func receive(on connection: NWConnection, deframer: GDL90Deframer) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            var deframer = deframer
            if let data, !data.isEmpty {
                let events = Self.decode(payloads: deframer.feed([UInt8](data)))
                if !events.isEmpty { self.onEvents(events) }
            }
            if error == nil {
                self.receive(on: connection, deframer: deframer)
            } else {
                connection.cancel()
            }
        }
    }

    static func decode(payloads: [[UInt8]]) -> [GDL90Event] {
        var events: [GDL90Event] = []
        for payload in payloads {
            guard let message = GDL90Message.decode(payload) else { continue }
            if case .uplinkData(let uatFrame) = message {
                guard let uplink = UATUplinkFrame.parse(uatFrame) else { continue }
                for apdu in uplink.apdus {
                    events.append(.fisb(productID: apdu.productID, apdu.decodeProduct()))
                }
            } else {
                events.append(.message(message))
            }
        }
        return events
    }
}
