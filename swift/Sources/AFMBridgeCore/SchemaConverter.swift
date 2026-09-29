import Foundation
import FoundationModels

/// Structure of a converted schema, kept to post-process generated values.
public indirect enum SchemaShape: Sendable, Equatable {
  case leaf
  /// Properties in schema order.
  case object(properties: [SchemaProperty], nullableRequired: [String])
  case array(SchemaShape)
  case anyOf([SchemaShape])
  case ref(String)
}

public struct SchemaProperty: Sendable, Equatable {
  public var name: String
  public var shape: SchemaShape
}

/// A JSON Schema converted for FoundationModels, plus what is needed to turn the
/// generated value back into JSON that validates against the original schema.
public struct ConvertedSchema: Sendable {
  public let schema: GenerationSchema
  public let shape: SchemaShape
  public let definitions: [String: SchemaShape]

  /// FoundationModels omits optional properties it decides not to generate. JSON Schema
  /// `required` + nullable (Zod's `.nullable()`) expects the key with `null`; add it.
  public func normalize(_ value: JSON) -> JSON {
    normalize(value, shape, depth: 0)
  }

  private func normalize(_ value: JSON, _ shape: SchemaShape, depth: Int) -> JSON {
    guard depth < 64 else { return value }
    switch shape {
    case .leaf:
      return value
    case .ref(let name):
      guard let target = definitions[name] else { return value }
      return normalize(value, target, depth: depth + 1)
    case .array(let item):
      guard case .array(let items) = value else { return value }
      return .array(items.map { normalize($0, item, depth: depth + 1) })
    case .object(let properties, let nullableRequired):
      // Rebuild in schema order (FoundationModels does not keep it), adding
      // missing nullable-required keys as null and keeping unknown keys at the end.
      guard case .object(let o) = value else { return value }
      var result = JSONObject()
      for property in properties {
        if let v = o[property.name] {
          result[property.name] = normalize(v, property.shape, depth: depth + 1)
        } else if nullableRequired.contains(property.name) {
          result[property.name] = .null
        }
      }
      for (key, v) in o where result[key] == nil { result[key] = v }
      return .object(result)
    case .anyOf(let branches):
      guard case .object(let o) = value else { return value }
      for branch in branches {
        if case .object(let properties, _) = resolve(branch), Set(o.keys).isSubset(of: properties.map(\.name)) {
          return normalize(value, branch, depth: depth + 1)
        }
      }
      return value
    }
  }

  private func resolve(_ shape: SchemaShape) -> SchemaShape {
    if case .ref(let name) = shape, let target = definitions[name] { return target }
    return shape
  }
}

/// Converts the JSON Schema subset documented in PROTOCOL.md section 8 into a
/// `GenerationSchema`. Anything outside the subset throws `unsupportedSchema` with a
/// JSON pointer, nothing is silently ignored except annotation keywords.
public enum JSONSchemaConverter {
  static let annotations: Set<String> = [
    "$schema", "$id", "$comment", "title", "description", "examples", "default", "format", "deprecated",
    "readOnly", "writeOnly",
  ]

  /// - Parameters:
  ///   - rootName: name of the root object schema (shown to the model).
  ///   - requireObject: tool parameters must be an object.
  public static func convert(_ json: JSON, rootName: String = "Response", requireObject: Bool = false) throws
    -> ConvertedSchema
  {
    let context = Context(root: json, rootName: sanitize(rootName))
    if requireObject, json["type"] != "object" {
      throw unsupported("", "The root of tool parameters must be {\"type\": \"object\"}")
    }
    let node = try context.node(json, path: "", hint: context.rootName, isRoot: true)
    if node.nullable { throw unsupported("", "The root schema cannot be nullable") }
    context.definitionShapes[context.rootName] = node.shape
    do {
      let schema = try GenerationSchema(root: node.schema, dependencies: context.dependencies)
      return ConvertedSchema(schema: schema, shape: node.shape, definitions: context.definitionShapes)
    } catch let error as GenerationSchema.SchemaError {
      throw unsupported("", ErrorMapper.describe(error))
    }
  }

  static func unsupported(_ path: String, _ reason: String) -> RPCError {
    RPCError(
      code: -32035, type: "unsupportedSchema",
      message: "Unsupported JSON Schema at '\(path.isEmpty ? "#" : path)': \(reason)",
      data: ["path": .string(path.isEmpty ? "#" : path), "reason": .string(reason)])
  }

  static func sanitize(_ name: String) -> String {
    let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    return cleaned.isEmpty ? "Schema" : cleaned
  }
}

private struct Node {
  var schema: DynamicGenerationSchema
  var shape: SchemaShape
  var nullable = false
  /// Objects and anyOf are named schemas that can be referenced.
  var isNamed = false
}

private final class Context {
  let root: JSON
  let rootName: String
  let definitions: JSONObject
  let definitionsKey: String
  var dependencies: [DynamicGenerationSchema] = []
  var definitionShapes: [String: SchemaShape] = [:]
  var converting: Set<String> = []
  var usedNames: Set<String>

  init(root: JSON, rootName: String) {
    self.root = root
    self.rootName = rootName
    if let d = root["$defs"]?.objectValue {
      definitions = d
      definitionsKey = "$defs"
    } else {
      definitions = root["definitions"]?.objectValue ?? JSONObject()
      definitionsKey = "definitions"
    }
    usedNames = Set([rootName] + definitions.keys.map(JSONSchemaConverter.sanitize))
  }

  func uniqueName(_ hint: String) -> String {
    let base = JSONSchemaConverter.sanitize(hint)
    var name = base
    var n = 2
    while usedNames.contains(name) {
      name = "\(base)\(n)"
      n += 1
    }
    usedNames.insert(name)
    return name
  }

  func fail(_ path: String, _ reason: String) -> RPCError { JSONSchemaConverter.unsupported(path, reason) }

  func check(_ o: JSONObject, _ allowed: Set<String>, _ path: String) throws {
    for key in o.keys where !allowed.contains(key) && !JSONSchemaConverter.annotations.contains(key) {
      if key == "minLength" || key == "maxLength" {
        throw fail(
          "\(path)/\(key)", "'\(key)' is not supported by FoundationModels (use maximumResponseTokens or a pattern)")
      }
      throw fail("\(path)/\(key)", "Keyword '\(key)' is not supported")
    }
  }

  func node(_ json: JSON, path: String, hint: String, isRoot: Bool = false, name: String? = nil) throws -> Node {
    guard case .object(let o) = json else { throw fail(path, "A schema must be a JSON object") }
    let rootKeys: Set<String> = isRoot ? ["$defs", "definitions"] : []

    if let ref = o["$ref"] {
      try check(o, ["$ref"], path)
      guard let ref = ref.stringValue else { throw fail("\(path)/$ref", "'$ref' must be a string") }
      return try reference(ref, path: "\(path)/$ref")
    }

    if o["anyOf"] != nil || o["oneOf"] != nil {
      try check(o, rootKeys.union(["anyOf", "oneOf"]), path)
      let key = o["anyOf"] != nil ? "anyOf" : "oneOf"
      guard case .array(let branches) = o[key]!, !branches.isEmpty else {
        throw fail("\(path)/\(key)", "'\(key)' must be a non-empty array")
      }
      var nullable = false
      var nodes: [Node] = []
      for (i, branch) in branches.enumerated() {
        if branch["type"] == "null" {
          nullable = true
          continue
        }
        nodes.append(try node(branch, path: "\(path)/\(key)/\(i)", hint: "\(hint)_\(i + 1)"))
      }
      if nodes.contains(where: \.nullable) { nullable = true }
      guard !nodes.isEmpty else { throw fail(path, "'\(key)' needs at least one non-null branch") }
      if nodes.count == 1 {
        var only = nodes[0]
        only.nullable = nullable
        return only
      }
      let named = name ?? (isRoot ? rootName : uniqueName(hint))
      return Node(
        schema: DynamicGenerationSchema(
          name: named, description: o["description"]?.stringValue, anyOf: nodes.map(\.schema)),
        shape: .anyOf(nodes.map(\.shape)), nullable: nullable, isNamed: true)
    }

    var nullable = false
    var type: String?
    switch o["type"] {
    case .none: type = nil
    case .string(let t): type = t
    case .array(let types):
      let names = types.compactMap(\.stringValue)
      guard names.count == types.count else { throw fail("\(path)/type", "'type' entries must be strings") }
      nullable = names.contains("null")
      let rest = names.filter { $0 != "null" }
      guard rest.count == 1 else {
        throw fail("\(path)/type", "Only [T, \"null\"] type unions are supported; use anyOf for other unions")
      }
      type = rest[0]
    default: throw fail("\(path)/type", "'type' must be a string or an array")
    }

    if let values = o["enum"] {
      try check(o, rootKeys.union(["enum", "type"]), path)
      guard case .array(let list) = values, !list.isEmpty else {
        throw fail("\(path)/enum", "'enum' must be a non-empty array")
      }
      if list.contains(.null) { nullable = true }
      let strings = list.filter { $0 != .null }.compactMap(\.stringValue)
      guard strings.count == list.filter({ $0 != .null }).count, type == nil || type == "string" else {
        throw fail("\(path)/enum", "Only string enums are supported")
      }
      return Node(
        schema: DynamicGenerationSchema(type: String.self, guides: [.anyOf(strings)]), shape: .leaf, nullable: nullable)
    }
    if let value = o["const"] {
      try check(o, rootKeys.union(["const", "type"]), path)
      guard let s = value.stringValue, type == nil || type == "string" else {
        throw fail("\(path)/const", "Only string constants are supported")
      }
      return Node(
        schema: DynamicGenerationSchema(type: String.self, guides: [.constant(s)]), shape: .leaf, nullable: nullable)
    }

    switch type {
    case "string":
      try check(o, rootKeys.union(["type", "pattern"]), path)
      var guides: [GenerationGuide<String>] = []
      if let pattern = o["pattern"] {
        guard let p = pattern.stringValue else { throw fail("\(path)/pattern", "'pattern' must be a string") }
        do {
          guides.append(.pattern(try Regex(p)))
        } catch {
          throw fail("\(path)/pattern", "Not a valid Swift regular expression: \(error)")
        }
      }
      return Node(schema: DynamicGenerationSchema(type: String.self, guides: guides), shape: .leaf, nullable: nullable)

    case "integer":
      try check(o, rootKeys.union(["type", "minimum", "maximum"]), path)
      let min = try integer(o["minimum"], "\(path)/minimum")
      let max = try integer(o["maximum"], "\(path)/maximum")
      var guides: [GenerationGuide<Int>] = []
      if let min, let max {
        guard min <= max else { throw fail(path, "'minimum' is greater than 'maximum'") }
        guides.append(.range(min...max))
      } else if let min {
        guides.append(.minimum(min))
      } else if let max {
        guides.append(.maximum(max))
      }
      return Node(schema: DynamicGenerationSchema(type: Int.self, guides: guides), shape: .leaf, nullable: nullable)

    case "number":
      try check(o, rootKeys.union(["type", "minimum", "maximum"]), path)
      let min = try number(o["minimum"], "\(path)/minimum")
      let max = try number(o["maximum"], "\(path)/maximum")
      var guides: [GenerationGuide<Double>] = []
      if let min, let max {
        guard min <= max else { throw fail(path, "'minimum' is greater than 'maximum'") }
        guides.append(.range(min...max))
      } else if let min {
        guides.append(.minimum(min))
      } else if let max {
        guides.append(.maximum(max))
      }
      return Node(schema: DynamicGenerationSchema(type: Double.self, guides: guides), shape: .leaf, nullable: nullable)

    case "boolean":
      try check(o, rootKeys.union(["type"]), path)
      return Node(schema: DynamicGenerationSchema(type: Bool.self), shape: .leaf, nullable: nullable)

    case "array":
      try check(o, rootKeys.union(["type", "items", "minItems", "maxItems"]), path)
      guard let items = o["items"] else { throw fail(path, "Arrays need an 'items' schema") }
      let item = try node(items, path: "\(path)/items", hint: "\(hint)_item")
      if item.nullable { throw fail("\(path)/items", "Nullable array items are not supported") }
      let minItems = try integer(o["minItems"], "\(path)/minItems")
      let maxItems = try integer(o["maxItems"], "\(path)/maxItems")
      return Node(
        schema: DynamicGenerationSchema(arrayOf: item.schema, minimumElements: minItems, maximumElements: maxItems),
        shape: .array(item.shape), nullable: nullable)

    case "object":
      try check(o, rootKeys.union(["type", "properties", "required", "additionalProperties"]), path)
      if let additional = o["additionalProperties"], additional != .bool(false) {
        throw fail(
          "\(path)/additionalProperties",
          "Only 'additionalProperties: false' is supported (the model never generates extra keys)")
      }
      let properties = o["properties"]?.objectValue ?? JSONObject()
      if let p = o["properties"], p.objectValue == nil {
        throw fail("\(path)/properties", "'properties' must be an object")
      }
      var required: [String] = []
      if let r = o["required"] {
        guard case .array(let list) = r, list.allSatisfy({ $0.stringValue != nil }) else {
          throw fail("\(path)/required", "'required' must be an array of strings")
        }
        required = list.compactMap(\.stringValue)
      }
      for key in required where properties[key] == nil {
        throw fail("\(path)/required", "Required property '\(key)' is not defined in 'properties'")
      }
      let named = name ?? (isRoot ? rootName : uniqueName(hint))
      var dynamicProperties: [DynamicGenerationSchema.Property] = []
      var shapes: [SchemaProperty] = []
      var nullableRequired: [String] = []
      for (key, sub) in properties {
        let child = try node(sub, path: "\(path)/properties/\(escape(key))", hint: "\(named)_\(key)")
        let isRequired = required.contains(key)
        if isRequired && child.nullable { nullableRequired.append(key) }
        dynamicProperties.append(
          .init(
            name: key, description: sub["description"]?.stringValue, schema: child.schema,
            isOptional: !isRequired || child.nullable))
        shapes.append(SchemaProperty(name: key, shape: child.shape))
      }
      return Node(
        schema: DynamicGenerationSchema(
          name: named, description: o["description"]?.stringValue, properties: dynamicProperties),
        shape: .object(properties: shapes, nullableRequired: nullableRequired), nullable: nullable, isNamed: true)

    case "null":
      throw fail(path, "'null' is only supported as part of a nullable property ([T, \"null\"] or anyOf)")
    case .none:
      throw fail(path, "Schema needs a 'type' (or enum, const, anyOf, $ref)")
    case .some(let other):
      throw fail("\(path)/type", "Unknown type '\(other)'")
    }
  }

  private func reference(_ ref: String, path: String) throws -> Node {
    if ref == "#" {
      return Node(schema: DynamicGenerationSchema(referenceTo: rootName), shape: .ref(rootName), isNamed: true)
    }
    let prefix = "#/\(definitionsKey)/"
    guard ref.hasPrefix(prefix) else {
      throw fail(path, "Only '#' and '#/$defs/Name' references are supported")
    }
    let key = String(ref.dropFirst(prefix.count))
    guard let definition = definitions[key] else { throw fail(path, "Definition '\(key)' not found") }
    let name = JSONSchemaConverter.sanitize(key)
    if definitionShapes[name] != nil || converting.contains(name) {
      return Node(schema: DynamicGenerationSchema(referenceTo: name), shape: .ref(name), isNamed: true)
    }
    converting.insert(name)
    defer { converting.remove(name) }
    let node = try self.node(definition, path: "#/\(definitionsKey)/\(escape(key))", hint: name, name: name)
    guard node.isNamed else {
      // Primitive definitions have no name to reference; inline them.
      return node
    }
    dependencies.append(node.schema)
    definitionShapes[name] = node.shape
    return Node(
      schema: DynamicGenerationSchema(referenceTo: name), shape: .ref(name), nullable: node.nullable, isNamed: true)
  }

  private func integer(_ value: JSON?, _ path: String) throws -> Int? {
    switch value {
    case .none: return nil
    case .int(let i): return i
    case .double(let d) where d == d.rounded() && abs(d) < 9.2e18: return Int(d)
    default: throw fail(path, "Must be an integer")
    }
  }

  private func number(_ value: JSON?, _ path: String) throws -> Double? {
    switch value {
    case .none: return nil
    case .int(let i): return Double(i)
    case .double(let d): return d
    default: throw fail(path, "Must be a number")
    }
  }

  private func escape(_ key: String) -> String {
    key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }
}

extension JSON {
  /// Converts generated content to JSON, keeping the property order of the model.
  public init(_ content: GeneratedContent) {
    switch content.kind {
    case .null: self = .null
    case .bool(let b): self = .bool(b)
    case .number(let d):
      self = d == d.rounded() && abs(d) < 9_007_199_254_740_992 ? .int(Int(d)) : .double(d)
    case .string(let s): self = .string(s)
    case .array(let items): self = .array(items.map(JSON.init))
    case .structure(let properties, let orderedKeys):
      var o = JSONObject()
      for key in orderedKeys {
        if let value = properties[key] { o[key] = JSON(value) }
      }
      self = .object(o)
    @unknown default:
      self = .null
    }
  }
}
