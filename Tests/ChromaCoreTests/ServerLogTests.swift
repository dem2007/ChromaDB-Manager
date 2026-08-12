import XCTest
@testable import ChromaCore

/// The strings below are copied verbatim from chroma 1.4.4 running on this
/// machine — the whole point of the parser is that it matches reality.
final class ServerFailureTests: XCTestCase {
    private let banner = [
        "Saving data to: /Users/USER/Library/Application Support/ChromaDBManager/chroma_data",
        "Connect to Chroma at: http://localhost:8000",
        "No telemetry is configured.",
    ]

    func testPortConflictIsRecognisedAndNamesThePort() {
        let output = banner + [
            "thread 'main' (766046) panicked at /Users/runner/work/chroma/chroma/rust/frontend/src/server.rs:417:66:",
            #"called `Result::unwrap()` on an `Err` value: Os { code: 48, kind: AddrInUse, message: "Address already in use" }"#,
            "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace",
        ]
        let failure = ServerFailure.diagnose(output: output, exitCode: 101, expectedPort: 8000)
        XCTAssertEqual(failure, .addressInUse(port: 8000))
        XCTAssertTrue(failure?.message.contains("8000") == true)
        XCTAssertNotNil(failure?.suggestion, "у занятого порта должен быть совет, что делать")
    }

    func testUnwritablePathIsRecognisedAndNamesTheFolder() {
        let output = [
            "Saving data to: /System/nope/db",
            "thread 'main' (767399) panicked at /Users/runner/work/chroma/chroma/rust/frontend/src/lib.rs:89:10:",
            #"Error creating Frontend Config: PathError(Os { code: 1, kind: PermissionDenied, message: "Operation not permitted" })"#,
            "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace",
        ]
        XCTAssertEqual(
            ServerFailure.diagnose(output: output, exitCode: 101),
            .pathNotPermitted(path: "/System/nope/db")
        )
    }

    func testUnknownPanicKeepsTheServersOwnWording() {
        let output = banner + [
            "thread 'main' (1) panicked at src/lib.rs:1:1:",
            "something we have never seen",
            "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace",
        ]
        guard case .panic(let reason)? = ServerFailure.diagnose(output: output, exitCode: 101) else {
            return XCTFail("нераспознанная паника должна оставаться паникой")
        }
        XCTAssertEqual(reason, "something we have never seen")
        XCTAssertFalse(reason.contains("RUST_BACKTRACE"), "служебная строка не должна попадать в сообщение")
    }

    func testCleanExitIsNotAFailure() {
        // SIGTERM from our own stop(): chroma exits 0 and prints nothing.
        XCTAssertNil(ServerFailure.diagnose(output: banner, exitCode: 0))
    }

    func testNonZeroExitWithoutAPanicStillReportsTheCode() {
        XCTAssertEqual(ServerFailure.diagnose(output: banner, exitCode: 137), .exited(code: 137))
    }
}

final class ServerLogStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-serverlog-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARunIsWrittenToItsOwnFile() throws {
        let store = ServerLogStore(directory: directory)
        let url = try XCTUnwrap(store.beginRun(label: "Локальная база", command: "chroma run config.yaml"))
        store.append(["Connect to Chroma at: http://localhost:8000", "No telemetry is configured."])
        store.endRun(note: "остановлен")

        let text = try waitForContents(of: url, containing: "остановлен")
        XCTAssertTrue(text.contains("chroma run config.yaml"), "команда запуска должна быть в файле")
        XCTAssertTrue(text.contains("No telemetry is configured."))
        XCTAssertEqual(store.runs().count, 1)
    }

    func testOnlyTheLastRunsAreKept() throws {
        let store = ServerLogStore(directory: directory, keepRuns: 2)
        for index in 1...4 {
            store.beginRun(label: "run \(index)", command: "chroma run")
            store.append(["line \(index)"])
            store.endRun(note: "готово")
            // File names carry a one-second stamp; without this the runs would
            // collide instead of accumulating.
            Thread.sleep(forTimeInterval: 1.05)
        }
        XCTAssertEqual(store.runs().count, 2, "старые файлы должны удаляться")
    }

    func testAppendingWithoutARunDoesNotCrash() {
        let store = ServerLogStore(directory: directory)
        store.append(["сирота"])
        store.endRun(note: "нечего закрывать")
        XCTAssertTrue(store.runs().isEmpty)
    }

    /// Writes are queued, so the file lags the call by a moment.
    private func waitForContents(of url: URL, containing marker: String) throws -> String {
        for _ in 0..<50 {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains(marker) { return text }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class PortAvailabilityTests: XCTestCase {
    func testAFreePortLooksFreeAndAnOccupiedOneDoesNot() throws {
        let port = PortUtility.freePort()
        XCTAssertTrue(PortUtility.isAvailable(host: "127.0.0.1", port: port))

        // Hold the port the way a running server would.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bound != 0, "порт успели занять между вызовами")
        XCTAssertEqual(listen(listener, 1), 0)

        XCTAssertFalse(
            PortUtility.isAvailable(host: "127.0.0.1", port: port),
            "занятый порт не должен считаться свободным — иначе приложение отчитается о чужом сервере как о своём"
        )
    }
}

final class AutoStartSettingTests: XCTestCase {
    func testAutoStartDefaultsToOnForConfigsWrittenBeforeTheSwitchExisted() throws {
        // A config from stage 2 has no such key; the app must keep behaving the
        // way the user is used to.
        let json = #"{"mode":"localDatabase","serverProfiles":[],"lmStudioBaseURL":"http://localhost:1234"}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertTrue(configuration.autoStartServerOnLaunch)
    }

    func testAutoStartSurvivesARoundTrip() throws {
        var configuration = AppConfiguration()
        configuration.autoStartServerOnLaunch = false
        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertFalse(restored.autoStartServerOnLaunch)
    }
}
