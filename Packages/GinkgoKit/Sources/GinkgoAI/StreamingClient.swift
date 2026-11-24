import Foundation

/// One server-sent event.
struct SSEEvent: Equatable {
    var event: String?
    var data: String
}

/// Turns SSE lines into events: `event:` and `data:` fields, a blank line ends an event.
struct SSEParser {
    private var event: String?
    private var data: [String] = []

    /// Feed one line (without its newline). Returns an event when the line completes one.
    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let (field, value) = split(line)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    mutating func flush() -> SSEEvent? {
        defer { event = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event, data: data.joined(separator: "\n"))
    }

    private func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

/// What each provider supplies; the transport and SSE handling are shared.
protocol StreamingClient: AIClient {
    var session: URLSession { get }
    func makeURLRequest(_ request: AIRequest) throws -> URLRequest
    /// Text carried by one event, or nil. Throws for in-stream errors and refusals.
    func text(from event: SSEEvent) throws -> String?
}

extension StreamingClient {
    public func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 2000 { break } }
                        throw AIError.http(status: status, message: Self.errorMessage(in: body))
                    }
                    var parser = SSEParser()
                    var produced = false
                    // `lines` drops blank lines, so every data line is dispatched as its own event; all three
                    // providers send one JSON object per data line.
                    for try await line in bytes.lines {
                        _ = parser.feed(line)
                        if line.hasPrefix("data:"), let event = parser.flush() {
                            if event.data == "[DONE]" { break }
                            if let text = try self.text(from: event), !text.isEmpty {
                                produced = true
                                continuation.yield(text)
                            }
                        }
                        if line.hasPrefix("event:") { continue }
                    }
                    if !produced { throw AIError.empty }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pulls a readable message out of a provider's JSON error body.
    static func errorMessage(in body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(body.prefix(200))
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = json["message"] as? String { return message }
        return String(body.prefix(200))
    }
}

func jsonObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func postRequest(_ url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return request
}
