import Foundation
import Network
import Testing
import FBGDL90
@testable import FlightBag

/// Serialized: the tests bind real UDP ports on the loopback interface.
@MainActor
@Suite(.serialized) struct GDL90ListenerTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.withLock { count += n } }
        var value: Int { lock.withLock { count } }
    }

    private static let heartbeat = GDL90Deframer.frame([0x00, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00])

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The documented "zombie FlightBag eats the simulator's datagrams"
    /// failure: a stopped listener's accepted connection kept its socket, so
    /// a sender that kept talking reached it instead of the new listener.
    @Test func restartedListenerReceivesFromAnExistingSender() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let first = Counter()
        let listenerA = GDL90UDPListener(port: port, onEvents: { first.add($0.count) }, onFailure: { _ in })
        listenerA.start()
        try await Task.sleep(for: .milliseconds(200))

        // One sender for the whole test, like gdl90sim unicasting at 1 Hz.
        let sender = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        sender.start(queue: DispatchQueue(label: "gdl90-test-sender"))
        let send = { sender.send(content: Data(Self.heartbeat), completion: .contentProcessed { _ in }) }
        send()
        await waitUntil { first.value > 0 }
        #expect(first.value > 0)

        listenerA.stop()
        try await Task.sleep(for: .milliseconds(200))

        let second = Counter()
        let listenerB = GDL90UDPListener(port: port, onEvents: { second.add($0.count) }, onFailure: { _ in })
        listenerB.start()
        try await Task.sleep(for: .milliseconds(200))
        defer { listenerB.stop(); sender.cancel() }

        for _ in 0..<10 where second.value == 0 {
            send()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(second.value > 0)
    }
}
