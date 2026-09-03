import Foundation
import Network
import CryptoKit

/// Minimal embedded HTTP/1.1 server built on Network.framework — its own
/// listener/port, independent of `LocalHTTPServer` (the printer overlay's
/// server). Kept as a separate listener (rather than folded into
/// LocalHTTPServer's routes) so each overlay's OBS Browser Source URL keeps
/// its own stable host:port, unaffected by the other overlay starting,
/// stopping, or changing port. Serves:
///   GET /nowplaying     -> JSON snapshot of the current Music.app track
///   GET /artwork.png    -> current track's artwork (PNG)
///   GET /, /overlay.*   -> the overlay page (embedded in NowPlayingAssets)
///   WS  /audio-stream   -> live 16-bit PCM audio (48kHz, stereo), when audio
///                          capture is active — lets the overlay page itself
///                          play Music.app's audio, so OBS only needs ONE
///                          Browser Source (video + audio) instead of a
///                          separate audio input source.
final class NowPlayingHTTPServer {

    enum ServerError: Error, CustomStringConvertible {
        case portInUse
        case other(String)

        var description: String {
            switch self {
            case .portInUse: return "A porta já está em uso por outro processo."
            case .other(let msg): return msg
            }
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.obsassistants.nowplaying.http")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Connections that completed a WebSocket handshake on /audio-stream and
    /// are receiving broadcast PCM frames.
    private var audioSubscribers: [ObjectIdentifier: NWConnection] = [:]

    /// Supplies the latest snapshot on demand (called from the server queue).
    var snapshotProvider: (() -> NowPlayingInfo)?
    /// Supplies the path to the current artwork PNG file, if any.
    var artworkURLProvider: (() -> URL?)?

    private(set) var port: UInt16 = 8080
    private(set) var isRunning = false

    func start(port: UInt16, completion: @escaping (Result<Void, ServerError>) -> Void) {
        stop()
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(.other("Porta inválida.")))
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: nwPort)
        } catch {
            completion(.failure(.other(error.localizedDescription)))
            return
        }

        var didComplete = false
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                if !didComplete { didComplete = true; completion(.success(())) }
            case .failed(let error):
                self.isRunning = false
                if !didComplete {
                    didComplete = true
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        completion(.failure(.portInUse))
                    } else {
                        completion(.failure(.other(error.localizedDescription)))
                    }
                }
                self.stop()
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        audioSubscribers.removeAll()
    }

    /// Sends one chunk of raw PCM audio (see `AudioCaptureEngine`) to every
    /// currently-connected /audio-stream WebSocket client, wrapped as a
    /// binary WebSocket frame. Safe to call from any thread/queue.
    func broadcastAudio(_ pcmData: Data) {
        queue.async { [weak self] in
            guard let self, !self.audioSubscribers.isEmpty else { return }
            let frame = Self.makeWebSocketFrame(binaryPayload: pcmData)
            for (key, connection) in self.audioSubscribers {
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.queue.async {
                            self?.audioSubscribers.removeValue(forKey: key)
                            connection.cancel()
                        }
                    }
                })
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.lowerBound]
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                self.handle(headerText: headerText, connection: connection)
                return
            }

            if isComplete || error != nil || data == nil {
                self.closeConnection(connection)
                return
            }

            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private func closeConnection(_ connection: NWConnection) {
        connection.cancel()
        let key = ObjectIdentifier(connection)
        connections.removeValue(forKey: key)
        audioSubscribers.removeValue(forKey: key)
    }

    private func handle(headerText: String, connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            respond(connection, status: 400, contentType: "text/plain", body: Data("Bad Request".utf8))
            return
        }
        let method = components[0]
        let fullPath = components[1]
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if path == "/audio-stream" {
            handleAudioStreamUpgrade(headers: headers, connection: connection)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            respond(connection, status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8))
            return
        }

        switch path {
        case "/nowplaying":
            let info = snapshotProvider?() ?? .idle
            let body = (try? JSONEncoder().encode(info)) ?? Data("{}".utf8)
            respond(connection, status: 200, contentType: "application/json; charset=utf-8", body: body, cors: true, cache: false)

        case "/artwork.png":
            if let url = artworkURLProvider?(), let data = try? Data(contentsOf: url) {
                respond(connection, status: 200, contentType: "image/png", body: data, cors: true, cache: false)
            } else {
                respond(connection, status: 404, contentType: "text/plain", body: Data("No artwork".utf8), cors: true)
            }

        case "/", "/overlay.html", "/index.html":
            respond(connection, status: 200, contentType: "text/html; charset=utf-8", body: Data(NowPlayingAssets.html.utf8), cache: false)

        case "/overlay.css":
            respond(connection, status: 200, contentType: "text/css; charset=utf-8", body: Data(NowPlayingAssets.css.utf8), cache: false)

        case "/overlay.js":
            respond(connection, status: 200, contentType: "application/javascript; charset=utf-8", body: Data(NowPlayingAssets.js.utf8), cache: false)

        default:
            respond(connection, status: 404, contentType: "text/plain", body: Data("Not Found".utf8))
        }
    }

    // MARK: - WebSocket (/audio-stream)

    private func handleAudioStreamUpgrade(headers: [String: String], connection: NWConnection) {
        guard (headers["upgrade"]?.lowercased() == "websocket"),
              let clientKey = headers["sec-websocket-key"] else {
            respond(connection, status: 400, contentType: "text/plain", body: Data("Expected a WebSocket upgrade".utf8))
            return
        }

        let acceptKey = Self.webSocketAcceptKey(for: clientKey)
        let headerLines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
            "",
            ""
        ]
        let responseData = Data(headerLines.joined(separator: "\r\n").utf8)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.closeConnection(connection)
                return
            }
            let key = ObjectIdentifier(connection)
            self.audioSubscribers[key] = connection
            // We never need anything FROM the client beyond the handshake —
            // just keep draining incoming frames (pings/close) so the
            // connection notices when the browser navigates away or OBS
            // drops the source, instead of leaking a dead subscriber.
            self.drainWebSocketClient(connection)
        })
    }

    private func drainWebSocketClient(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.closeConnection(connection)
                return
            }
            self.drainWebSocketClient(connection)
        }
    }

    private static func webSocketAcceptKey(for clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    /// Encodes an unmasked, unfragmented binary WebSocket frame (server ->
    /// client frames are never masked per RFC 6455).
    private static func makeWebSocketFrame(binaryPayload data: Data) -> Data {
        var frame = Data()
        frame.append(0x82) // FIN=1, opcode=2 (binary)
        let length = data.count
        if length <= 125 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }
        frame.append(data)
        return frame
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, body: Data, cors: Bool = false, cache: Bool = true) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }

        var headerLines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        if cors {
            headerLines.append("Access-Control-Allow-Origin: *")
        }
        if !cache {
            headerLines.append("Cache-Control: no-store, no-cache, must-revalidate")
        }
        headerLines.append("")
        headerLines.append("")
        let header = headerLines.joined(separator: "\r\n")

        var responseData = Data(header.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(connection)
        })
    }
}
