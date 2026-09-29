import { describe, expect, it } from 'vitest'
import { z } from 'zod'
import {
  AppleFoundationModels,
  DecodingError,
  jsonSchema,
  type StructuredStreamChunk,
  ToolExecutionError,
  tool,
  validate,
} from '../src/index.js'
import { zodSchema } from '../src/zod/index.js'
import { type MockBehavior, MockTransport, sleep, until } from './mock-sidecar.js'

function setup(behavior: MockBehavior = {}) {
  const transport = new MockTransport(behavior)
  return { transport, afm: new AppleFoundationModels({ transport }) }
}

const personSchema = {
  type: 'object',
  properties: { name: { type: 'string' }, age: { type: 'integer', minimum: 0 } },
  required: ['name', 'age'],
  additionalProperties: false,
} as const

describe('validate', () => {
  it('accepts values that match the subset and reports the first mismatch with a pointer', () => {
    const schema = {
      type: 'object',
      properties: {
        tags: { type: 'array', items: { type: 'string' }, maxItems: 2 },
        role: { enum: ['admin', 'user'] },
        nick: { type: ['string', 'null'] },
        pet: { anyOf: [{ $ref: '#/$defs/Dog' }, { type: 'string' }] },
        code: { type: 'string', pattern: '^\\d{3}$' },
      },
      required: ['tags', 'nick'],
      additionalProperties: false,
      $defs: { Dog: { type: 'object', properties: { bark: { type: 'boolean' } }, required: ['bark'] } },
    } as const
    expect(
      validate(schema, { tags: ['a'], nick: null, role: 'user', pet: { bark: true }, code: '123' }),
    ).toBeUndefined()
    expect(validate(schema, { tags: ['a', 'b', 'c'], nick: null })).toMatchObject({ path: '#/tags' })
    expect(validate(schema, { tags: [1], nick: null })).toMatchObject({ path: '#/tags/0' })
    expect(validate(schema, { tags: [] })).toMatchObject({ message: "is missing required property 'nick'" })
    expect(validate(schema, { tags: [], nick: null, extra: 1 })).toMatchObject({
      message: "has unexpected property 'extra'",
    })
    expect(validate(schema, { tags: [], nick: null, role: 'root' })).toMatchObject({ path: '#/role' })
    expect(validate(schema, { tags: [], nick: null, pet: { bark: 'yes' } })).toMatchObject({ path: '#/pet' })
    expect(validate(schema, { tags: [], nick: null, code: '12a' })).toMatchObject({ path: '#/code' })
  })

  it('handles recursion through #', () => {
    const tree = {
      type: 'object',
      properties: { value: { type: 'string' }, children: { type: 'array', items: { $ref: '#' } } },
      required: ['value', 'children'],
    } as const
    expect(validate(tree, { value: 'a', children: [{ value: 'b', children: [] }] })).toBeUndefined()
    expect(validate(tree, { value: 'a', children: [{ value: 1, children: [] }] })).toMatchObject({
      path: '#/children/0/value',
    })
  })
})

describe('structured output', () => {
  it('sends the schema and returns the validated value', async () => {
    const { transport, afm } = setup({
      respond: async () => ({ text: '{"name":"Ada","age":36}', content: { name: 'Ada', age: 36 } }),
    })
    const session = await afm.createSession()
    const person = await session.respond<{ name: string; age: number }>('Invent', { schema: personSchema })
    expect(person).toEqual({ name: 'Ada', age: 36 })
    const params = transport.current.requests('session/respond')[0].params
    expect(params.schema).toEqual(personSchema)
    expect(params).not.toHaveProperty('includeSchemaInPrompt')
    await session.respond('Invent', { schema: personSchema, includeSchemaInPrompt: false })
    expect(transport.current.requests('session/respond')[1].params.includeSchemaInPrompt).toBe(false)
  })

  it('rejects a value that does not match with DecodingError', async () => {
    const { afm } = setup({ respond: async () => ({ text: '{}', content: { name: 'Ada', age: -1 } }) })
    const session = await afm.createSession()
    const error = await session.respond('x', { schema: personSchema }).catch((e) => e)
    expect(error).toBeInstanceOf(DecodingError)
    expect(error.data.path).toBe('#/age')
  })

  it('returns content, text and usage from generate()', async () => {
    const usage = { inputTokens: 1, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0 }
    const { afm } = setup({
      respond: async () => ({ text: '{"name":"A","age":1}', content: { name: 'A', age: 1 }, usage }),
    })
    const session = await afm.createSession()
    await expect(session.generate('x', { schema: jsonSchema(personSchema) })).resolves.toEqual({
      content: { name: 'A', age: 1 },
      text: '{"name":"A","age":1}',
      usage,
    })
  })

  it('streams partial values and ends with the parsed content', async () => {
    const { afm } = setup({
      respond: async (_p, ctx) => {
        ctx.partial({ name: 'A' })
        ctx.partial({ name: 'Ada' })
        await sleep(5)
        return { text: '{"name":"Ada","age":36}', content: { name: 'Ada', age: 36 } }
      },
    })
    const session = await afm.createSession()
    const chunks: StructuredStreamChunk<{ name: string; age: number }>[] = []
    for await (const chunk of session.stream('x', {
      schema: jsonSchema<{ name: string; age: number }>(personSchema),
    })) {
      chunks.push(chunk)
    }
    expect(chunks).toEqual([
      { done: false, partial: { name: 'A' } },
      { done: false, partial: { name: 'Ada' } },
      { done: true, content: { name: 'Ada', age: 36 }, text: '{"name":"Ada","age":36}' },
    ])
  })
})

describe('zodSchema', () => {
  const Person = z.object({
    name: z.string().describe('Full name'),
    email: z.string().email(),
    nick: z.string().nullable(),
    age: z
      .number()
      .int()
      .transform((n) => n + 1),
  })

  it('converts to JSON Schema and drops format patterns by default', () => {
    const schema = zodSchema(Person)
    const props = schema.jsonSchema.properties ?? {}
    expect(props.email).toMatchObject({ type: 'string', format: 'email' })
    expect(props.email).not.toHaveProperty('pattern')
    expect(props.name).toMatchObject({ description: 'Full name' })
    expect(zodSchema(Person, { keepFormatPatterns: true }).jsonSchema.properties?.email).toHaveProperty(
      'pattern',
    )
  })

  it('parses with Zod (transforms apply) and reports issues', () => {
    const schema = zodSchema(Person)
    expect(schema.parse({ name: 'A', email: 'a@b.cz', nick: null, age: 1 })).toEqual({
      name: 'A',
      email: 'a@b.cz',
      nick: null,
      age: 2,
    })
    const error = (() => {
      try {
        schema.parse({ name: 'A', email: 'nope', nick: null, age: 1 })
      } catch (e) {
        return e as DecodingError
      }
    })()
    expect(error).toBeInstanceOf(DecodingError)
    expect(error?.data.path).toBe('#/email')
  })
})

describe('tools', () => {
  const weather = tool({
    name: 'getWeather',
    description: 'Current weather',
    parameters: zodSchema(z.object({ city: z.string() })),
    execute: async ({ city }) => ({ city, tempC: 21 }),
  })

  it('registers tools, runs them on tool/call and returns JSON output', async () => {
    let toolResult: unknown
    const { transport, afm } = setup({
      respond: async (_p, ctx) => {
        toolResult = await ctx.callTool('getWeather', { city: 'Prague' })
        return { text: 'done' }
      },
    })
    const session = await afm.createSession({ instructions: 'x', tools: [weather] })
    await expect(session.respond('Weather?')).resolves.toBe('done')
    expect(toolResult).toEqual({ output: '{"city":"Prague","tempC":21}' })
    const created = transport.current.requests('session/create')[0].params
    expect(created.tools).toEqual([
      {
        name: 'getWeather',
        description: 'Current weather',
        parameters: expect.objectContaining({ type: 'object', required: ['city'] }),
      },
    ])
  })

  it('passes strings through and reports errors, invalid arguments and unknown tools', async () => {
    const results: unknown[] = []
    const { afm } = setup({
      respond: async (_p, ctx) => {
        for (const [name, args] of [
          ['echo', { text: 'hi' }],
          ['boom', {}],
          ['echo', { text: 5 }],
          ['missing', {}],
        ] as const) {
          results.push(await ctx.callTool(name, args).catch((e) => ({ error: e })))
        }
        return { text: 'ok' }
      },
    })
    const session = await afm.createSession({
      tools: [
        tool({
          name: 'echo',
          description: 'Echo',
          parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
          execute: (args) => (args as { text: string }).text,
        }),
        tool({
          name: 'boom',
          description: 'Fails',
          parameters: { type: 'object', properties: {} },
          execute: () => {
            throw new Error('database offline')
          },
        }),
      ],
    })
    await session.respond('x')
    expect(results[0]).toEqual({ output: 'hi' })
    expect(results[1]).toMatchObject({ error: { message: 'database offline' } })
    expect(results[2]).toMatchObject({ error: { message: expect.stringContaining('#/text') } })
    expect(results[3]).toMatchObject({ error: { message: "Unknown tool 'missing'" } })
  })

  it('times out a slow tool', async () => {
    let result: unknown
    const { afm } = setup({
      respond: async (_p, ctx) => {
        result = await ctx.callTool('slow', {}).catch((e) => ({ error: e }))
        return { text: 'ok' }
      },
    })
    const session = await afm.createSession({
      tools: [
        tool({
          name: 'slow',
          description: 'Slow',
          parameters: { type: 'object' },
          timeoutMs: 20,
          execute: () => new Promise(() => {}),
        }),
      ],
    })
    await session.respond('x')
    expect(result).toMatchObject({ error: { message: "Tool 'slow' timed out after 20 ms" } })
  })

  it('aborts the tool signal when the sidecar cancels the call', async () => {
    let toolSignal: AbortSignal | undefined
    const { transport, afm } = setup({
      respond: async (_p, ctx) => {
        await ctx.callTool('wait', {})
        return { text: 'never' }
      },
    })
    const session = await afm.createSession({
      tools: [
        tool({
          name: 'wait',
          description: 'Waits',
          parameters: { type: 'object' },
          execute: (_args, { signal }) => {
            toolSignal = signal
            return new Promise(() => {})
          },
        }),
      ],
    })
    const controller = new AbortController()
    const pending = session.respond('x', { signal: controller.signal })
    await until(() => toolSignal !== undefined)
    controller.abort()
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    await until(() => toolSignal?.aborted === true)
    expect(transport.current.received.some((m) => m.error?.message === "Tool 'wait' was cancelled")).toBe(
      true,
    )
  })

  it('maps a toolExecution error of the generation', async () => {
    const { afm } = setup({
      respond: () =>
        Promise.reject({
          code: -32040,
          message: "Tool 'boom' failed: database offline",
          data: { type: 'toolExecution', toolName: 'boom', message: 'database offline' },
        }),
    })
    const session = await afm.createSession({ tools: [weather] })
    const error = await session.respond('x').catch((e) => e)
    expect(error).toBeInstanceOf(ToolExecutionError)
    expect(error.data.toolName).toBe('boom')
  })
})
