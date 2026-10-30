import Foundation

/// Answers requests from URLSession.shared without a network: register it, set `handler`, unregister after.
final class MockServer: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Response)?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    static func start(_ handler: @escaping (URLRequest, Data) -> Response) {
        self.handler = handler
        requests = []
        URLProtocol.registerClass(MockServer.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(MockServer.self)
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { handler != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let response = Self.handler?(request, body) ?? Response(status: 500, body: Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension Data {
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:] }
}
