import Foundation
import Network

/// Minimal embedded HTTP/1.1 server (Network.framework, no third-party
/// dependency) for the 4th overlay — "Preview 3D": shows the sliced-plate
/// render Bambu Studio already produces (`Metadata/plate_1.png` inside the
/// `.3mf`, read via BambuStudioProjectReader) as a static "here's what this
/// print should look like" image, so whoever's running the stream can add
/// it as a 4th, independently-positioned OBS Browser Source and choose
/// whether to show it.
///
/// Its own listener/port — same reasoning as `LocalHTTPServer`'s doc
/// comment: fully independent from the printer/Studio/Now Playing servers,
/// so starting/stopping this one never affects the others. Serves:
///   GET /preview.png         -> the plate preview PNG, or 404 if none yet
///   GET /, /overlay.html     -> the overlay page (PrintPreviewAssets)
///   GET /overlay.css, /overlay.js -> its assets
final class PrintPreviewHTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.obsassistants.preview.http")
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Supplies the current preview PNG bytes on demand (nil = none read
    /// yet / folder not configured / newest `.3mf` has no preview member).
    var imageProvider: (() -> Data?)?

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0

    enum ServerError: LocalizedError {
        case invalidPort
        case startFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Porta inválida"
            case .startFailed(let reason): return "Falha ao iniciar servidor: \(reason)"
            }
        }
    }

    func start(port desiredPort: Int) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(desiredPort)) else {
            throw ServerError.invalidPort
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let newListener = try NWListener(using: params, on: nwPort)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed:
                self?.isRunning = false
            default:
                break
            }
        }
        newListener.start(queue: queue)
        listener = newListener
        port = UInt16(desiredPort)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        for (_, connection) in connections { connection.cancel() }
        connections.removeAll()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections[id] = nil }
            if case .failed = state { self?.connections[id] = nil }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                let requestLine = String(data: headerData, encoding: .utf8)?
                    .components(separatedBy: "\r\n").first ?? ""
                self.respond(to: requestLine, on: connection)
                return
            }

            if isComplete || error != nil || buffer.count > 16 * 1024 {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Only GET is supported".utf8), on: connection)
            return
        }
        let fullPath = String(parts[1])
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullPath

        switch path {
        case "/preview.png":
            if let data = imageProvider?(), !data.isEmpty {
                send(status: "200 OK", contentType: "image/png", body: data, on: connection, cors: true)
            } else {
                send(status: "404 Not Found", contentType: "text/plain", body: Data("No preview yet".utf8), on: connection, cors: true)
            }
        case "/", "/overlay.html", "/index.html":
            send(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(PrintPreviewAssets.html.utf8), on: connection)
        case "/overlay.css":
            send(status: "200 OK", contentType: "text/css; charset=utf-8", body: Data(PrintPreviewAssets.css.utf8), on: connection)
        case "/overlay.js":
            send(status: "200 OK", contentType: "application/javascript; charset=utf-8", body: Data(PrintPreviewAssets.js.utf8), on: connection)
        default:
            send(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8), on: connection)
        }
    }

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection, cors: Bool = false) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store\r\n"
        if cors {
            headers += "Access-Control-Allow-Origin: *\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        var responseData = Data(headers.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
