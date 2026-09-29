import Testing

@testable import AFMBridgeCore

@Suite struct MessageParserTests {
  @Test func parsesRequest() throws {
    let m = try MessageParser.parse(#"{"jsonrpc":"2.0","id":7,"method":"session/info","params":{"sessionId":"a"}}"#)
      .get()
    #expect(m == .request(id: .int(7), method: "session/info", params: ["sessionId": "a"]))
  }

  @Test func missingParamsBecomeEmptyObject() throws {
    let m = try MessageParser.parse(#"{"jsonrpc":"2.0","id":"s:1","method":"shutdown"}"#).get()
    #expect(m == .request(id: .string("s:1"), method: "shutdown", params: .object([:])))
  }

  @Test func parsesNotification() throws {
    let m = try MessageParser.parse(#"{"jsonrpc":"2.0","method":"cancel","params":{"id":3}}"#).get()
    #expect(m == .notification(method: "cancel", params: ["id": 3]))
  }

  @Test func parsesResultAndErrorResponses() throws {
    let ok = try MessageParser.parse(#"{"jsonrpc":"2.0","id":"s:2","result":{"output":"x"}}"#).get()
    #expect(ok == .response(id: .string("s:2"), result: .success(["output": "x"])))
    let err = try MessageParser.parse(
      #"{"jsonrpc":"2.0","id":"s:3","error":{"code":-32000,"message":"boom","data":{"type":"custom","k":1}}}"#
    ).get()
    #expect(
      err
        == .response(
          id: .string("s:3"), result: .failure(RPCError(code: -32000, type: "custom", message: "boom", data: ["k": 1])))
    )
  }

  @Test func rejectsInvalidJSON() {
    guard case .failure(let f) = MessageParser.parse("{not json") else {
      Issue.record("expected failure")
      return
    }
    #expect(f.id == nil)
    #expect(f.error.code == -32700)
  }

  @Test func rejectsWrongVersionButKeepsId() {
    guard case .failure(let f) = MessageParser.parse(#"{"jsonrpc":"1.0","id":4,"method":"x"}"#) else {
      Issue.record("expected failure")
      return
    }
    #expect(f.id == .int(4))
    #expect(f.error.type == "invalidRequest")
  }

  @Test func rejectsNonObjectAndBadId() {
    guard case .failure(let a) = MessageParser.parse("[1,2]"),
      case .failure(let b) = MessageParser.parse(
        #"{"jsonrpc":"2.0","id":true,"method":"x"}"#)
    else {
      Issue.record("expected failures")
      return
    }
    #expect(a.error.type == "invalidRequest")
    #expect(b.error.type == "invalidRequest")
  }

  @Test func encodesSingleLineWithIntegerIds() {
    let line = MessageEncoder.line(MessageEncoder.response(id: .int(1), result: ["text": "a\nb", "n": 3]))
    #expect(!line.contains("\n"))
    #expect(line.contains(#""id":1"#))
    #expect(line.contains(#""n":3"#))
    #expect(line.contains(#""text":"a\nb""#))
  }

  @Test func errorCarriesTypeInData() {
    let json = RPCError.sessionBusy("abc").json
    #expect(json["code"] == .int(-32021))
    #expect(json["data"]?["type"] == "sessionBusy")
    #expect(json["data"]?["sessionId"] == "abc")
  }
}
