import { describe, expect, it } from 'vitest'
import {
  AbortError,
  AfmError,
  AppleFoundationModels,
  ClientClosedError,
  ContextWindowExceededError,
  createLineSplitter,
  ModelUnavailableError,
  ProtocolError,
  RequestTimeoutError,
  SessionBusyError,
  SessionLostError,
  SessionNotFoundError,
  SidecarCrashedError,
  type StreamChunk,
  TransportError,
} from '../src/index.js'
import { type MockBehavior, MockTransport, sleep, until } from './mock-sidecar.js'

function setup(
  behavior: MockBehavior = {},
  options: { requestTimeoutMs?: number; initializeTimeoutMs?: number } = {},
) {
  const transport = new MockTransport(behavior)
  const afm = new AppleFoundationModels({ transport, ...options })
  return { transport, afm }
}

async function collect(stream: AsyncIterable<StreamChunk>): Promise<StreamChunk[]> {
  const chunks: StreamChunk[] = []
  for await (const chunk of stream) chunks.push(chunk)
  return chunks
}

describe('startup and availability', () => {
  it('starts the sidecar lazily and only once', async () => {
    const { transport, afm } = setup()
    expect(transport.processes).toHaveLength(0)
    const [a, b] = await Promise.all([afm.availability(), afm.serverInfo()])
    expect(a).toMatchObject({ available: true, contextSize: 4096 })
    expect(b.models['private-cloud']).toMatchObject({ available: false, reason: 'requiresEntitlement' })
    expect(transport.processes).toHaveLength(1)
    expect(transport.current.requests('initialize')[0].params).toMatchObject({
      protocolVersion: 1,
      client: { name: 'afm-bridge' },
    })
  })

  it('reports an unavailable model without throwing', async () => {
    const { afm } = setup({
      status: { available: false, reason: 'appleIntelligenceNotEnabled', message: 'Turn it on' },
    })
    await expect(afm.availability()).resolves.toEqual({
      available: false,
      reason: 'appleIntelligenceNotEnabled',
      message: 'Turn it on',
    })
  })

  it('turns a platform check failure into an unavailable status and a typed error', async () => {
    const { transport, afm } = setup()
    transport.connectError = new ModelUnavailableError('Needs Apple silicon', {
      type: 'modelUnavailable',
      data: { reason: 'unsupportedPlatform' },
    })
    await expect(afm.availability()).resolves.toMatchObject({
      available: false,
      reason: 'unsupportedPlatform',
    })
    const error = await afm.createSession().catch((e) => e)
    expect(error).toBeInstanceOf(ModelUnavailableError)
    expect(error.reason).toBe('unsupportedPlatform')
  })

  it('maps a modelUnavailable error from session/create', async () => {
    const { afm } = setup({
      createError: {
        code: -32010,
        message: 'Apple Intelligence is turned off',
        data: { type: 'modelUnavailable', model: 'on-device', reason: 'appleIntelligenceNotEnabled' },
      },
    })
    const error = await afm.createSession().catch((e) => e)
    expect(error).toBeInstanceOf(ModelUnavailableError)
    expect(error.reason).toBe('appleIntelligenceNotEnabled')
    expect(error.message).toBe('Apple Intelligence is turned off')
  })

  it('rejects an incompatible protocol version and stops the process', async () => {
    const { transport, afm } = setup({ protocolVersion: 2 })
    const error = await afm.serverInfo().catch((e) => e)
    expect(error).toBeInstanceOf(ProtocolError)
    expect(error.message).toContain('protocol version 2')
    expect(transport.current.alive).toBe(false)
  })

  it('fails with SidecarCrashedError when initialize never answers', async () => {
    const { transport, afm } = setup({ silentInitialize: true }, { initializeTimeoutMs: 30 })
    await expect(afm.serverInfo()).rejects.toBeInstanceOf(SidecarCrashedError)
    expect(transport.current.alive).toBe(false)
  })

  it('propagates transport errors without counting them as crashes', async () => {
    const { transport, afm } = setup()
    transport.connectError = new TransportError('binary not found', { type: 'transportError' })
    for (let i = 0; i < 5; i++) await expect(afm.serverInfo()).rejects.toBeInstanceOf(TransportError)
    transport.connectError = undefined
    await expect(afm.serverInfo()).resolves.toMatchObject({ protocolVersion: 1 })
  })

  it('counts tokens', async () => {
    const { afm } = setup()
    await expect(afm.tokenCount('one two three')).resolves.toBe(3)
  })
})

describe('sessions', () => {
  it('sends instructions and generation options, but not signal or timeout', async () => {
    const { transport, afm } = setup()
    const session = await afm.createSession({ instructions: 'Be brief.' })
    expect(session.contextSize).toBe(4096)
    const controller = new AbortController()
    await expect(
      session.respond('Hi', {
        temperature: 0.3,
        maximumResponseTokens: 50,
        signal: controller.signal,
        timeoutMs: 5000,
      }),
    ).resolves.toBe('Hello!')
    expect(transport.current.requests('session/create')[0].params).toEqual({ instructions: 'Be brief.' })
    expect(transport.current.requests('session/respond')[0].params).toEqual({
      sessionId: session.id,
      prompt: 'Hi',
      options: { temperature: 0.3, maximumResponseTokens: 50 },
    })
  })

  it('returns usage from generate()', async () => {
    const usage = { inputTokens: 5, cachedInputTokens: 0, outputTokens: 2, reasoningTokens: 0 }
    const { afm } = setup({ respond: async () => ({ text: 'Hi', usage }) })
    const session = await afm.createSession()
    await expect(session.generate('x')).resolves.toEqual({ text: 'Hi', usage })
  })

  it('maps generation errors to typed classes', async () => {
    const { afm } = setup({
      respond: () =>
        Promise.reject({
          code: -32030,
          message: 'Exceeded model context window size',
          data: { type: 'contextWindowExceeded', contextSize: 4096 },
        }),
    })
    const session = await afm.createSession()
    const error = await session.respond('x').catch((e) => e)
    expect(error).toBeInstanceOf(ContextWindowExceededError)
    expect(error).toBeInstanceOf(AfmError)
    expect(error.contextSize).toBe(4096)
    expect(error.type).toBe('contextWindowExceeded')
  })

  it('keeps unknown error types as AfmError', async () => {
    const { afm } = setup({
      respond: () =>
        Promise.reject({ code: -32077, message: 'new thing', data: { type: 'somethingNew', x: 1 } }),
    })
    const session = await afm.createSession()
    const error = await session.respond('x').catch((e) => e)
    expect(error.constructor).toBe(AfmError)
    expect(error.type).toBe('somethingNew')
    expect(error.data).toEqual({ x: 1 })
  })

  it('passes sessionBusy through as SessionBusyError', async () => {
    const { afm } = setup({
      respond: () => Promise.reject({ code: -32021, message: 'busy', data: { type: 'sessionBusy' } }),
    })
    const session = await afm.createSession()
    await expect(session.respond('x')).rejects.toBeInstanceOf(SessionBusyError)
  })

  it('reports session info and prewarms', async () => {
    const { transport, afm } = setup()
    const session = await afm.createSession()
    await session.prewarm('Summarize:')
    expect(transport.current.requests('session/prewarm')[0].params).toEqual({
      sessionId: session.id,
      promptPrefix: 'Summarize:',
    })
    await expect(session.info()).resolves.toMatchObject({ historyTokenCount: 10, isResponding: false })
  })

  it('disposes once and rejects later calls', async () => {
    const { transport, afm } = setup()
    const session = await afm.createSession()
    await session.dispose()
    await session.dispose()
    expect(transport.current.requests('session/dispose')).toHaveLength(1)
    await expect(session.respond('x')).rejects.toBeInstanceOf(SessionNotFoundError)
  })
})

describe('streaming', () => {
  it('yields deltas with the running text and a final chunk', async () => {
    const usage = { inputTokens: 1, cachedInputTokens: 0, outputTokens: 3, reasoningTokens: 0 }
    const { transport, afm } = setup({
      respond: async (_params, ctx) => {
        ctx.delta('Wa')
        ctx.delta('ves')
        await sleep(5)
        ctx.reset('Sea')
        ctx.delta(' foam')
        await sleep(5)
        return { text: 'Sea foam', usage }
      },
    })
    const session = await afm.createSession()
    const chunks = await collect(session.stream('Haiku'))
    expect(chunks).toEqual([
      { done: false, delta: 'Wa', text: 'Wa' },
      { done: false, delta: 'ves', text: 'Waves' },
      { done: false, delta: '', text: 'Sea', reset: true },
      { done: false, delta: ' foam', text: 'Sea foam' },
      { done: true, delta: '', text: 'Sea foam', usage },
    ])
    expect(transport.current.requests('session/respond')[0].params.stream).toBe(true)
  })

  it('does not start the request until iterated', async () => {
    const { transport, afm } = setup()
    const session = await afm.createSession()
    const stream = session.stream('x')
    await sleep(5)
    expect(transport.current.requests('session/respond')).toHaveLength(0)
    await collect(stream)
    expect(transport.current.requests('session/respond')).toHaveLength(1)
  })

  it('cancels the generation when the consumer breaks out', async () => {
    let cancelled = false
    const { transport, afm } = setup({
      respond: async (_p, ctx) => {
        ctx.delta('a')
        await new Promise((_, reject) =>
          ctx.signal.addEventListener('abort', () => {
            cancelled = true
            reject(new Error('x'))
          }),
        )
        return { text: '' }
      },
    })
    const session = await afm.createSession()
    for await (const chunk of session.stream('x')) {
      expect(chunk.delta).toBe('a')
      break
    }
    expect(cancelled).toBe(true)
    expect(transport.current.requests('cancel')).toHaveLength(1)
  })

  it('throws AbortError from the iterator when the signal aborts', async () => {
    const { afm } = setup({
      respond: async (_p, ctx) => {
        ctx.delta('a')
        await new Promise(() => {})
        return { text: '' }
      },
    })
    const session = await afm.createSession()
    const controller = new AbortController()
    const seen: string[] = []
    const error = await (async () => {
      for await (const chunk of session.stream('x', { signal: controller.signal })) {
        seen.push(chunk.delta)
        controller.abort()
      }
    })().catch((e) => e)
    expect(seen).toEqual(['a'])
    expect(error).toBeInstanceOf(AbortError)
    expect(error.name).toBe('AbortError')
  })

  it('delivers buffered chunks before the error', async () => {
    const { afm } = setup({
      respond: async (_p, ctx) => {
        ctx.delta('partial')
        await sleep(5)
        throw { code: -32031, message: 'unsafe', data: { type: 'guardrailViolation' } }
      },
    })
    const session = await afm.createSession()
    const seen: string[] = []
    const error = await (async () => {
      for await (const chunk of session.stream('x')) seen.push(chunk.text)
    })().catch((e) => e)
    expect(seen).toEqual(['partial'])
    expect(error.type).toBe('guardrailViolation')
  })
})

describe('cancellation and timeouts', () => {
  const hang: MockBehavior = { respond: () => new Promise(() => {}) }

  it('sends cancel and rejects with AbortError', async () => {
    const { transport, afm } = setup(hang)
    const session = await afm.createSession()
    const controller = new AbortController()
    const pending = session.respond('x', { signal: controller.signal })
    await until(() => transport.current.requests('session/respond').length === 1)
    controller.abort()
    await expect(pending).rejects.toBeInstanceOf(AbortError)
    const respondId = transport.current.requests('session/respond')[0].id
    expect(transport.current.requests('cancel')[0].params).toEqual({ id: respondId })
  })

  it('does not send anything for an already aborted signal', async () => {
    const { transport, afm } = setup(hang)
    const session = await afm.createSession()
    await expect(session.respond('x', { signal: AbortSignal.abort() })).rejects.toBeInstanceOf(AbortError)
    expect(transport.current.requests('session/respond')).toHaveLength(0)
  })

  it('times out on the client side and cancels the request', async () => {
    const { transport, afm } = setup(hang)
    const session = await afm.createSession()
    const error = await session.respond('x', { timeoutMs: 20 }).catch((e) => e)
    expect(error).toBeInstanceOf(RequestTimeoutError)
    expect(transport.current.requests('cancel')).toHaveLength(1)
  })

  it('applies requestTimeoutMs to every call', async () => {
    const { afm } = setup(hang, { requestTimeoutMs: 20 })
    const session = await afm.createSession()
    await expect(session.respond('x')).rejects.toBeInstanceOf(RequestTimeoutError)
  })
})

describe('process lifecycle', () => {
  it('rejects in-flight calls when the sidecar crashes and restarts on the next call', async () => {
    const { transport, afm } = setup({ respond: () => new Promise(() => {}) })
    const session = await afm.createSession()
    const pending = session.respond('x')
    await until(() => transport.current.requests('session/respond').length === 1)
    transport.current.crash(134)

    const error = await pending.catch((e) => e)
    expect(error).toBeInstanceOf(SidecarCrashedError)
    expect(error.message).toContain('exit code 134')
    expect(error.message).toContain('simulated crash')

    // Old sessions are gone, new ones work in a fresh process.
    await expect(session.respond('x')).rejects.toBeInstanceOf(SessionLostError)
    await expect(afm.availability()).resolves.toMatchObject({ available: true })
    expect(transport.processes).toHaveLength(2)
    expect(transport.processes[0]?.alive).toBe(false)
  })

  it('stops restarting after too many crashes within the window', async () => {
    const transport = new MockTransport()
    const afm = new AppleFoundationModels({ transport, restart: { maxRestarts: 2, windowMs: 60_000 } })
    for (let i = 0; i < 3; i++) {
      await afm.serverInfo()
      transport.current.crash()
    }
    const error = await afm.serverInfo().catch((e) => e)
    expect(error).toBeInstanceOf(SidecarCrashedError)
    expect(error.message).toContain('3 times')
    expect(transport.processes).toHaveLength(3)
  })

  it('restarts again once old crashes leave the window', async () => {
    const transport = new MockTransport()
    const afm = new AppleFoundationModels({ transport, restart: { maxRestarts: 0, windowMs: 30 } })
    await afm.serverInfo()
    transport.current.crash()
    await expect(afm.serverInfo()).rejects.toBeInstanceOf(SidecarCrashedError)
    await sleep(40)
    await expect(afm.serverInfo()).resolves.toMatchObject({ protocolVersion: 1 })
  })

  it('close() shuts the sidecar down and rejects later calls', async () => {
    const { transport, afm } = setup({ respond: () => new Promise(() => {}) })
    const session = await afm.createSession()
    const pending = session.respond('x')
    await until(() => transport.current.requests('session/respond').length === 1)
    await afm.close()
    await afm.close()
    await expect(pending).rejects.toBeInstanceOf(ClientClosedError)
    expect(transport.current.requests('shutdown')).toHaveLength(1)
    expect(transport.current.alive).toBe(false)
    await expect(afm.availability()).rejects.toBeInstanceOf(ClientClosedError)
    await expect(session.respond('x')).rejects.toBeInstanceOf(ClientClosedError)
    await expect(session.dispose()).resolves.toBeUndefined()
  })

  it('close() before any call does not start the sidecar', async () => {
    const { transport, afm } = setup()
    await afm.close()
    expect(transport.processes).toHaveLength(0)
  })

  it('marks the connection active only while requests are in flight', async () => {
    const { transport, afm } = setup()
    const session = await afm.createSession()
    await session.respond('x')
    const activity = transport.current.activity
    expect(activity.at(-1)).toBe(false)
    expect(activity).toContain(true)
  })

  it('answers unknown server requests with methodNotFound', async () => {
    const { transport, afm } = setup()
    await afm.serverInfo()
    transport.current.emit({ jsonrpc: '2.0', id: 's:1', method: 'future/method', params: {} })
    await until(() => transport.current.received.some((m) => m.id === 's:1'))
    const reply = transport.current.received.find((m) => m.id === 's:1')
    expect(reply.error.data.type).toBe('methodNotFound')
  })

  it('forwards sidecar logs', async () => {
    const lines: string[] = []
    const transport = new MockTransport()
    const afm = new AppleFoundationModels({ transport, onLog: (l) => lines.push(l) })
    await afm.serverInfo()
    transport.current.crash()
    expect(lines).toContain('fatal: simulated crash')
  })
})

describe('createLineSplitter', () => {
  it('splits chunks into lines across boundaries', () => {
    const lines: string[] = []
    const splitter = createLineSplitter((l) => lines.push(l))
    splitter.push('{"a":1}\n{"b"')
    splitter.push(':2}\r\n\n{"c":3}')
    expect(lines).toEqual(['{"a":1}', '{"b":2}'])
    splitter.flush()
    expect(lines).toEqual(['{"a":1}', '{"b":2}', '{"c":3}'])
  })
})
