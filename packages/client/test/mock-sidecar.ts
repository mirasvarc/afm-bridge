import type { Connection, ModelStatus, Transport, TransportHandlers } from '../src/index.js'

// biome-ignore lint/suspicious/noExplicitAny: test double for arbitrary JSON-RPC traffic
type Json = any

export interface RespondContext {
  /** Sends a `session/delta` notification. */
  delta(delta: string): void
  reset(text: string): void
  /** Aborted when the client sends `cancel` for this request. */
  signal: AbortSignal
  process: MockProcess
}

export interface MockBehavior {
  protocolVersion?: number
  status?: ModelStatus
  /** Never answer `initialize`. */
  silentInitialize?: boolean
  createError?: { code: number; message: string; data: Json }
  respond?: (params: Json, ctx: RespondContext) => Promise<{ text: string; usage?: Json }>
}

export const availableStatus: ModelStatus = {
  available: true,
  contextSize: 4096,
  capabilities: ['toolCalling'],
  supportedLanguages: ['en'],
}

/** In-memory sidecar speaking the protocol, for unit tests without a process. */
export class MockTransport implements Transport {
  readonly processes: MockProcess[] = []
  connectError: Error | undefined

  constructor(public behavior: MockBehavior = {}) {}

  async connect(handlers: TransportHandlers): Promise<Connection> {
    if (this.connectError) throw this.connectError
    const process = new MockProcess(this.behavior, handlers)
    this.processes.push(process)
    return process.connection
  }

  get current(): MockProcess {
    const p = this.processes.at(-1)
    if (!p) throw new Error('no process started')
    return p
  }
}

export class MockProcess {
  readonly received: Json[] = []
  readonly activity: boolean[] = []
  alive = true
  private nextSession = 1
  private readonly sessions = new Set<string>()
  private readonly running = new Map<number, AbortController>()

  readonly connection: Connection

  constructor(
    private readonly behavior: MockBehavior,
    private readonly handlers: TransportHandlers,
  ) {
    this.connection = {
      send: (line) => this.receive(JSON.parse(line)),
      close: async () => this.exit(0, null),
      setActive: (active) => this.activity.push(active),
    }
  }

  requests(method: string): Json[] {
    return this.received.filter((m) => m.method === method)
  }

  crash(code = 1) {
    this.handlers.onLog?.('fatal: simulated crash')
    this.exit(code, null)
  }

  /** Sends an arbitrary message to the client. */
  emit(message: Json) {
    setTimeout(() => {
      if (this.alive) this.handlers.onMessage(JSON.stringify(message))
    }, 0)
  }

  private exit(code: number | null, signal: string | null) {
    if (!this.alive) return
    this.alive = false
    for (const c of this.running.values()) c.abort()
    this.handlers.onClose({ code, signal })
  }

  private reply(id: Json, result: Json) {
    this.emit({ jsonrpc: '2.0', id, result })
  }

  private fail(id: Json, error: { code: number; message: string; data: Json }) {
    this.emit({ jsonrpc: '2.0', id, error })
  }

  private receive(message: Json) {
    if (!this.alive) return
    this.received.push(message)
    const { id, method, params } = message
    switch (method) {
      case 'initialize':
        if (this.behavior.silentInitialize) return
        this.reply(id, {
          protocolVersion: this.behavior.protocolVersion ?? 1,
          server: { name: 'afm-bridge-server', version: '0.0.0-mock' },
          os: { version: '27.0' },
          models: {
            'on-device': this.behavior.status ?? availableStatus,
            'private-cloud': { available: false, reason: 'requiresEntitlement', message: 'no' },
          },
        })
        return
      case 'model/status':
        this.reply(id, this.behavior.status ?? availableStatus)
        return
      case 'model/tokenCount':
        this.reply(id, { tokenCount: String(params.text).split(' ').length })
        return
      case 'session/create': {
        if (this.behavior.createError) return this.fail(id, this.behavior.createError)
        const sessionId = `s${this.nextSession++}`
        this.sessions.add(sessionId)
        this.reply(id, { sessionId, contextSize: 4096 })
        return
      }
      case 'session/respond':
        this.handleRespond(id, params)
        return
      case 'session/info':
        this.reply(id, { model: 'on-device', contextSize: 4096, isResponding: false, historyTokenCount: 10 })
        return
      case 'session/prewarm':
        this.reply(id, {})
        return
      case 'session/dispose':
        this.sessions.delete(params.sessionId)
        this.reply(id, {})
        return
      case 'cancel':
        this.running.get(params.id)?.abort()
        return
      case 'shutdown':
        this.reply(id, {})
        setTimeout(() => this.exit(0, null), 1)
        return
      default:
        if (id !== undefined) {
          this.fail(id, {
            code: -32601,
            message: `Method not found: ${method}`,
            data: { type: 'methodNotFound' },
          })
        }
    }
  }

  private handleRespond(id: number, params: Json) {
    if (!this.sessions.has(params.sessionId)) {
      return this.fail(id, {
        code: -32020,
        message: 'Session not found',
        data: { type: 'sessionNotFound', sessionId: params.sessionId },
      })
    }
    const controller = new AbortController()
    this.running.set(id, controller)
    const respond = this.behavior.respond ?? (async () => ({ text: 'Hello!' }))
    const ctx: RespondContext = {
      delta: (delta) =>
        params.stream &&
        this.emit({ jsonrpc: '2.0', method: 'session/delta', params: { requestId: id, delta } }),
      reset: (text) =>
        params.stream &&
        this.emit({ jsonrpc: '2.0', method: 'session/delta', params: { requestId: id, reset: true, text } }),
      signal: controller.signal,
      process: this,
    }
    const cancelled = new Promise<never>((_, reject) =>
      controller.signal.addEventListener('abort', () => reject(new Error('cancelled'))),
    )
    Promise.race([respond(params, ctx), cancelled]).then(
      (result) => {
        this.running.delete(id)
        this.reply(id, result)
      },
      (error: Json) => {
        this.running.delete(id)
        if (controller.signal.aborted) {
          this.fail(id, { code: -32800, message: 'Request was cancelled', data: { type: 'cancelled' } })
        } else {
          this.fail(id, error)
        }
      },
    )
  }
}

/** Waits until `condition` holds (polling), for asynchronous assertions. */
export async function until(condition: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now()
  while (!condition()) {
    if (Date.now() - start > timeoutMs) throw new Error('condition not met in time')
    await new Promise((r) => setTimeout(r, 2))
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
