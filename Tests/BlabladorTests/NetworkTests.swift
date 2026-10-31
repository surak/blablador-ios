import XCTest
@testable import BlabladorCore

/// MCP client and chat streaming against a fake server.
final class MCPTests: XCTestCase {
    override func tearDown() { MockServer.stop() }

    /// A server that answers initialize, tools/list (in two pages) and tools/call; `sse` answers as an event stream.
    private func startServer(sse: Bool) {
        MockServer.start { request, body in
            let message = body.json
            let id = message["id"] as? Int
            var result: [String: Any]?
            switch message["method"] as? String {
            case "initialize":
                result = ["protocolVersion": "2025-06-18", "capabilities": [:], "serverInfo": ["name": "test"]]
            case "notifications/initialized":
                return .init(status: 202, body: Data())
            case "tools/list":
                if (message["params"] as? [String: Any])?["cursor"] == nil {
                    result = ["tools": [["name": "get_weather", "description": "Weather for a city",
                                         "inputSchema": ["type": "object", "properties": ["city": ["type": "string"]]]]],
                              "nextCursor": "page2"]
                } else {
                    result = ["tools": [["name": "list.issues"]]]
                }
            case "tools/call":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                let arguments = (message["params"] as? [String: Any])?["arguments"] as? [String: Any]
                result = ["content": [["type": "text", "text": "Sunny in \(arguments?["city"] as? String ?? "?")"]], "isError": false]
            default:
                return .init(body: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? 0, "error": ["message": "unknown"]]))
            }
            let answer = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? 0, "result": result ?? [:]])
            var headers = ["Mcp-Session-Id": "session-1", "Content-Type": sse ? "text/event-stream" : "application/json"]
            if sse { headers["Content-Type"] = "text/event-stream" }
            let payload = sse ? Data(("event: message\ndata: " + String(decoding: answer, as: UTF8.self) + "\n\n").utf8) : answer
            return .init(headers: headers, body: payload)
        }
    }

    private let server = MCPServer(name: "Weather Service!", url: "https://mcp.example.org/mcp", token: "secret")

    func testListAndCallOverJSON() async throws {
        startServer(sse: false)
        let client = MCPClient(server: server)
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.qualifiedName), ["weather_service__get_weather", "weather_service__list_issues"])
        XCTAssertTrue(tools[0].description.hasPrefix("[Weather Service!]"))
        let parameters = (tools[0].definition["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertNotNil((parameters?["properties"] as? [String: Any])?["city"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: tools[0].definition), "definition must serialise for the API")
        let result = try await client.callTool("get_weather", arguments: ["city": "Jülich"])
        XCTAssertEqual(result.text, "Sunny in Jülich")
        XCTAssertFalse(result.isError)
    }

    func testListAndCallOverEventStream() async throws {
        startServer(sse: true)
        let client = MCPClient(server: server)
        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 2)
        let result = try await client.callTool("get_weather", arguments: ["city": "Aachen"])
        XCTAssertEqual(result.text, "Sunny in Aachen")
    }

    func testPlainHTTPIsRefused() async {
        let client = MCPClient(server: MCPServer(name: "x", url: "http://example.org/mcp"))
        do {
            _ = try await client.listTools()
            XCTFail("plain http must be refused")
        } catch {
            XCTAssertEqual((error as? MCPError)?.errorDescription, MCPError.badURL.errorDescription)
        }
    }
}

final class StreamTests: XCTestCase {
    override func tearDown() { MockServer.stop() }

    func testContentReasoningAndToolCallsFromChunks() async throws {
        let chunks = [
            #"{"choices":[{"delta":{"reasoning_content":"Let me think."}}]}"#,
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"content":", world"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":"{\"que"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"JUPITER\"}"}}]}}]}"#,
        ]
        let stream = chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        MockServer.start { _, _ in .init(headers: ["Content-Type": "text/event-stream"], body: Data(stream.utf8)) }

        var reasoning = "", content = ""
        var calls: [BlabladorAPI.ToolCall] = []
        for try await event in BlabladorAPI(apiKey: "test").streamChat(model: "m", messages: [["role": "user", "content": "hi"]]) {
            switch event {
            case let .reasoning(text): reasoning += text
            case let .content(text): content += text
            case let .toolCalls(found): calls = found
            case .usage: break
            }
        }
        XCTAssertEqual(reasoning, "Let me think.")
        XCTAssertEqual(content, "Hello, world")
        XCTAssertEqual(calls.first?.id, "call_1")
        XCTAssertEqual(calls.first?.name, "web_search")
        XCTAssertEqual(calls.first?.arguments, #"{"query":"JUPITER"}"#)
        let sent = MockServer.requests.first?.body.json
        XCTAssertEqual(sent?["stream"] as? Bool, true)
        XCTAssertEqual(MockServer.requests.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
    }

    func testHTTPErrorIsReported() async {
        MockServer.start { _, _ in .init(status: 400, body: Data("model does not support tools".utf8)) }
        do {
            for try await _ in BlabladorAPI(apiKey: "test").streamChat(model: "m", messages: []) {}
            XCTFail("expected an error")
        } catch let BlabladorAPIError.http(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("does not support tools"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

/// Runs real Python with Pyodide from the CDN; needs the network, so only with BLABLADOR_NETWORK_TESTS=1.
@MainActor
final class PythonTests: XCTestCase {
    func testPlotOutputAndErrors() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BLABLADOR_NETWORK_TESTS"] == "1", "set BLABLADOR_NETWORK_TESTS=1")
        let result = try await PythonRunner.shared.run("""
        import matplotlib.pyplot as plt
        plt.plot([1, 2, 3], [1, 4, 9])
        print(open('/data/input.txt').read().upper())
        6 * 7
        """, files: ["input.txt": Data("data file".utf8)])
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "DATA FILE")
        XCTAssertEqual(result.value, "42")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(result.images[0].starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let csv = try await PythonRunner.shared.run("import pandas as pd\nprint(pd.read_csv('/data/q.csv')['nodes'].sum())",
                                                    files: ["q.csv": Data("year,nodes\n2025,10\n2026,40\n".utf8)])
        XCTAssertEqual(csv.output.trimmingCharacters(in: .whitespacesAndNewlines), "50", csv.error ?? "")

        // Excel: written and read back with pandas, which needs openpyxl loaded on demand.
        let excel = try await PythonRunner.shared.run("""
        import pandas as pd
        pd.DataFrame({'a': [1, 2]}).to_excel('/tmp/t.xlsx', index=False)
        print(pd.read_excel('/tmp/t.xlsx')['a'].sum())
        """)
        XCTAssertEqual(excel.output.trimmingCharacters(in: .whitespacesAndNewlines), "3", excel.error ?? "")

        let failing = try await PythonRunner.shared.run("1 / 0")
        XCTAssertTrue(failing.error?.contains("ZeroDivisionError") == true)
    }
}
