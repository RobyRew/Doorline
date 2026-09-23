import XCTest
@testable import Doorline

@MainActor
final class Classe300XSessionTests: XCTestCase {
    func testStartStateIsUnsignedAndIdle() {
        let session = make()
        XCTAssertEqual(session.association, .signedOut)
        XCTAssertEqual(session.call.phase, .idle)
        XCTAssertFalse(session.call.audioLive)
        XCTAssertFalse(session.call.videoLive)
        XCTAssertNil(session.currentCameraID)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertEqual(session.forwarding, .blocked)
        XCTAssertFalse(session.professionalStudio)
    }

    func testRingThenAnswerIsAnActiveAudioVideoCall() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        await session.receiveRing(caller: "Entrance")
        XCTAssertEqual(session.call.phase, .ringing)
        XCTAssertFalse(session.call.audioLive)
        XCTAssertFalse(session.call.videoLive)
        await session.answer()
        XCTAssertEqual(session.call.phase, .active)
        XCTAssertEqual(session.call.direction, .incoming)
        XCTAssertTrue(session.call.audioLive)
        XCTAssertTrue(session.call.videoLive)
        XCTAssertTrue(session.history.contains { $0.kind == .call })
        XCTAssertEqual(
            session.sent.last(where: { $0.kind == .callAnswer })?.wire,
            C300XCodec.answer(plant: "1001")
        )
    }

    func testRingThenDeclineStaysSilent() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        await session.receiveRing(caller: "Entrance")
        await session.decline()
        XCTAssertEqual(session.call.phase, .declined)
        XCTAssertFalse(session.call.audioLive)
        XCTAssertFalse(session.call.videoLive)
        XCTAssertEqual(
            session.sent.last(where: { $0.kind == .callDecline })?.wire,
            C300XCodec.decline(plant: "1001")
        )
        XCTAssertFalse(session.sent.contains { $0.kind == .callAnswer })
    }

    func testCameraSelectionChangesTheCurrentCamera() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        XCTAssertEqual(session.currentCameraID, C300XCodec.entranceCameraAddress)
        await session.selectCamera(C300XCodec.secondaryCameraAddress)
        XCTAssertEqual(session.currentCameraID, C300XCodec.secondaryCameraAddress)
        XCTAssertEqual(session.currentCamera?.name, "Secondary")
        XCTAssertEqual(
            session.sent.last(where: { $0.kind == .camera })?.wire,
            C300XCodec.cameraOn(address: C300XCodec.secondaryCameraAddress)
        )
        await session.selectCamera("missing")
        XCTAssertEqual(session.currentCameraID, C300XCodec.secondaryCameraAddress)
    }

    func testDoorLockAndActuatorAreDistinctAndUnlockIsHistory() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        let unlocksBefore = session.history.filter { $0.kind == .unlock }.count
        await session.releaseDoorLock()
        await session.releaseActuator()
        let door = session.sent.last(where: { $0.kind == .doorLock })
        let gate = session.sent.last(where: { $0.kind == .actuator })
        XCTAssertEqual(door?.wire, C300XCodec.doorLock())
        XCTAssertEqual(gate?.wire, C300XCodec.actuator())
        XCTAssertNotEqual(door?.wire, gate?.wire)
        XCTAssertEqual(session.history.filter { $0.kind == .unlock }.count, unlocksBefore + 1)
    }

    func testAnsweringMachinePlaySelectsOneMessage() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        let first = AnsweringMessage(id: "m1", recordedAt: Date(timeIntervalSince1970: 1_700_000_000), caller: "Entrance")
        let second = AnsweringMessage(id: "m2", recordedAt: Date(timeIntervalSince1970: 1_700_000_100), caller: "Gate")
        session.ingestMessages(C300XCodec.messageList([first, second]))
        XCTAssertEqual(session.messages.map(\.id), ["m1", "m2"])
        await session.setAnsweringMachineEnabled(true)
        XCTAssertTrue(session.answeringMachineEnabled)
        XCTAssertEqual(session.sent.last(where: { $0.kind == .answeringMachine })?.wire, C300XCodec.answeringMachine(enabled: true))
        await session.playMessage("m2")
        XCTAssertEqual(session.playingMessageID, "m2")
        XCTAssertEqual(session.sent.last(where: { $0.kind == .playMessage })?.wire, C300XCodec.playMessage(id: "m2"))
        await session.playMessage("missing")
        XCTAssertEqual(session.playingMessageID, "m2")
    }

    func testForwardingAndProfessionalStudio() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        await session.setForwarding(.allPhones)
        XCTAssertEqual(session.forwarding, .allPhones)
        await session.setForwarding(.atHome)
        XCTAssertEqual(session.forwarding, .atHome)
        XCTAssertNotEqual(
            session.sent.filter { $0.kind == .callForward }.map(\.wire).first,
            session.sent.filter { $0.kind == .callForward }.map(\.wire).last
        )
        await session.setProfessionalStudio(true)
        XCTAssertTrue(session.professionalStudio)
        let unlocksBefore = session.history.filter { $0.kind == .unlock }.count
        await session.receiveRing(caller: "Panel")
        XCTAssertEqual(session.call.phase, .ringing)
        XCTAssertEqual(session.history.filter { $0.kind == .unlock }.count, unlocksBefore + 1)
        XCTAssertTrue(session.history.contains { $0.kind == .call })
    }

    func testCallHomeReachesTheInternalUnit() async {
        let session = make()
        await session.associate(account: "ada@example.com", plantID: "1001", gatewayID: "gw-1")
        await session.callHome()
        XCTAssertEqual(session.call.phase, .active)
        XCTAssertEqual(session.call.direction, .callHome)
        XCTAssertTrue(session.call.audioLive)
        XCTAssertFalse(session.call.videoLive)
        XCTAssertEqual(session.sent.last(where: { $0.kind == .callHome })?.wire, C300XCodec.callHome(plant: "1001"))
        XCTAssertTrue(session.history.contains { $0.kind == .call && $0.detail == "Internal unit" })
    }

    func testBlankAccountDoesNotAssociate() async {
        let session = make()
        await session.associate(account: "  ", plantID: "1001", gatewayID: "gw-1")
        XCTAssertEqual(session.association, .signedOut)
        XCTAssertTrue(session.sent.isEmpty)
    }

    private func make() -> Classe300XSession {
        Classe300XSession(transport: QueuedTransport(), shelf: MemoryShelf())
    }
}
