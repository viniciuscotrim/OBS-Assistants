import Foundation
import Network
import Security

enum MQTTClientState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    case disconnected
}

/// A small MQTT 3.1.1-over-TLS client built directly on Network.framework.
/// No third-party dependency — this is all the printer's local broker
/// actually needs (CONNECT, one SUBSCRIBE, receive PUBLISH, one PUBLISH to
/// request "pushall", keepalive PING). TLS trust is relaxed because Bambu
/// printers serve a self-signed certificate on the LAN broker; optionally a
/// client identity (SecIdentity) can be supplied for mutual-TLS, used by
/// BambuConnectionManager's post-Jan/2025-firmware fallback.
final class MQTTClient {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.obsassistants.mqtt")
    private var reader = MQTTPacketReader()
    private var pingTimer: DispatchSourceTimer?
    private var nextPacketID: UInt16 = 1

    var onStateChange: ((MQTTClientState) -> Void)?
    var onMessage: ((String, Data) -> Void)?

    private(set) var state: MQTTClientState = .idle {
        didSet { onStateChange?(state) }
    }

    func connect(
        host: String,
        port: UInt16 = 8883,
        clientID: String,
        username: String,
        password: String,
        clientIdentity: SecIdentity? = nil
    ) {
        disconnect()
        state = .connecting

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        // Bambu's local broker presents a self-signed certificate; this is a
        // LAN-only connection to an IP the user typed in themselves, so we
        // accept it rather than pin/verify a CA chain that doesn't exist.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            queue
        )
        if let identity = clientIdentity {
            let secIdentity = sec_identity_create(identity)
            if let secIdentity {
                sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
            }
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 8

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let endpoint = NWEndpoint.Host(host)
        let conn = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.sendConnectPacket(clientID: clientID, username: username, password: password)
                self.startReceiving()
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
                self.teardown()
            case .cancelled:
                if case .connecting = self.state {
                    self.state = .failed("Conexão cancelada")
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        if let connection, connection.state == .ready {
            connection.send(content: MQTTEncode.disconnect(), completion: .contentProcessed { _ in })
        }
        connection?.cancel()
        connection = nil
        reader = MQTTPacketReader()
        if state != .idle { state = .disconnected }
    }

    /// Publish a JSON payload (QoS 0) to a topic — used for the
    /// "pushing.pushall" request that asks the printer for a full status
    /// dump instead of only deltas.
    func publish(topic: String, jsonObject: [String: Any]) {
        guard let connection, connection.state == .ready else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
        let packet = MQTTEncode.publish(topic: topic, payload: data)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: - Internals

    private func sendConnectPacket(clientID: String, username: String, password: String) {
        let packet = MQTTEncode.connect(clientID: clientID, username: username, password: password)
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.state = .failed("Falha ao enviar CONNECT: \(error.localizedDescription)")
            }
        })
    }

    private func startReceiving() {
        receiveLoop()
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.reader.append(data)
                for packet in self.reader.drainPackets() {
                    self.handle(packet)
                }
            }
            if let error {
                self.state = .failed(error.localizedDescription)
                self.teardown()
                return
            }
            if isComplete {
                self.state = .disconnected
                self.teardown()
                return
            }
            self.receiveLoop()
        }
    }

    private func handle(_ packet: MQTTRawPacket) {
        guard let type = MQTTPacketType(rawValue: packet.type) else { return }
        switch type {
        case .connack:
            let returnCode = packet.payload.count >= 2 ? packet.payload[packet.payload.startIndex + 1] : 0xFF
            if returnCode == 0 {
                state = .connected
                subscribeAndArmKeepalive()
            } else {
                state = .failed(Self.connackErrorDescription(returnCode))
                teardown()
            }
        case .publish:
            if let (topic, body) = MQTTDecode.parsePublish(packet.payload) {
                onMessage?(topic, body)
            }
        case .pingresp, .puback, .suback:
            break
        default:
            break
        }
    }

    /// Called once CONNACK succeeds; subscription topic itself is driven by
    /// the caller via `subscribeTopic`, set before connect() in practice —
    /// kept simple by having BambuConnectionManager call `subscribe(topic:)`
    /// directly once it observes `.connected`.
    private var pendingSubscribeTopic: String?
    func subscribe(topic: String) {
        pendingSubscribeTopic = topic
        if state == .connected {
            sendSubscribe(topic: topic)
        }
    }

    private func subscribeAndArmKeepalive() {
        if let topic = pendingSubscribeTopic {
            sendSubscribe(topic: topic)
        }
        armKeepalive()
    }

    private func sendSubscribe(topic: String) {
        let id = nextPacketID
        nextPacketID = nextPacketID &+ 1
        let packet = MQTTEncode.subscribe(packetID: id, topic: topic)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func armKeepalive() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection, connection.state == .ready else { return }
            connection.send(content: MQTTEncode.pingreq(), completion: .contentProcessed { _ in })
        }
        timer.resume()
        pingTimer = timer
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
    }

    private static func connackErrorDescription(_ code: UInt8) -> String {
        switch code {
        case 1: return "Versão de protocolo MQTT não aceita"
        case 2: return "Identificador de cliente rejeitado"
        case 3: return "Serviço MQTT indisponível"
        case 4: return "Usuário/senha inválidos (verifique o Access Code)"
        case 5: return "Não autorizado (a impressora pode exigir certificado X.509 — ver fallback)"
        default: return "CONNACK code \(code)"
        }
    }
}
