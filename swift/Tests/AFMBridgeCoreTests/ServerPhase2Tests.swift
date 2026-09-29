import Foundation
import Testing

@testable import AFMBridgeCore

extension Harness {
  func toolCalls() async -> [JSON] { await sink.notifications("tool/call") }

  /// Waits for the n-th `tool/call` request the server sent.
  func toolCall(_ index: Int = 0) async throws -> JSON {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let calls = await toolCalls()
      if calls.count > index { return calls[index] }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw TestTimeout(what: "tool call \(index)")
  }

  func reply(_ id: JSON, result: JSON? = nil, error: JSON? = nil) async {
    var m: JSONObject = ["jsonrpc": "2.0", "id": id]
    if let result { m["result"] = result }
    if let error { m["error"] = error }
    await server.handle(line: MessageEncoder.line(.object(m)))
  }
}

let weatherTool: JSON = [
  "name": "getWeather", "description": "Current weather",
  "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
]

@Suite struct ServerPhase2Tests {
  @Test func toolCallRoundTrip() async throws {
    let engine = FakeEngine(behavior: .callTool("getWeather", ["city": "Prague"]))
    let h = Harness(engine: engine)
    try await h.initialize()
    let created = try await h.call(1, "session/create", ["tools": [weatherTool]])
    let sid = try #require(created["result"]?["sessionId"])
    let tools = await engine.recorder.tools
    #expect(tools.first?.map(\.name) == ["getWeather"])

    await h.send(2, "session/respond", ["sessionId": sid, "prompt": "Weather?"])
    let call = try await h.toolCall()
    #expect(call["params"]?["name"] == "getWeather")
    #expect(call["params"]?["arguments"] == ["city": "Prague"])
    #expect(call["params"]?["requestId"] == 2)
    #expect(call["params"]?["sessionId"] == sid)
    #expect(call["id"]?.stringValue?.hasPrefix("s:") == true)

    await h.reply(call["id"]!, result: ["output": "21 °C"])
    let r = try await h.sink.response(2)
    #expect(r["result"]?["text"] == "tool said: 21 °C")
  }

  @Test func toolErrorFailsTheGeneration() async throws {
    let h = Harness(engine: FakeEngine(behavior: .callTool("getWeather", ["city": "X"])))
    try await h.initialize()
    let sid = try #require(try await h.call(1, "session/create", ["tools": [weatherTool]])["result"]?["sessionId"])
    await h.send(2, "session/respond", ["sessionId": sid, "prompt": "Weather?"])
    let call = try await h.toolCall()
    await h.reply(call["id"]!, error: ["code": -32000, "message": "offline", "data": ["type": "handlerError"]])
    let r = try await h.sink.response(2)
    // The fake engine does not wrap in ToolCallError, so the failure surfaces as generationFailed with the message.
    #expect(r["error"]?["message"] == "offline")
  }

  @Test func cancellingTheRequestCancelsThePendingToolCall() async throws {
    let h = Harness(engine: FakeEngine(behavior: .callTool("getWeather", ["city": "X"])))
    try await h.initialize()
    let sid = try #require(try await h.call(1, "session/create", ["tools": [weatherTool]])["result"]?["sessionId"])
    await h.send(2, "session/respond", ["sessionId": sid, "prompt": "Weather?"])
    let call = try await h.toolCall()
    await h.send(nil, "cancel", ["id": 2])
    #expect(try await h.sink.response(2)["error"]?["data"]?["type"] == "cancelled")
    let deadline = ContinuousClock.now + .seconds(2)
    var cancelled = false
    while ContinuousClock.now < deadline, !cancelled {
      cancelled = await h.sink.notifications("cancel").contains { $0["params"]?["id"] == call["id"] }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(cancelled)
    // A late answer from the client is ignored.
    await h.reply(call["id"]!, result: ["output": "late"])
  }

  @Test func rejectsInvalidToolDefinitions() async throws {
    let h = Harness()
    try await h.initialize()
    let badName = try await h.call(
      1, "session/create", ["tools": [["name": "get weather", "description": "x", "parameters": ["type": "object"]]]])
    #expect(badName["error"]?["data"]?["path"] == "tools/0/name")
    let badSchema = try await h.call(
      2, "session/create",
      [
        "tools": [
          [
            "name": "t", "description": "x",
            "parameters": ["type": "object", "properties": ["a": ["type": "string", "maxLength": 2]]],
          ]
        ]
      ])
    #expect(badSchema["error"]?["data"]?["type"] == "unsupportedSchema")
    #expect(badSchema["error"]?["data"]?["path"] == "tools/0/parameters/properties/a/maxLength")
    let duplicate = try await h.call(3, "session/create", ["tools": [weatherTool, weatherTool]])
    #expect(duplicate["error"]?["data"]?["path"] == "tools/1/name")
  }

  @Test func structuredOutputStreamsPartialsAndNormalizes() async throws {
    let h = Harness(engine: FakeEngine(behavior: .partials([["name": "A"], ["name": "A"], ["name": "Ada"]])))
    try await h.initialize()
    let sid = try await h.createSession()
    let schema: JSON = [
      "type": "object", "properties": ["name": ["type": "string"], "nick": ["type": ["string", "null"]]],
      "required": ["name", "nick"],
    ]
    let r = try await h.call(
      2, "session/respond", ["sessionId": .string(sid), "prompt": "x", "schema": schema, "stream": true])
    #expect(r["result"]?["content"] == ["name": "Ada", "nick": nil])
    #expect(r["result"]?["text"] == #"{"name":"Ada","nick":null}"#)
    let partials = await h.sink.notifications("session/delta").compactMap { $0["params"]?["partial"] }
    #expect(partials == [["name": "A"], ["name": "Ada"]])
  }

  @Test func invalidSchemaIsRejectedBeforeGenerating() async throws {
    let h = Harness()
    try await h.initialize()
    let sid = try await h.createSession()
    let r = try await h.call(
      2, "session/respond",
      ["sessionId": .string(sid), "prompt": "x", "schema": ["type": "object", "additionalProperties": true]])
    #expect(r["error"]?["data"]?["type"] == "unsupportedSchema")
    // The session was not marked busy.
    #expect(try await h.call(3, "session/info", ["sessionId": .string(sid)])["result"]?["isResponding"] == false)
  }
}
