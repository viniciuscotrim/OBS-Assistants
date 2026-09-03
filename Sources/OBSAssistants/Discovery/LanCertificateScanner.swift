import Foundation
import Network
import Security
#if canImport(Darwin)
import Darwin
#endif

/// A printer found by actively probing the LAN, rather than waiting for it
/// to announce itself.
struct ScannedPrinter: Identifiable, Equatable {
    var id: String { serial }
    let serial: String
    let ip: String
}

/// Active fallback for when passive SSDP discovery
/// (`PrinterDiscoveryService`) doesn't work — which in practice is common:
/// plenty of home routers/mesh systems drop or mis-forward multicast
/// (missing IGMP querier, "AP/client isolation", etc.) while ordinary
/// unicast TCP works fine.
///
/// This scans the Mac's local subnet for hosts with Bambu's MQTT/TLS port
/// (8883) open, opens a TLS connection to each, and reads the printer's
/// **serial number straight out of its TLS certificate's Common Name** —
/// Bambu device certs are issued as `CN=<serial>` by "BBL Device CA" — all
/// without needing the Access Code or completing a real MQTT handshake
/// (the connection is aborted the instant the certificate is inspected).
/// Confirmed against a real printer: `openssl s_client -connect
/// <ip>:8883` shows `subject=/CN=<serial>`.
final class LanCertificateScanner {
    // NWConnection callbacks are dispatched to this queue; nothing on it
    // ever blocks synchronously, so it's safe for all outstanding probes to
    // share it (no thread-pool exhaustion risk the way a blocking
    // DispatchSemaphore.wait() on a concurrent queue would have).
    private let callbackQueue = DispatchQueue(label: "com.obsassistants.lanscan")
    private let maxConcurrent = 48
    private let perHostTimeout: TimeInterval = 1.5

    func scan(completion: @escaping ([ScannedPrinter]) -> Void) {
        guard let hosts = Self.localSubnetHosts() else {
            completion([])
            return
        }

        var results: [ScannedPrinter] = []
        let resultsLock = NSLock()
        var remaining = hosts.count
        var index = 0
        let stateLock = NSLock()

        guard !hosts.isEmpty else {
            completion([])
            return
        }

        // Simple concurrency-limited pump: keep `maxConcurrent` probes in
        // flight, kicking off the next one each time one finishes — all
        // book-keeping here is non-blocking (just a short NSLock around
        // plain array/int access), so there's no risk of starving the
        // queue that the async network callbacks themselves need to run on.
        func finishedOne(_ printer: ScannedPrinter?) {
            if let printer {
                resultsLock.lock()
                results.append(printer)
                resultsLock.unlock()
            }
            var nextHost: String?
            var isDone = false
            stateLock.lock()
            remaining -= 1
            if index < hosts.count {
                nextHost = hosts[index]
                index += 1
            }
            isDone = remaining == 0
            stateLock.unlock()

            if let nextHost {
                self.probe(host: nextHost, completion: finishedOne)
            }
            if isDone {
                completion(results)
            }
        }

        let initialBatch = min(maxConcurrent, hosts.count)
        stateLock.lock()
        index = initialBatch
        stateLock.unlock()
        for i in 0..<initialBatch {
            probe(host: hosts[i], completion: finishedOne)
        }
    }

    // MARK: - Probing one host

    private final class SerialBox { var serial: String? }

    private func probe(host: String, completion: @escaping (ScannedPrinter?) -> Void) {
        let box = SerialBox()

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, secTrustRef, verifyComplete in
                let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                    // Any device on the LAN might happen to speak TLS on
                    // 8883 (routers/NAS boxes sometimes do) — only trust
                    // this as "it's a Bambu printer" if the cert was
                    // actually issued by Bambu's device CA, not just
                    // because *some* cert with a CN showed up.
                    let issuedByBambu = chain.dropFirst().contains { cert in
                        let issuerSummary = (SecCertificateCopySubjectSummary(cert) as String?) ?? ""
                        return issuerSummary.localizedCaseInsensitiveContains("BBL")
                            || issuerSummary.localizedCaseInsensitiveContains("Bambu")
                    }
                    if issuedByBambu, let cn = SecCertificateCopySubjectSummary(leaf) as String? {
                        box.serial = cn
                    }
                }
                // We only wanted to look at the certificate — no need (and
                // no credentials) to complete a real handshake.
                verifyComplete(false)
            },
            callbackQueue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 1

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        guard let port = NWEndpoint.Port(rawValue: 8883) else {
            completion(nil)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

        var finished = false
        let finishLock = NSLock()
        func finishOnce() {
            finishLock.lock()
            defer { finishLock.unlock() }
            guard !finished else { return }
            finished = true
            connection.cancel()
            if let serial = box.serial {
                completion(ScannedPrinter(serial: serial, ip: host))
            } else {
                completion(nil)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                finishOnce()
            default:
                break
            }
        }
        connection.start(queue: callbackQueue)

        // Belt-and-suspenders timeout: a filtered/firewalled port can leave
        // the TCP handshake hanging past NWProtocolTCP's own connect timeout
        // in some network conditions.
        callbackQueue.asyncAfter(deadline: .now() + perHostTimeout) {
            finishOnce()
        }
    }

    // MARK: - Subnet enumeration

    /// All host addresses (excluding network/broadcast) on the local
    /// non-loopback IPv4 subnet, as dotted strings. Falls back to just the
    /// /24 containing the local address if the actual subnet is
    /// implausibly large (e.g. a misconfigured /8), to keep the scan from
    /// taking forever.
    private static func localSubnetHosts() -> [String]? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let maskSa = current.pointee.ifa_netmask, maskSa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let addrBE = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let maskBE = maskSa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let addr = UInt32(bigEndian: addrBE)
            let mask = UInt32(bigEndian: maskBE)

            // Skip link-local (169.254.0.0/16, no real LAN behind it).
            if (addr >> 16) == 0xA9FE { continue }

            var network = addr & mask
            var broadcast = network | ~mask
            if broadcast - network > 4096 {
                // Implausibly large (e.g. /8) — scan just the local /24
                // instead of the whole thing.
                network = addr & 0xFFFFFF00
                broadcast = network | 0xFF
            }
            guard broadcast > network + 1 else { continue }

            var hosts: [String] = []
            hosts.reserveCapacity(Int(broadcast - network))
            for host in (network + 1)..<broadcast {
                hosts.append(Self.dotted(host))
            }
            return hosts
        }
        return nil
    }

    private static func dotted(_ addr: UInt32) -> String {
        "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
    }
}
