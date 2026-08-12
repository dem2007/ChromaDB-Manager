import Foundation

/// Which interfaces a listener is bound to.
///
/// The switch exists for the **proxy only**. The ChromaDB server itself stays
/// on loopback whatever the user picks: it has no per-collection permissions,
/// no read-only mode and one token for the whole instance, so putting
/// it on the network hands the entire database to whoever finds the port. The
/// proxy is the thing that knows how to say no, so the proxy is the thing that
/// may be exposed.
public enum NetworkExposure: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Only this machine can connect. Default, and where «экстренная остановка»
    /// puts things back to.
    case loopback
    /// Anyone who can reach this machine on the local network can connect.
    case allInterfaces

    public var id: String { rawValue }

    public var bindHost: String {
        switch self {
        case .loopback: return "127.0.0.1"
        case .allInterfaces: return "0.0.0.0"
        }
    }

    public var isExposed: Bool { self == .allInterfaces }

    public var title: String {
        switch self {
        case .loopback: return String(localized: "Только этот компьютер (127.0.0.1)")
        case .allInterfaces: return String(localized: "Локальная сеть (0.0.0.0)")
        }
    }

    public var subtitle: String {
        switch self {
        case .loopback:
            return String(localized: "Подключиться могут только программы на этом Маке.")
        case .allInterfaces:
            return String(localized: "Подключиться сможет любое устройство, которое видит этот Мак по сети — с действующим ключом.")
        }
    }
}

/// The addresses this machine answers on, for the «куда подключаться» line on
/// the security screen. Without it the user is told the proxy is open to the
/// network and left to find the address themselves.
public enum LocalNetwork {
    /// IPv4 addresses of the up, non-loopback interfaces.
    public static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let text = String(cString: buffer)
            if !text.isEmpty && !found.contains(text) { found.append(text) }
        }
        return found
    }
}
