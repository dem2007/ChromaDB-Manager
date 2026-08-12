import Foundation
import Darwin

/// What the kernel knows about a live process.
///
/// Read through `libproc` rather than by parsing `ps`: the engine lives under
/// `Application Support`, so its path contains spaces and there is no reliable
/// way to tell the executable from its arguments in a `ps` line.
public struct ProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let executablePath: String
    public let startedAt: Date
    /// TCP ports the process is listening on. This is the only fact that ties a
    /// saved record to a running process by something the process cannot fake
    /// and a stranger cannot coincidentally match.
    public let listeningPorts: [Int]

    public init(pid: Int32, executablePath: String, startedAt: Date, listeningPorts: [Int]) {
        self.pid = pid
        self.executablePath = executablePath
        self.startedAt = startedAt
        self.listeningPorts = listeningPorts
    }
}

public enum ProcessInspector {
    /// `nil` when the process is gone, or belongs to another user and cannot be
    /// inspected. Both answers mean the same thing to the caller: do not signal it.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0, let path = executablePath(of: pid), let started = startTime(of: pid) else {
            return nil
        }
        return ProcessIdentity(
            pid: pid,
            executablePath: path,
            startedAt: started,
            listeningPorts: listeningPorts(of: pid)
        )
    }

    /// True only when the process exists *and* this user may signal it: `kill`
    /// answers `EPERM` for everyone else's processes, which is the safe direction.
    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let seconds = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    static func listeningPorts(of pid: Int32) -> [Int] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bufferSize)
        guard used > 0 else { return [] }

        var ports: [Int] = []
        let count = min(capacity, Int(used) / MemoryLayout<proc_fdinfo>.size)
        for descriptor in descriptors[0..<count]
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, size) == size,
                  socketInfo.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socketInfo.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // The port sits in a host-order Int32 field in network byte order.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.append(port) }
        }
        return ports
    }
}

/// The answer to "may this pid be signalled on behalf of this record?".
public enum ServerIdentityVerdict: Equatable, Sendable {
    /// The process is the one the record describes.
    case confirmed
    /// Nothing is running under that pid any more — forget the record.
    case gone
    /// Something *is* running there and it is demonstrably **not** ours: the
    /// pid was reused. Never signal it, and forget the record — our server is
    /// gone, whatever happened to it.
    case foreign(String)
    /// Something is running there that may well be ours, but one fact could not
    /// be read. Never signal it — and **never forget it either**.
    ///
    /// The distinction matters more than it looks. «Не смог подтвердить» used
    /// to be treated as «можно забыть», and a live server that failed one check
    /// once disappeared from the app's memory for good: not offered to stop, not
    /// found at the next launch, holding the database directory until somebody
    /// noticed it in Activity Monitor.
    case unverified(String)

    public var isConfirmed: Bool { self == .confirmed }

    /// Whether the record may be dropped. Only when we know what happened to
    /// the process — not when we merely failed to look.
    public var allowsForgetting: Bool {
        switch self {
        case .gone, .foreign: return true
        case .confirmed, .unverified: return false
        }
    }

    public var reason: String? {
        switch self {
        case .confirmed, .gone: return nil
        case .foreign(let reason), .unverified(let reason): return reason
        }
    }
}

public enum ServerIdentity {
    /// The record is written a moment after the process starts, so the two
    /// timestamps never match exactly — a second of drift is normal. A reused
    /// pid is minutes or hours off, never a second.
    public static let startTimeTolerance: TimeInterval = 10

    /// Pure so the rules can be tested without spawning anything.
    public static func verify(
        _ record: RunningServerRecord,
        identity: ProcessIdentity?,
        isAlive: Bool
    ) -> ServerIdentityVerdict {
        guard isAlive else { return .gone }
        // Alive but unreadable. That is a failure to look, not a fact about the
        // process: it stays untouched and stays remembered.
        guard let identity else {
            return .unverified(String(localized: "сведения о процессе недоступны"))
        }

        if let expected = record.executablePath {
            guard identity.executablePath == expected else {
                return .foreign(String(localized: "PID занят другой программой: \(identity.executablePath)"))
            }
        } else if URL(fileURLWithPath: identity.executablePath).lastPathComponent != "chroma" {
            // Records written before this check carry no path; the file name is
            // all we have, and it is still better than a substring match.
            return .foreign(String(localized: "PID занят другой программой: \(identity.executablePath)"))
        }

        let drift = abs(identity.startedAt.timeIntervalSince(record.startedAt))
        guard drift <= startTimeTolerance else {
            return .foreign(String(localized: "время старта расходится на \(Int(drift).plainDigits) с — PID переиспользован"))
        }

        // The port is the one fact that can be *temporarily* false about our own
        // server: it is read through the process's file descriptors, which can
        // fail, and a server that is still starting has not bound yet. Same
        // executable, same start time, wrong port — that is «пока не подтвердил»,
        // not «это чужой процесс».
        guard identity.listeningPorts.contains(record.port) else {
            return .unverified(String(localized: "процесс не слушает порт \(record.port.plainDigits)"))
        }

        return .confirmed
    }

    /// Same rules against the live system.
    public static func verify(_ record: RunningServerRecord) -> ServerIdentityVerdict {
        verify(
            record,
            identity: ProcessInspector.identity(of: record.pid),
            isAlive: ProcessInspector.isAlive(record.pid)
        )
    }
}
