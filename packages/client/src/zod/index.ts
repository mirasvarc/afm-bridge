import { type output, toJSONSchema, type ZodType } from 'zod'
import { DecodingError } from '../errors.js'
import { type JSONSchema, jsonSchema, type StructuredSchema } from '../schema.js'

export interface ZodSchemaOptions {
  /**
   * Keep `pattern` next to `format` (Zod adds a regex for `.email()`, `.uuid()` and similar).
   * The on-device model rejects most of these patterns with `UnsupportedSchemaError`, so by
   * default they are dropped and the format is checked by Zod after generation instead.
   */
  keepFormatPatterns?: boolean
}

/**
 * Uses a Zod 4 schema for structured output or tool arguments. The model generates the
 * schema's input shape; the value is then run through `schema.parse`, so transforms and
 * refinements apply and the result has the output type.
 *
 * ```ts
 * const Person = z.object({ name: z.string(), age: z.number().int() })
 * const person = await session.respond('Invent a person', { schema: zodSchema(Person) })
 * ```
 */
export function zodSchema<S extends ZodType>(
  schema: S,
  options: ZodSchemaOptions = {},
): StructuredSchema<output<S>> {
  const converted = toJSONSchema(schema, { target: 'draft-2020-12', io: 'input', unrepresentable: 'throw' })
  const json = options.keepFormatPatterns ? converted : dropFormatPatterns(converted)
  return jsonSchema(json as JSONSchema, (value) => {
    const result = schema.safeParse(value)
    if (result.success) return result.data
    const issue = result.error.issues[0]
    const path = issue ? `#/${issue.path.join('/')}` : '#'
    throw new DecodingError(`Generated value does not match the Zod schema at '${path}': ${issue?.message}`, {
      type: 'decodingFailure',
      data: { path, issues: result.error.issues, rawContent: JSON.stringify(value) },
      cause: result.error,
    })
  })
}

function dropFormatPatterns(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(dropFormatPatterns)
  if (typeof value !== 'object' || value === null) return value
  const record = value as Record<string, unknown>
  const out: Record<string, unknown> = {}
  for (const [key, v] of Object.entries(record)) {
    if (key === 'pattern' && 'format' in record) continue
    out[key] = dropFormatPatterns(v)
  }
  return out
}
