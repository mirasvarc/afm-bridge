import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { AbortError, AppleFoundationModels, ContextWindowExceededError } from '../src/index.js'
import { NodeStdioTransport } from '../src/node/index.js'

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
})
