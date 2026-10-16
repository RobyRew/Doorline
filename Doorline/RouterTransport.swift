import Foundation

/// Sends each frame over the transport that carries it.
///
/// Configuration writes (`PUT https://…`) go to the myhomeweb portal. OWN bus frames
/// (session open, door lock, actuator, camera, answering machine) go to the panel's
/// OpenWebNet port 20000 when a panel host is set; without one they stay queued, which
/// keeps a missing panel from reading as a delivered command.
final class RouterTransport: C300XTransport {
    private let portal: PortalTransport
    private var own: OwnTransport?
    private var host: String?

    init(portal: PortalTransport = PortalTransport()) {
        self.portal = portal
    }

    /// Sets the panel address the OWN frames are sent to. Empty clears it.
    func setPanelHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.host = nil
            own = nil
            return
        }
        guard trimmed != self.host else { return }
        self.host = trimmed
        own = OwnTransport(host: trimmed)
    }

    var panelHost: String? { host }

    func send(_ frame: C300XFrame) async -> C300XReceipt {
        switch frame.kind {
        case .callForward, .professionalStudio:
            return await portal.send(frame)
        case .sessionOpen, .doorLock, .actuator, .camera, .answeringMachine:
            guard let own else { return .queued }
            return await own.send(frame)
        case .callAnswer, .callDecline, .callHome, .playMessage:
            // Carried by the SIP stack; a raw-text frame stays queued.
            return .queued
        }
    }
}
