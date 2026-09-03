import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One printer heard on the LAN via SSDP, not yet necessarily configured.
struct DiscoveredPrinter: Identifiable, Equatable {
    var id: String { serial }
    let serial: String
    var ip: String
    var name: String
    var model: String
    var signal: String?
    var firmware: String?
    var lastSeen: Date
}

/// Listens for the SSDP-style discovery broadcasts Bambu Lab printers send
/// on the LAN — the same mechanism Bambu Studio/OrcaSlicer use to populate
/// their printer picker — so IP + serial can be auto-filled instead of
/// typed by hand. The Access Code is never part of this broadcast (it's a
/// secret), so it always stays a manual field.
///
/// Protocol (reverse-engineered, documented by the community — see e.g.
/// https://github.com/Doridian/OpenBambuAPI and various LAN-mode writeups):
/// printers multicast a `NOTIFY * HTTP/1.1` message to 239.255.255.250,
/// sent from UDP port 1900 to destination port 1990 or 2021, roughly every
/// 5 seconds, with headers including:
///   Location: <printer IP>
///   USN: <serial number>
///   DevModel.bambu.com: <model code>
///   DevName.bambu.com: <friendly name, as set in Bambu Handy/Studio>
///   DevSignal.bambu.com: <wifi signal, dBm>
///   DevVersion.bambu.com: <firmware version>
/// This class joins that multicast group on both destination ports using
/// plain BSD sockets (Network.framework's multicast APIs are a poor fit for
/// "listen passively on a fixed well-known port/group"), and keeps a
/// registry of printers seen in the last ~30s.
final class PrinterDiscoveryService {
    private static let multicastAddress = "239.255.255.250"
    private static let ports: [UInt16] = [1990, 2021]
    private static let staleAfter: TimeInterval = 30
    private static let pruneInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "com.obsassistants.discovery")
    private var sources: [DispatchSourceRead] = []
    private var pruneTimer: DispatchSourceTimer?
    private var printers: [String: DiscoveredPrinter] = [:]
    private var totalNotifiesReceived = 0

    /// Called (on an arbitrary queue) whenever the set of currently-seen
    /// printers changes.
    var onUpdate: (([DiscoveredPrinter]) -> Void)?

    func start() {
        stop()
        let interfaceCount = Self.activeIPv4Addresses().count
        print("[Discovery] starting — \(interfaceCount) active IPv4 interface(s) found, joining \(Self.multicastAddress) on ports \(Self.ports)")
        var boundAny = false
        for port in Self.ports {
            guard let fd = Self.makeMulticastSocket(port: port) else {
                // Non-fatal: Bambu Studio/OrcaSlicer/Bambu Handy also listen
                // on these same well-known ports and may already hold one
                // of them (even with SO_REUSEPORT, exact behavior varies).
                // Bambu printers alternate their broadcast between 1990 and
                // 2021, so being bound to just one is normally enough.
                continue
            }
            boundAny = true
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(fd: fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        if !boundAny {
            print("[Discovery] could not bind to \(Self.ports) — another app may hold both. Descoberta automática indisponível; preencha IP/serial manualmente.")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pruneInterval, repeating: Self.pruneInterval)
        timer.setEventHandler { [weak self] in self?.pruneStale() }
        timer.resume()
        pruneTimer = timer
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pruneTimer?.cancel()
        pruneTimer = nil
        queue.async { [weak self] in
            self?.printers.removeAll()
        }
    }

    // MARK: - Receiving

    private func readAvailable(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            if let text = String(bytes: buffer[0..<n], encoding: .utf8) {
                handle(message: text)
            }
        }
    }

    private func handle(message: String) {
        totalNotifiesReceived += 1
        guard message.hasPrefix("NOTIFY") else { return }

        var fields: [String: String] = [:]
        for rawLine in message.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[rawLine.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let serial = fields["USN"], !serial.isEmpty,
              let ip = fields["Location"], !ip.isEmpty else { return }

        printers[serial] = DiscoveredPrinter(
            serial: serial,
            ip: ip,
            name: fields["DevName.bambu.com"].flatMap { $0.isEmpty ? nil : $0 } ?? serial,
            model: fields["DevModel.bambu.com"] ?? "",
            signal: fields["DevSignal.bambu.com"],
            firmware: fields["DevVersion.bambu.com"],
            lastSeen: Date()
        )
        notifyUpdate()
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let before = printers.count
        printers = printers.filter { $0.value.lastSeen > cutoff }
        if printers.count != before {
            notifyUpdate()
        }
        if printers.isEmpty {
            // Heartbeat so it's possible to tell "nothing arriving at all"
            // (0 notifies — points at Local Network permission, AP client
            // isolation, or a VPN eating the interface) apart from "packets
            // arrive but don't parse as expected".
            print("[Discovery] heartbeat: 0 impressoras, \(totalNotifiesReceived) pacote(s) NOTIFY recebido(s) até agora")
        }
    }

    private func notifyUpdate() {
        let list = printers.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        onUpdate?(list)
    }

    // MARK: - Socket setup

    private static func makeMulticastSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        var reusePort: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reusePort, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return nil
        }

        // Join the multicast group on *every* active IPv4 interface, not
        // just INADDR_ANY. On a Mac with more than one interface up at once
        // (Wi-Fi + Ethernet, or a VPN adding a utun interface) INADDR_ANY
        // lets the kernel pick just one — often not the one actually
        // carrying LAN traffic from the printer — so discovery silently
        // never sees anything. Joining explicitly per-interface is the
        // standard fix for multi-homed multicast receivers. Best-effort:
        // an interface that can't join (e.g. a point-to-point VPN tunnel)
        // is simply skipped, not fatal to the socket as a whole.
        var joinedAny = false
        for interfaceAddress in Self.activeIPv4Addresses() {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(multicastAddress)
            mreq.imr_interface = interfaceAddress
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joinedAny = true
            }
        }
        // Always also try the "let the kernel decide" join as a fallback,
        // in case interface enumeration above missed the right one.
        var anyMreq = ip_mreq()
        anyMreq.imr_multiaddr.s_addr = inet_addr(multicastAddress)
        anyMreq.imr_interface.s_addr = in_addr_t(INADDR_ANY)
        if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &anyMreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
            joinedAny = true
        }

        guard joinedAny else {
            close(fd)
            return nil
        }

        // Non-blocking: DispatchSource just tells us data is *available*,
        // recv() itself shouldn't block the discovery queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        return fd
    }

    /// Every "up", non-loopback, IPv4 interface address currently
    /// configured on this Mac (Wi-Fi, Ethernet, etc. — excludes VPN/utun
    /// tunnels, which aren't broadcast-capable and would just fail to join
    /// silently anyway).
    private static func activeIPv4Addresses() -> [in_addr] {
        var addresses: [in_addr] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return addresses }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            addresses.append(sin.sin_addr)
        }
        return addresses
    }
}
