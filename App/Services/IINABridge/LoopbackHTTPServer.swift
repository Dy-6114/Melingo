import Foundation
import Network

/// One parsed request from the IINA plugin. Parameters are merged from the URL
/// query and the body (JSON object or form-encoded), so the plugin may send either.
struct BridgeHTTPRequest: Sendable {
    let method: String
    let path: String
    let parameters: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
}

struct BridgeHTTPResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> BridgeHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return BridgeHTTPResponse(status: status, body: data)
    }

    fileprivate func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only — never reachable from the network.
/// One request per connection; enough for the IINA plugin's short GET calls.
///
/// `@unchecked Sendable`: all mutable state is touched only on `queue`.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (BridgeHTTPRequest) async -> BridgeHTTPResponse

    private static let maxRequestBytes = 64 * 1024

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "melingo.iina-bridge")
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("Melingo IINA bridge stopped: %@", String(describing: error))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    /// Lets `NWConnection` cross into `@Sendable` callbacks; it is only used on `queue`
    /// or through its own thread-safe `send` / `cancel`.
    private final class ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        let box = ConnectionBox(connection)
        connection.start(queue: queue)
        receive(on: box, buffer: Data())
    }

    private func receive(on box: ConnectionBox, buffer: Data) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                box.connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if buffer.count > Self.maxRequestBytes {
                self.send(.json(["error": "too-large"], status: 413), on: box)
                return
            }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.dispatch(request, on: box)
            case .malformed:
                self.send(.json(["error": "bad-request"], status: 400), on: box)
            case .incomplete:
                if isComplete || error != nil {
                    box.connection.cancel()
                } else {
                    self.receive(on: box, buffer: buffer)
                }
            }
        }
    }

    private func dispatch(_ request: BridgeHTTPRequest, on box: ConnectionBox) {
        let handler = self.handler
        Task { [weak self] in
            let response = await handler(request)
            self?.send(response, on: box)
        }
    }

    private func send(_ response: BridgeHTTPResponse, on box: ConnectionBox) {
        box.connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            box.connection.cancel()
        })
    }

    // MARK: - Parsing

    private enum ParseResult {
        case incomplete
        case malformed
        case complete(BridgeHTTPRequest)
    }

    private static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return .malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .malformed }
        let method = requestLine[0].uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0, contentLength <= maxRequestBytes else { return .malformed }
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= contentLength else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))

        var path = target
        var parameters: [String: String] = [:]
        if let question = target.firstIndex(of: "?") {
            path = String(target[..<question])
            parameters = formParameters(String(target[target.index(after: question)...]))
        }
        if !body.isEmpty {
            if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                for (key, value) in object {
                    if let string = value as? String {
                        parameters[key] = string
                    } else if let number = value as? NSNumber {
                        parameters[key] = number.stringValue
                    }
                }
            } else if let form = String(data: body, encoding: .utf8) {
                parameters.merge(formParameters(form)) { _, new in new }
            }
        }

        return .complete(BridgeHTTPRequest(
            method: method,
            path: path.removingPercentEncoding ?? path,
            parameters: parameters,
            headers: headers
        ))
    }

    /// Decodes `a=1&b=two%20words`; accepts `+` as a space like HTML forms do.
    private static func formParameters(_ encoded: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let name = decode(String(rawName))
            guard !name.isEmpty else { continue }
            result[name] = decode(rawValue)
        }
        return result
    }

    private static func decode(_ component: String) -> String {
        let spaced = component.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
