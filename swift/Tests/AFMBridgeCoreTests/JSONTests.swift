import Testing

@testable import AFMBridgeCore

@Suite struct JSONTests {
  @Test func keepsObjectKeyOrder() throws {
    let json = try JSON.parse(#"{"z":1,"a":{"y":true,"b":null},"m":[1,2]}"#)
    #expect(json.objectValue?.keys == ["z", "a", "m"])
    #expect(json["a"]?.objectValue?.keys == ["y", "b"])
    #expect(json.serialized == #"{"z":1,"a":{"y":true,"b":null},"m":[1,2]}"#)
  }

  @Test func parsesNumbers() throws {
    #expect(try JSON.parse("42") == .int(42))
    #expect(try JSON.parse("-7") == .int(-7))
    #expect(try JSON.parse("1.5") == .double(1.5))
    #expect(try JSON.parse("2e3") == .double(2000))
    #expect(try JSON.parse("99999999999999999999") == .double(1e20))
    #expect(throws: JSONParseError.self) { try JSON.parse("01x") }
    #expect(throws: JSONParseError.self) { try JSON.parse("-") }
  }

  @Test func parsesStringEscapes() throws {
    let json = try JSON.parse(#""a\"b\\c\/d\n\té😀""#)
    #expect(json == .string("a\"b\\c/d\n\té😀"))
    #expect(throws: JSONParseError.self) { try JSON.parse(#""\ud83d""#) }
    #expect(throws: JSONParseError.self) { try JSON.parse("\"a\nb\"") }
  }

  @Test func rejectsMalformedInput() {
    for text in ["", "{", "[1,]", "{\"a\" 1}", "{\"a\":1,}", "tru", "[1] x", "{1:2}"] {
      #expect(throws: JSONParseError.self, "\(text)") { try JSON.parse(text) }
    }
  }

  @Test func serializesEscapesOnOneLine() throws {
    let json: JSON = [
      "text": "line1\nline2 \"quoted\" \u{01}", "n": .double(3.0), "x": .double(0.25), "inf": .double(.infinity),
    ]
    let line = json.serialized
    #expect(!line.contains("\n"))
    #expect(line == #"{"text":"line1\nline2 \"quoted\" \u0001","n":3,"x":0.25,"inf":null}"#)
    #expect(try JSON.parse(line)["text"] == json["text"])
  }

  @Test func objectEqualityIgnoresOrderButRemovalWorks() {
    var a: JSONObject = ["x": 1, "y": 2]
    let b: JSONObject = ["y": 2, "x": 1]
    #expect(a == b)
    a["x"] = nil
    #expect(a.keys == ["y"])
    a["x"] = 3
    #expect(a.keys == ["y", "x"])
  }
}
