import Foundation
import Network

/// OpenWebNet TCP transport to a Classe 300X panel.
///
/// Door Entry connects with the panel on TCP port 20000: it opens the session with the OWN
/// XML `OWNSetProtocol` handshake, then exchanges plain `*who*what*where##` frames. The
/// panel answers each command with `*#*1##` (ACK) or `*#*0##` (NACK); the session-open
/// answer is an OWN XML acknowledgement.
///
/// Frames are written one at a time in arrival order; each send resolves when the panel
/// answers, or rejects after a timeout. With `Monitor=1` in the handshake the panel also
/// pushes OWN event frames, which are surfaced through `onEvent`.
///
/// Every mutable member is touched only on `queue`, so the class is Sendable despite the
/// Network callbacks hopping onto the queue.
final class OwnTransport: C300XTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "doorline.own")
    private var connection: NWConnection?
    private var pending: [(wire: String, continuation: CheckedContinuation<C300XReceipt, Never>)] = []
    private var inflight = false
    private var timeout: DispatchWorkItem?

    /// ASCII events (OWN event frames, XML notifications) received outside a request.
    var onEvent: ((String) -> Void)?

    init(host: String, port: UInt16 = 20000) {
        self.host = host
        self.port = port
    }

    func send(_ frame: C300XFrame) async -> C300XReceipt {
        await withCheckedContinuation { continuation in
            queue.async { self.enqueue(frame.wire, continuation) }
        }
    }

    private func enqueue(_ wire: String, _ continuation: CheckedContinuation<C300XReceipt, Never>) {
        pending.append((wire, continuation))
        pump()
    }

    /// Writes the next queued frame when the connection is ready and no frame awaits an answer.
    private func pump() {
        guard !inflight, let item = pending.first else { return }
        if connection == nil {
            connect()
            return
        }
        guard let connection, connection.state == .ready else { return }
        inflight = true
        let wire = item.wire
        write(wire, on: connection)
        scheduleTimeout(for: wire)
    }

    private func connect() {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 20000)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handle(state) }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            pump()
        case .failed, .cancelled:
            failAll("The panel did not accept the connection.")
        default:
            break
        }
    }

    private func write(_ wire: String, on connection: NWConnection) {
        let data = Data((wire + "\r\n").utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func scheduleTimeout(for wire: String) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inflight, self.pending.first?.wire == wire else { return }
            self.failAll("The panel did not answer the command.")
        }
        timeout = work
        queue.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let text = String(decoding: data, as: UTF8.self)
                self.queue.async { self.ingest(text) }
            }
            if error == nil && !isComplete {
                self.receive(on: connection)
            }
        }
    }

    private func ingest(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard inflight else {
                onEvent?(trimmed)
                continue
            }
            switch trimmed {
            case "*#*1##":
                resolveFirst(.accepted)
            case "*#*0##":
                resolveFirst(.rejected("The panel rejected the command."))
            default:
                if pending.first?.wire == C300XCodec.sessionOpen, trimmed.hasPrefix("<OWNMsg") {
                    resolveFirst(.accepted)
                } else {
                    onEvent?(trimmed)
                }
            }
        }
    }

    private func resolveFirst(_ receipt: C300XReceipt) {
        timeout?.cancel()
        guard let item = pending.first else { return }
        pending.removeFirst()
        inflight = false
        item.continuation.resume(returning: receipt)
        pump()
    }

    private func failAll(_ reason: String) {
        timeout?.cancel()
        inflight = false
        let items = pending
        pending.removeAll()
        connection?.cancel()
        connection = nil
        for item in items {
            item.continuation.resume(returning: .rejected(reason))
        }
    }
}
