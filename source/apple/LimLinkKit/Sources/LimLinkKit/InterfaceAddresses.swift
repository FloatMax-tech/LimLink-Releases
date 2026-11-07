import Darwin
import Foundation

/// Current NIC addresses for the same-device check. Loopback is recognized even when absent here.
public enum InterfaceAddresses {
    public static func current() -> Set<String> {
        var found: Set<String> = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return found }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            if let address = item.pointee.ifa_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    found.insert(String(decoding: bytes, as: UTF8.self))
                }
            }
            cursor = item.pointee.ifa_next
        }
        return found
    }
}
