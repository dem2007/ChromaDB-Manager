import XCTest
@testable import ChromaCore

/// a pid is not a name. Before anything is signalled, the process behind
/// it has to be proven to be the one the record describes.
final class ProcessIdentityTests: XCTestCase {
    private let enginePath = "/Users/USER/Library/Application Support/ChromaDBManager/bin/chroma"
    private let startedAt = Date(timeIntervalSince1970: 1_785_485_480)

    private func record(
        pid: Int32 = 4242,
        port: Int = 54982,
        startedAt: Date? = nil
    ) -> RunningServerRecord {
        RunningServerRecord(
            pid: pid,
            port: port,
            host: "127.0.0.1",
            path: "/Users/USER/Library/Application Support/ChromaDBManager/chroma_data",
            label: "Локальная база",
            startedAt: startedAt ?? self.startedAt,
            executablePath: enginePath
        )
    }

    /// Written before: no engine path was stored back then.
    private func legacyRecord() -> RunningServerRecord {
        var legacy = record()
        legacy.executablePath = nil
        return legacy
    }

    private func identity(
        pid: Int32 = 4242,
        path: String? = nil,
        startedAt: Date? = nil,
        ports: [Int] = [54982]
    ) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            executablePath: path ?? enginePath,
            // The record is written a moment after the process starts.
            startedAt: startedAt ?? self.startedAt.addingTimeInterval(-1),
            listeningPorts: ports
        )
    }

    func testTheProcessWeStartedIsConfirmed() {
        let verdict = ServerIdentity.verify(record(), identity: identity(), isAlive: true)
        XCTAssertEqual(verdict, .confirmed)
    }

    func testADeadPidIsGoneRatherThanSuspicious() {
        let verdict = ServerIdentity.verify(record(), identity: nil, isAlive: false)
        XCTAssertEqual(verdict, .gone)
    }

    /// Alive but unreadable. Never signalled — and never forgotten either: a
    /// record dropped here is a live server nobody will find again.
    func testAnUninspectableProcessIsNeitherSignalledNorForgotten() {
        let verdict = ServerIdentity.verify(record(), identity: nil, isAlive: true)
        guard case .unverified = verdict else { return XCTFail("ожидался unverified, получено \(verdict)") }
        XCTAssertFalse(verdict.allowsForgetting)
    }

    func testAReusedPidRunningAnotherProgramIsRejected() {
        let verdict = ServerIdentity.verify(
            record(),
            identity: identity(path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            isAlive: true
        )
        guard case .foreign(let reason) = verdict else { return XCTFail("ожидался foreign") }
        XCTAssertTrue(reason.contains("Safari"), reason)
        XCTAssertTrue(verdict.allowsForgetting, "чужой процесс — наш сервер точно исчез")
    }

    /// The same binary path, but started hours later: the system handed the
    /// number to a new run of the engine that this record knows nothing about.
    func testAReusedPidWithADifferentStartTimeIsRejected() {
        let verdict = ServerIdentity.verify(
            record(),
            identity: identity(startedAt: startedAt.addingTimeInterval(7 * 3600)),
            isAlive: true
        )
        guard case .foreign(let reason) = verdict else { return XCTFail("ожидался foreign") }
        XCTAssertTrue(reason.contains("PID переиспользован"), reason)
        XCTAssertTrue(verdict.allowsForgetting)
    }

    /// The same binary started at the same second, but not listening on the
    /// recorded port. That is «пока не подтвердил», not «это чужой процесс»:
    /// the port list is read through file descriptors and can fail, and a
    /// server that is still starting has not bound yet.
    func testAProcessNotHoldingTheRecordedPortIsUnverifiedRatherThanForeign() {
        let verdict = ServerIdentity.verify(record(), identity: identity(ports: [57408]), isAlive: true)
        guard case .unverified(let reason) = verdict else { return XCTFail("ожидался unverified, получено \(verdict)") }
        XCTAssertTrue(reason.contains("54982"), reason)
        XCTAssertFalse(verdict.allowsForgetting, "живой процесс нельзя забывать — иначе он останется навсегда")
    }

    func testDriftUpToTheToleranceIsAccepted() {
        let late = identity(startedAt: startedAt.addingTimeInterval(-ServerIdentity.startTimeTolerance + 1))
        XCTAssertEqual(ServerIdentity.verify(record(), identity: late, isAlive: true), .confirmed)
    }

    // MARK: - Records written before

    func testALegacyRecordFallsBackToTheFileName() {
        XCTAssertEqual(
            ServerIdentity.verify(legacyRecord(), identity: identity(path: "/opt/homebrew/bin/chroma"), isAlive: true),
            .confirmed
        )
    }

    /// The old check was `command.contains("chroma")`, which any process with
    /// the word anywhere in its command line satisfied.
    func testALegacyRecordStillRejectsAProgramMerelyNamedLikeUs() {
        let verdict = ServerIdentity.verify(
            legacyRecord(),
            identity: identity(path: "/Users/USER/Documents/AI/chroma-tools/bin/inspector"),
            isAlive: true
        )
        guard case .foreign = verdict else { return XCTFail("ожидался foreign, получено \(verdict)") }
    }

    // MARK: - The live system

    /// The inspector is read against this very test process: whatever else is
    /// true, it is alive, it has a path, and it started in the past.
    func testTheInspectorReadsThisProcess() throws {
        let me = getpid()
        XCTAssertTrue(ProcessInspector.isAlive(me))
        let identity = try XCTUnwrap(ProcessInspector.identity(of: me))
        XCTAssertEqual(identity.pid, me)
        XCTAssertFalse(identity.executablePath.isEmpty)
        XCTAssertLessThanOrEqual(identity.startedAt, Date())
        XCTAssertGreaterThan(identity.startedAt, Date(timeIntervalSince1970: 0))
    }

    /// `launchd` belongs to root: `kill(1, 0)` answers EPERM, and that has to
    /// read as "not ours to touch" rather than as "alive".
    func testAnotherUsersProcessIsNotReportedAlive() {
        XCTAssertFalse(ProcessInspector.isAlive(1))
    }

    /// The rules against a real `chroma run`: set `CDBM_LIVE_PID` and
    /// `CDBM_LIVE_PORT` to a running server.
    func testARunningServerIsConfirmedAndEveryAlteredRecordIsNot() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["CDBM_LIVE_PID"], let pid = Int32(raw),
              let rawPort = environment["CDBM_LIVE_PORT"], let port = Int(rawPort) else {
            throw XCTSkip("живая проверка: задайте CDBM_LIVE_PID и CDBM_LIVE_PORT")
        }

        let live = try XCTUnwrap(ProcessInspector.identity(of: pid), "процесс \(pid) недоступен")
        XCTAssertTrue(live.listeningPorts.contains(port), "процесс не слушает \(port): \(live.listeningPorts)")

        var honest = record(pid: pid, port: port, startedAt: live.startedAt)
        honest.executablePath = live.executablePath
        XCTAssertEqual(ServerIdentity.verify(honest), .confirmed)

        var wrongPort = honest
        wrongPort.port = port == 1 ? 2 : port - 1
        guard case .unverified = ServerIdentity.verify(wrongPort) else {
            return XCTFail("чужой порт принят за свой")
        }

        var wrongStart = honest
        wrongStart.startedAt = live.startedAt.addingTimeInterval(3600)
        guard case .foreign = ServerIdentity.verify(wrongStart) else {
            return XCTFail("переиспользованный PID принят за свой")
        }

        var wrongBinary = honest
        wrongBinary.executablePath = "/usr/bin/true"
        guard case .foreign = ServerIdentity.verify(wrongBinary) else {
            return XCTFail("чужая программа принята за движок")
        }
    }

    func testAFreshPidHasNoIdentity() {
        // Nothing can be running under a pid this far above the current one.
        XCTAssertNil(ProcessInspector.identity(of: 99_999_999))
        XCTAssertFalse(ProcessInspector.isAlive(99_999_999))
    }
}

/// записи о серверах удаляются только тогда, когда судьба процесса известна.
final class ServerRecordRetentionTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

    private func record(pid: Int32 = 4242, port: Int = 54982) -> RunningServerRecord {
        RunningServerRecord(
            pid: pid, port: port, host: "127.0.0.1",
            path: "/tmp/chroma", label: "Локальная база", startedAt: startedAt,
            executablePath: "/Users/USER/Library/Application Support/ChromaDBManager/bin/chroma"
        )
    }

    private func identity(ports: [Int] = [54982]) -> ProcessIdentity {
        ProcessIdentity(
            pid: 4242,
            executablePath: "/Users/USER/Library/Application Support/ChromaDBManager/bin/chroma",
            startedAt: startedAt,
            listeningPorts: ports
        )
    }

    func testOnlyAKnownFateAllowsForgetting() {
        XCTAssertTrue(ServerIdentityVerdict.gone.allowsForgetting)
        XCTAssertTrue(ServerIdentityVerdict.foreign("чужой").allowsForgetting)
        XCTAssertFalse(ServerIdentityVerdict.unverified("не прочитал").allowsForgetting)
        XCTAssertFalse(ServerIdentityVerdict.confirmed.allowsForgetting, "работающий сервер тем более не забывают")
    }

    /// The shape of the leak that produced four abandoned servers: alive, ours
    /// by every readable sign, one fact unread — and dropped from memory.
    func testALiveServerWithAnUnreadablePortStaysRemembered() {
        let verdict = ServerIdentity.verify(record(), identity: identity(ports: []), isAlive: true)
        XCTAssertFalse(verdict.allowsForgetting)
        XCTAssertNotNil(verdict.reason)
    }

    func testAConfirmedRecordHasNothingToExplain() {
        let verdict = ServerIdentity.verify(record(), identity: identity(), isAlive: true)
        XCTAssertEqual(verdict, .confirmed)
        XCTAssertNil(verdict.reason)
    }
}
