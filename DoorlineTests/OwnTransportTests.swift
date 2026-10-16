import XCTest
import Network
@testable import Doorline

/// Runs a fake OWN panel on localhost: it answers the session-open with an OWN XML
/// acknowledgement and every other command with `*#*1##`, and records what it received.
@MainActor
final class OwnTransportTests: XCTestCase {
    func testSessionOpenThenDoorLockRoundTrips() async throws {
        let panel = FakePanel()
        let port = try await panel.start()
        let transport = OwnTransport(host: "127.0.0.1", port: port)

        let open = await transport.send(C300XFrame(kind: .sessionOpen, wire: C300XCodec.sessionOpen))
        XCTAssertEqual(open, .accepted)
        XCTAssertEqual(panel.received, [C300XCodec.sessionOpen + "\r\n"])

        let lock = await transport.send(C300XFrame(kind: .doorLock, wire: C300XCodec.doorLock()))
        XCTAssertEqual(lock, .accepted)
        XCTAssertEqual(panel.received.last, C300XCodec.doorLock() + "\r\n")
        panel.stop()
    }

    func testPanelRejectionIsReported() async throws {
        let panel = FakePanel(ack: "*#*0##")
        let port = try await panel.start()
        let transport = OwnTransport(host: "127.0.0.1", port: port)

        _ = await transport.send(C300XFrame(kind: .sessionOpen, wire: C300XCodec.sessionOpen))
        let lock = await transport.send(C300XFrame(kind: .doorLock, wire: C300XCodec.doorLock()))
        XCTAssertEqual(lock, .rejected("The panel rejected the command."))
        panel.stop()
    }

    func testMissingPanelRejectsInsteadOfHanging() async {
        // The port comes from a listener that is stopped right away, so nothing accepts.
        let panel = FakePanel()
        let port = try! await panel.start()
        panel.stop()
        let transport = OwnTransport(host: "127.0.0.1", port: port)
        let receipt = await transport.send(C300XFrame(kind: .doorLock, wire: C300XCodec.doorLock()))
        switch receipt {
        case .rejected: break
        default: XCTFail("A missing panel must read as a rejection, got \(receipt)")
        }
    }
}

private final class FakePanel {
    private let ack: String
    private(set) var received: [String] = []
    private var listener: NWListener?
    private var connection: NWConnection?

    init(ack: String = "*#*1##") {
        self.ack = ack
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    continuation.resume(returning: listener.port!.rawValue)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.connection = connection
                connection.start(queue: .global())
                self?.serve(connection)
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                self.received.append(text)
                let reply: String
                if text.hasPrefix("<OWNMsg") {
                    reply = "<OWNMsg Profile=\"V4\"><Payload><Service TYPE=\"ACK\"/></Payload></OWNMsg>\r\n"
                } else {
                    reply = self.ack + "\r\n"
                }
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            }
            if error == nil && !isComplete {
                self.serve(connection)
            }
        }
    }
}
