import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { z } from 'zod'
import {
  AbortError,
  AppleFoundationModels,
  ContextWindowExceededError,
  ToolExecutionError,
  tool,
  UnsupportedSchemaError,
} from '../src/index.js'
import { NodeStdioTransport } from '../src/node/index.js'
import { zodSchema } from '../src/zod/index.js'

// Runs against the real on-device model. Enable with AFM_INTEGRATION=1.
// Uses AFM_BRIDGE_BINARY, or the release/debug build in swift/.build.
const enabled = process.env.AFM_INTEGRATION === '1'

function binary(): string {
  if (process.env.AFM_BRIDGE_BINARY) return process.env.AFM_BRIDGE_BINARY
  for (const config of ['release', 'debug']) {
    const p = fileURLToPath(new URL(`../../../swift/.build/${config}/afm-bridge-server`, import.meta.url))
    if (existsSync(p)) return p
  }
  throw new Error('Build the sidecar first: swift build --package-path swift')
}

describe.runIf(enabled)('integration with the real model', { timeout: 120_000 }, () => {
  // Construction is lazy, so nothing starts unless the tests run.
  const afm = new AppleFoundationModels({
    transport: new NodeStdioTransport({ binaryPath: enabled ? binary() : 'unused' }),
  })
  afterAll(() => afm.close())

  it('reports availability', async () => {
    const status = await afm.availability()
    expect(status.available).toBe(true)
    if (status.available) expect(status.contextSize).toBeGreaterThan(1000)
  })

  it('responds and remembers the conversation', async () => {
    const session = await afm.createSession({ instructions: 'Answer in at most five words.' })
    await session.respond('My name is Ada.', { temperature: 0 })
    const answer = await session.respond('What is my name?', { temperature: 0 })
    expect(answer.toLowerCase()).toContain('ada')
    const info = await session.info()
    expect(info.historyTokenCount).toBeGreaterThan(0)
    await session.dispose()
  })

  it('streams deltas that add up to the final text', async () => {
    const session = await afm.createSession()
    let assembled = ''
    let final = ''
    for await (const chunk of session.stream('Write one sentence about the sea.')) {
      if (chunk.done) final = chunk.text
      else assembled = chunk.reset ? chunk.text : assembled + chunk.delta
    }
    expect(final.length).toBeGreaterThan(10)
    expect(assembled).toBe(final)
  })

  it('cancels a running generation and keeps the session usable', async () => {
    const session = await afm.createSession()
    const controller = new AbortController()
    setTimeout(() => controller.abort(), 500)
    await expect(
      session.respond('Write a 500-word essay about sailing.', { signal: controller.signal }),
    ).rejects.toBeInstanceOf(AbortError)
    await expect(session.respond('Say OK.')).resolves.toBeTruthy()
  })

  it('reports context overflow as ContextWindowExceededError', async () => {
    const session = await afm.createSession()
    const words = 'garden river mountain coffee window planet library orange bicycle music'.split(' ')
    const long = Array.from({ length: 12_000 }, (_, i) => words[(i * 7) % words.length]).join(' ')
    const error = await session.respond(`Count the words: ${long}`).catch((e) => e)
    expect(error).toBeInstanceOf(ContextWindowExceededError)
    expect(error.contextSize).toBeGreaterThan(0)
  })

  it('counts tokens', async () => {
    await expect(afm.tokenCount('Hello world')).resolves.toBeGreaterThan(0)
  })

  it('returns structured output that validates against a Zod schema', async () => {
    const session = await afm.createSession()
    const Person = z.object({
      name: z.string(),
      age: z.number().int().min(0).max(120),
      nickname: z.string().nullable(),
      role: z.enum(['admin', 'user']),
      hobbies: z.array(z.string()).min(1).max(3),
      email: z.string().email(),
    })
    const person = await session.respond('Invent a fictional user.', { schema: zodSchema(Person) })
    expect(Person.parse(person)).toEqual(person)
    expect(Object.keys(person)).toEqual(['name', 'age', 'nickname', 'role', 'hobbies', 'email'])
  })

  it('streams partial structured values', async () => {
    const session = await afm.createSession()
    const schema = zodSchema(z.object({ title: z.string(), steps: z.array(z.string()).max(3) }))
    const partials: unknown[] = []
    let final: unknown
    for await (const chunk of session.stream('A short recipe for tea.', { schema })) {
      if (chunk.done) final = chunk.content
      else partials.push(chunk.partial)
    }
    expect(partials.length).toBeGreaterThan(1)
    expect(final).toMatchObject({ title: expect.any(String), steps: expect.any(Array) })
  })

  it('rejects a pattern the model cannot handle with UnsupportedSchemaError', async () => {
    const session = await afm.createSession()
    const error = await session
      .respond('x', {
        schema: {
          type: 'object',
          properties: { code: { type: 'string', pattern: '[a-z]+' } },
          required: ['code'],
        },
      })
      .catch((e) => e)
    expect(error).toBeInstanceOf(UnsupportedSchemaError)
  })

  it('calls a JavaScript tool and uses its result', async () => {
    const calls: string[] = []
    const session = await afm.createSession({
      instructions: 'Use tools when they help. Answer briefly.',
      tools: [
        tool({
          name: 'getWeather',
          description: 'Get the current weather for a city',
          parameters: zodSchema(z.object({ city: z.string().describe('City name') })),
          execute: ({ city }) => {
            calls.push(city)
            return { city, temperatureC: 17, condition: 'foggy' }
          },
        }),
      ],
    })
    const answer = await session.respond('What is the weather in Prague right now?')
    expect(calls.map((c) => c.toLowerCase())).toContain('prague')
    expect(answer.toLowerCase()).toMatch(/17|fog/)
  })

  it('fails the generation with ToolExecutionError when a tool throws', async () => {
    const session = await afm.createSession({
      tools: [
        tool({
          name: 'getBalance',
          description: "Look up the user's account balance",
          parameters: { type: 'object', properties: {} },
          execute: () => {
            throw new Error('database offline')
          },
        }),
      ],
    })
    const error = await session.respond('What is my account balance? Use the tool.').catch((e) => e)
    expect(error).toBeInstanceOf(ToolExecutionError)
    expect(error.message).toContain('database offline')
  })

  it('understands an image given as a path or as base64 data', async () => {
    const path = fileURLToPath(new URL('./fixtures/red.png', import.meta.url))
    const question = 'What single color fills this image? Answer with one word.'
    const fromPath = await (await afm.createSession()).respond([
      { type: 'text', text: question },
      { type: 'image', path },
    ])
    const fromData = await (await afm.createSession()).respond([
      { type: 'text', text: question },
      { type: 'image', data: readFileSync(path).toString('base64'), mimeType: 'image/png' },
    ])
    expect(fromPath.toLowerCase()).toContain('red')
    expect(fromData.toLowerCase()).toContain('red')
  })
})
