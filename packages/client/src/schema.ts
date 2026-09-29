import { DecodingError } from './errors.js'

/** The JSON Schema subset afm-bridge supports (PROTOCOL.md section 8). */
export interface JSONSchema {
  type?: 'object' | 'array' | 'string' | 'integer' | 'number' | 'boolean' | 'null' | Array<string>
  description?: string
  properties?: Record<string, JSONSchema>
  required?: string[]
  additionalProperties?: false
  items?: JSONSchema
  minItems?: number
  maxItems?: number
  minimum?: number
  maximum?: number
  enum?: Array<string | null>
  const?: string
  pattern?: string
  anyOf?: JSONSchema[]
  oneOf?: JSONSchema[]
  $ref?: string
  $defs?: Record<string, JSONSchema>
  definitions?: Record<string, JSONSchema>
  [annotation: string]: unknown
}

const structured = Symbol.for('afm-bridge.schema')

/**
 * A schema plus a parser that turns the generated JSON into `T`. Create one with
 * `jsonSchema()` or `zodSchema()` from `afm-bridge/zod`.
 */
export interface StructuredSchema<T> {
  readonly [structured]: true
  readonly jsonSchema: JSONSchema
  /** Validates and converts a generated value. Throws `DecodingError` when it does not match. */
  parse(value: unknown): T
}

/** A plain JSON Schema object or a `StructuredSchema`. */
export type SchemaInput<T = unknown> = JSONSchema | StructuredSchema<T>

/**
 * Wraps a JSON Schema. Without `parse` the result is checked by the built-in validator
 * for the supported subset and typed as `T`.
 */
export function jsonSchema<T = unknown>(
  schema: JSONSchema,
  parse?: (value: unknown) => T,
): StructuredSchema<T> {
  return {
    [structured]: true,
    jsonSchema: schema,
    parse:
      parse ??
      ((value: unknown) => {
        const issue = validate(schema, value)
        if (issue) {
          throw new DecodingError(
            `Generated value does not match the schema at '${issue.path}': ${issue.message}`,
            {
              type: 'decodingFailure',
              data: { path: issue.path, rawContent: JSON.stringify(value) },
            },
          )
        }
        return value as T
      }),
  }
}

export function isStructuredSchema(value: unknown): value is StructuredSchema<unknown> {
  return typeof value === 'object' && value !== null && structured in value
}

export function toStructuredSchema<T>(input: SchemaInput<T>): StructuredSchema<T> {
  return isStructuredSchema(input) ? (input as StructuredSchema<T>) : jsonSchema<T>(input as JSONSchema)
}

/** Recursively optional, for partial values while a structured response streams in. */
export type DeepPartial<T> =
  T extends Array<infer U>
    ? Array<DeepPartial<U>>
    : T extends object
      ? { [K in keyof T]?: DeepPartial<T[K]> }
      : T

// MARK: - Validation of the supported subset

interface Issue {
  path: string
  message: string
}

/** Returns the first mismatch between `value` and `schema`, or undefined. `format` is not checked. */
export function validate(schema: JSONSchema, value: unknown): Issue | undefined {
  return check(schema, value, '#', schema, 0)
}

function check(
  schema: JSONSchema,
  value: unknown,
  path: string,
  root: JSONSchema,
  depth: number,
): Issue | undefined {
  if (depth > 64) return undefined
  const fail = (message: string): Issue => ({ path, message })

  if (schema.$ref !== undefined) {
    const target = resolveRef(schema.$ref, root)
    if (!target) return fail(`cannot resolve ${schema.$ref}`)
    return check(target, value, path, root, depth + 1)
  }
  const branches = schema.anyOf ?? schema.oneOf
  if (branches) {
    const ok = branches.some((b) => !check(b, value, path, root, depth + 1))
    return ok ? undefined : fail('does not match any of the allowed schemas')
  }
  if (schema.enum) {
    return schema.enum.includes(value as string | null)
      ? undefined
      : fail(`must be one of ${JSON.stringify(schema.enum)}`)
  }
  if (schema.const !== undefined) {
    return value === schema.const ? undefined : fail(`must be ${JSON.stringify(schema.const)}`)
  }

  const types = schema.type === undefined ? [] : Array.isArray(schema.type) ? schema.type : [schema.type]
  if (value === null) {
    return types.includes('null') ? undefined : fail('must not be null')
  }
  const type = types.find((t) => t !== 'null')
  switch (type) {
    case 'string': {
      if (typeof value !== 'string') return fail('must be a string')
      // A pattern that is valid for Swift but not for JavaScript is skipped, not failed.
      const pattern = schema.pattern === undefined ? undefined : safeRegExp(schema.pattern)
      if (pattern && !pattern.test(value)) return fail(`must match /${schema.pattern}/`)
      return undefined
    }
    case 'integer':
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) return fail(`must be a ${type}`)
      if (type === 'integer' && !Number.isInteger(value)) return fail('must be an integer')
      if (schema.minimum !== undefined && value < schema.minimum) return fail(`must be >= ${schema.minimum}`)
      if (schema.maximum !== undefined && value > schema.maximum) return fail(`must be <= ${schema.maximum}`)
      return undefined
    case 'boolean':
      return typeof value === 'boolean' ? undefined : fail('must be a boolean')
    case 'array': {
      if (!Array.isArray(value)) return fail('must be an array')
      if (schema.minItems !== undefined && value.length < schema.minItems) {
        return fail(`must have at least ${schema.minItems} items`)
      }
      if (schema.maxItems !== undefined && value.length > schema.maxItems) {
        return fail(`must have at most ${schema.maxItems} items`)
      }
      if (!schema.items) return undefined
      for (const [i, item] of value.entries()) {
        const issue = check(schema.items, item, `${path}/${i}`, root, depth + 1)
        if (issue) return issue
      }
      return undefined
    }
    case 'object': {
      if (typeof value !== 'object' || Array.isArray(value)) return fail('must be an object')
      const record = value as Record<string, unknown>
      const properties = schema.properties ?? {}
      for (const key of schema.required ?? []) {
        if (!(key in record)) return fail(`is missing required property '${key}'`)
      }
      for (const [key, v] of Object.entries(record)) {
        const sub = properties[key]
        if (!sub) {
          if (schema.additionalProperties === false) return fail(`has unexpected property '${key}'`)
          continue
        }
        const issue = check(sub, v, `${path}/${escapePointer(key)}`, root, depth + 1)
        if (issue) return issue
      }
      return undefined
    }
    default:
      return undefined
  }
}

function resolveRef(ref: string, root: JSONSchema): JSONSchema | undefined {
  if (ref === '#') return root
  const match = /^#\/(\$defs|definitions)\/(.+)$/.exec(ref)
  if (!match?.[1] || !match[2]) return undefined
  const defs = (match[1] === '$defs' ? root.$defs : root.definitions) ?? {}
  return defs[match[2].replace(/~1/g, '/').replace(/~0/g, '~')]
}

function escapePointer(key: string): string {
  return key.replace(/~/g, '~0').replace(/\//g, '~1')
}

function safeRegExp(pattern: string): RegExp | undefined {
  try {
    return new RegExp(pattern, 'u')
  } catch {
    return undefined
  }
}
