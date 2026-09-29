import FoundationModels
import Testing

@testable import AFMBridgeCore

@Suite struct SchemaConverterTests {
  func convert(_ text: String, requireObject: Bool = false) throws -> ConvertedSchema {
    try JSONSchemaConverter.convert(try JSON.parse(text), requireObject: requireObject)
  }

  func failure(_ text: String, requireObject: Bool = false) -> RPCError? {
    do {
      _ = try convert(text, requireObject: requireObject)
      return nil
    } catch let e as RPCError {
      return e
    } catch {
      return nil
    }
  }

  @Test func convertsTheDocumentedSubset() throws {
    // Everything Zod 4 emits for a typical object, including $schema, format and nullable.
    let schema = try convert(
      #"""
      {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","description":"A person",
       "properties":{
        "name":{"type":"string","description":"Full name"},
        "age":{"type":"integer","minimum":0,"maximum":120},
        "score":{"type":"number","minimum":0.5},
        "active":{"type":"boolean"},
        "email":{"type":"string","format":"email","pattern":"\\d{3}"},
        "role":{"type":"string","enum":["admin","user"]},
        "kind":{"type":"string","const":"person"},
        "tags":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3},
        "nick":{"type":["string","null"]},
        "pet":{"anyOf":[{"type":"object","properties":{"dog":{"type":"string"}},"required":["dog"],"additionalProperties":false},
                        {"type":"object","properties":{"cat":{"type":"string"}},"required":["cat"],"additionalProperties":false}]}
       },
       "required":["name","age","score","active","role","kind","tags","nick","pet"],"additionalProperties":false}
      """#)
    guard case .object(let properties, let nullableRequired) = schema.shape else {
      Issue.record("expected object shape")
      return
    }
    #expect(
      properties.map(\.name) == ["name", "age", "score", "active", "email", "role", "kind", "tags", "nick", "pet"])
    #expect(nullableRequired == ["nick"])
  }

  @Test func supportsDefsAndRecursion() throws {
    let schema = try convert(
      #"""
      {"type":"object","properties":{"root":{"$ref":"#/$defs/Node"},"id":{"$ref":"#/$defs/Id"}},"required":["root"],
       "$defs":{"Node":{"type":"object","properties":{"value":{"type":"string"},
                                                     "children":{"type":"array","items":{"$ref":"#/$defs/Node"}}},
                        "required":["value","children"]},
                "Id":{"type":"string"}}}
      """#)
    #expect(schema.definitions["Node"] != nil)
    // Zod emits {"$ref":"#"} for recursion on the root.
    _ = try convert(
      ##"{"type":"object","properties":{"value":{"type":"string"},"children":{"type":"array","items":{"$ref":"#"}}},"required":["value","children"]}"##
    )
  }

  @Test func reportsUnsupportedKeywordsWithAPointer() {
    let cases: [(String, String)] = [
      (##"{"type":"object","properties":{"a":{"type":"string","maxLength":3}}}"##, "/properties/a/maxLength"),
      (
        ##"{"type":"object","properties":{"a":{"type":"number","exclusiveMinimum":1}}}"##,
        "/properties/a/exclusiveMinimum"
      ),
      (##"{"type":"object","additionalProperties":true}"##, "/additionalProperties"),
      (##"{"type":"object","properties":{"a":{"type":"array"}}}"##, "/properties/a"),
      (##"{"type":"object","properties":{"a":{"type":["string","integer"]}}}"##, "/properties/a/type"),
      (##"{"type":"object","properties":{"a":{"$ref":"#/components/X"}}}"##, "/properties/a/$ref"),
      (##"{"type":"object","properties":{"a":{"enum":[1,2]}}}"##, "/properties/a/enum"),
      (##"{"type":"object","required":["missing"]}"##, "/required"),
      (##"{"type":["object","null"]}"##, "#"),
      (##"{"properties":{}}"##, "#"),
    ]
    for (schema, path) in cases {
      let error = failure(schema)
      #expect(error?.type == "unsupportedSchema", "\(schema)")
      #expect(error?.data["path"] == .string(path), "\(schema)")
      #expect(error?.code == -32035)
    }
  }

  @Test func toolParametersMustBeAnObject() {
    #expect(failure(##"{"type":"string"}"##, requireObject: true)?.type == "unsupportedSchema")
  }

  @Test func normalizerAddsNullAndRestoresSchemaOrder() throws {
    let schema = try convert(
      #"""
      {"type":"object","properties":{"a":{"type":"string"},"b":{"type":["string","null"]},"c":{"type":"string"},
       "items":{"type":"array","items":{"type":"object","properties":{"x":{"type":"string"},"y":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["x","y"]}}},
       "required":["a","b","items"]}
      """#)
    let generated = try JSON.parse(##"{"items":[{"x":"1"}],"a":"A"}"##)
    let normalized = schema.normalize(generated)
    #expect(normalized.serialized == ##"{"a":"A","b":null,"items":[{"x":"1","y":null}]}"##)
  }

  @Test func generatedContentBecomesJSON() throws {
    let content = try GeneratedContent(json: ##"{"n":3,"f":1.5,"s":"x","b":true,"a":[1,null]}"##)
    let json = JSON(content)
    #expect(json["n"] == .int(3))
    #expect(json["f"] == .double(1.5))
    #expect(json["a"] == [1, nil])
  }
}
