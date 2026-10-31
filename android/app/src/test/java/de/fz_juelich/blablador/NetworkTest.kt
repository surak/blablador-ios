package de.fz_juelich.blablador

import de.fz_juelich.blablador.data.BlabladorApi
import de.fz_juelich.blablador.data.BlabladorException
import de.fz_juelich.blablador.data.McpClient
import de.fz_juelich.blablador.data.McpException
import de.fz_juelich.blablador.data.McpServer
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** MCP client against a fake server answering as JSON or as an event stream. */
class McpTest {
    private val server = MockWebServer()
    private val headersSeen = mutableListOf<RecordedRequest>()

    private fun start(sse: Boolean) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val message = BlabladorApi.json.parseToJsonElement(request.body.readUtf8()).jsonObject
                val id = message["id"]?.jsonPrimitive?.int ?: 0
                val result: JsonObject = when (message["method"]?.jsonPrimitive?.contentOrNull) {
                    "initialize" -> buildJsonObject { put("protocolVersion", "2025-06-18") }
                    "notifications/initialized" -> return MockResponse().setResponseCode(202)
                    "tools/list" -> {
                        val cursor = message["params"]?.jsonObject?.get("cursor")
                        BlabladorApi.json.parseToJsonElement(
                            if (cursor == null) """{"tools":[{"name":"get_weather","description":"Weather for a city","inputSchema":{"type":"object","properties":{"city":{"type":"string"}}}}],"nextCursor":"page2"}"""
                            else """{"tools":[{"name":"list.issues"}]}""").jsonObject
                    }
                    "tools/call" -> {
                        headersSeen += request
                        val city = message["params"]?.jsonObject?.get("arguments")?.jsonObject?.get("city")?.jsonPrimitive?.content
                        BlabladorApi.json.parseToJsonElement("""{"content":[{"type":"text","text":"Sunny in $city"}],"isError":false}""").jsonObject
                    }
                    else -> buildJsonObject {}
                }
                val answer = buildJsonObject { put("jsonrpc", "2.0"); put("id", id); put("result", result) }.toString()
                return MockResponse().setHeader("Mcp-Session-Id", "session-1")
                    .setHeader("Content-Type", if (sse) "text/event-stream" else "application/json")
                    .setBody(if (sse) "event: message\ndata: $answer\n\n" else answer)
            }
        }
        server.start()
    }

    @After fun stop() = server.shutdown()

    private fun mcp() = McpServer(name = "Weather Service!", url = server.url("/mcp").toString(), token = "secret")

    @Test fun listAndCallOverJson() = runTest {
        start(sse = false)
        val client = McpClient(mcp())
        val tools = client.listTools()
        assertEquals(listOf("weather_service__get_weather", "weather_service__list_issues"), tools.map { it.qualifiedName })
        assertTrue(tools[0].description.startsWith("[Weather Service!]"))
        assertNotNull(tools[0].definition["function"]!!.jsonObject["parameters"]!!.jsonObject["properties"]!!.jsonObject["city"])
        val (text, isError) = client.callTool("get_weather", buildJsonObject { put("city", "Jülich") })
        assertEquals("Sunny in Jülich", text)
        assertFalse(isError)
        assertEquals("session-1", headersSeen.last().getHeader("Mcp-Session-Id"))
        assertEquals("Bearer secret", headersSeen.last().getHeader("Authorization"))
    }

    @Test fun listAndCallOverEventStream() = runTest {
        start(sse = true)
        val client = McpClient(mcp())
        assertEquals(2, client.listTools().size)
        assertEquals("Sunny in Aachen", client.callTool("get_weather", buildJsonObject { put("city", "Aachen") }).first)
    }

    @Test fun plainHttpIsRefused() = runTest {
        try {
            McpClient(McpServer(name = "x", url = "http://example.org/mcp")).listTools()
            fail("plain http must be refused")
        } catch (e: McpException) {
            assertTrue(e.message!!.contains("https"))
        }
    }
}

/** Chat streaming against a fake Blablador. */
class StreamTest {
    private val server = MockWebServer()
    private val endpoint = BlabladorApi.endpoint

    @Before fun start() { server.start(); BlabladorApi.endpoint = server.url("/v1").toString() }
    @After fun stop() { BlabladorApi.endpoint = endpoint; server.shutdown() }

    @Test fun contentReasoningAndToolCallsFromChunks() = runTest {
        val chunks = listOf(
            """{"choices":[{"delta":{"reasoning_content":"Let me think."}}]}""",
            """{"choices":[{"delta":{"content":"Hello"}}]}""",
            """{"choices":[{"delta":{"content":", world"}}]}""",
            """{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":"{\"que"}}]}}]}""",
            """{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ry\":\"JUPITER\"}"}}]}}]}""",
        )
        server.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream")
            .setBody(chunks.joinToString("") { "data: $it\n\n" } + "data: [DONE]\n\n"))

        var reasoning = ""; var content = ""
        var calls = emptyList<BlabladorApi.ToolCall>()
        BlabladorApi("test").streamChat("m", listOf(buildJsonObject { put("role", "user"); put("content", "hi") })).collect {
            when (it) {
                is BlabladorApi.StreamEvent.Reasoning -> reasoning += it.text
                is BlabladorApi.StreamEvent.Content -> content += it.text
                is BlabladorApi.StreamEvent.ToolCalls -> calls = it.calls
                is BlabladorApi.StreamEvent.Usage -> {}
            }
        }
        assertEquals("Let me think.", reasoning)
        assertEquals("Hello, world", content)
        assertEquals("call_1", calls.first().id)
        assertEquals("web_search", calls.first().name)
        assertEquals("""{"query":"JUPITER"}""", calls.first().arguments)
        val request = server.takeRequest()
        assertEquals("Bearer test", request.getHeader("Authorization"))
        assertTrue(request.path!!.endsWith("/v1/chat/completions"))
        assertTrue(request.body.readUtf8().contains("\"stream\":true"))
    }

    @Test fun httpErrorIsReported() = runTest {
        server.enqueue(MockResponse().setResponseCode(400).setBody("model does not support tools"))
        try {
            BlabladorApi("test").streamChat("m", emptyList()).collect {}
            fail("expected an error")
        } catch (e: BlabladorException) {
            assertEquals(400, e.status)
            assertTrue(e.body.contains("does not support tools"))
        }
    }
}
