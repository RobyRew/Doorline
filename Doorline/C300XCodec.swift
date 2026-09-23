import Foundation

/// Wire shapes for a Classe 300X session.
///
/// The panel's video-door-entry bus uses WHO 8. A door-lock pulse is WHAT 19 at the
/// entrance address. A generic actuator (gate, staircase light) is WHAT 21. The
/// answering machine is WHAT 91 on and 92 off. The portal session starts with the
/// OWN XML handshake, then SIP on `{plant}.bs.iotleg.com`. Configuration writes go
/// to the plant gateway document on myhomeweb.
enum C300XCodec {
    static let sessionOpen = "<OWNMsg Profile=\"V4\"><Payload><Service TYPE=\"SET\"/><SeqID ID=\"0\" Progress=\"0\"/><Address/><ActionID>OWNSetProtocol</ActionID><Params><Param name=\"Version\">2</Param><Param name=\"Command\">1</Param><Param name=\"Monitor\">1</Param><Param name=\"ConnAlwaysOn\">1</Param></Params></Payload></OWNMsg>"

    static let doorLockAddress = "20"
    static let actuatorAddress = "10"
    static let entranceCameraAddress = "20"
    static let secondaryCameraAddress = "21"

    static func doorLock(address: String = doorLockAddress) -> String {
        "*8*19*\(address)##"
    }

    static func actuator(address: String = actuatorAddress) -> String {
        "*8*21*\(address)##"
    }

    static func cameraOn(address: String) -> String {
        "*8*1#5#4#\(address)*10##"
    }

    static func answeringMachine(enabled: Bool) -> String {
        enabled ? "*8*91##" : "*8*92##"
    }

    static func playMessage(id: String) -> String {
        "ACTION action_aswm_play id=\(id)"
    }

    static func answer(plant: String) -> String {
        "SIP/2.0 200 OK\r\nTo: <sip:c300x@\(plant).bs.iotleg.com>\r\nContact: <sip:doorline@\(plant).bs.iotleg.com>"
    }

    static func decline(plant: String) -> String {
        "SIP/2.0 603 Decline\r\nTo: <sip:c300x@\(plant).bs.iotleg.com>"
    }

    static func callHome(plant: String) -> String {
        "INVITE sip:c300x@\(plant).bs.iotleg.com SIP/2.0\r\nFrom: <sip:doorline@\(plant).bs.iotleg.com>"
    }

    static func forwarding(_ mode: ForwardingMode, plant: String, gateway: String) -> String {
        "PUT https://www.myhomeweb.com/plants/\(plant)/gateway/\(gateway)/conf\nforwarding=\(mode.rawValue)"
    }

    static func professionalStudio(enabled: Bool, plant: String, gateway: String) -> String {
        "PUT https://www.myhomeweb.com/plants/\(plant)/gateway/\(gateway)/conf\nprofessionalStudio=\(enabled ? "1" : "0")"
    }

    static func messageList(_ messages: [AnsweringMessage]) -> String {
        messages.map { message in
            "ASWM\t\(message.id)\t\(Self.stamp.string(from: message.recordedAt))\t\(message.caller)"
        }.joined(separator: "\n")
    }

    static func parseMessages(_ wire: String) -> [AnsweringMessage] {
        wire.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0] == "ASWM", let date = stamp.date(from: parts[2]) else { return nil }
            return AnsweringMessage(id: parts[1], recordedAt: date, caller: parts[3])
        }
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct C300XFrame: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case sessionOpen
        case doorLock
        case actuator
        case camera
        case callAnswer
        case callDecline
        case callHome
        case answeringMachine
        case playMessage
        case callForward
        case professionalStudio
    }

    var kind: Kind
    var wire: String
}

enum C300XReceipt: Equatable, Sendable {
    case queued
    case accepted
    case rejected(String)
}

protocol C300XTransport: AnyObject {
    func send(_ frame: C300XFrame) async -> C300XReceipt
}

/// Holds frames in memory. Tests and the unsigned session use this so a missing panel is not a success.
final class QueuedTransport: C300XTransport {
    func send(_ frame: C300XFrame) async -> C300XReceipt { .queued }
}

/// Posts configuration documents to myhomeweb. Bus and SIP frames stay queued: this client has no portal token.
final class PortalTransport: C300XTransport {
    func send(_ frame: C300XFrame) async -> C300XReceipt {
        guard frame.wire.hasPrefix("PUT https://"),
              let newline = frame.wire.firstIndex(of: "\n"),
              let url = URL(string: String(frame.wire[..<newline].dropFirst(4))) else {
            return .queued
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "PUT"
        request.httpBody = Data(frame.wire[frame.wire.index(after: newline)...].utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return .accepted }
            return .rejected("Portal answered \(code).")
        } catch {
            return .rejected(error.localizedDescription)
        }
    }
}
