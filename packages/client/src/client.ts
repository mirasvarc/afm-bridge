import {
  AfmError,
  ClientClosedError,
  ModelUnavailableError,
  ProtocolError,
  RequestTimeoutError,
  SessionLostError,
  SidecarCrashedError,
} from './errors.js'
import { type RequestOptions, RpcPeer } from './rpc.js'
import { type DeltaParams, Session, type SessionHost } from './session.js'
import { runTool, type Tool, toolDefinition } from './tool.js'
import type { CloseInfo, Connection, Transport } from './transport.js'
import type { CallOptions, ModelId, ModelStatus, ServerInfo, SessionOptions } from './types.js'

/** Protocol version this client speaks. See PROTOCOL.md section 3. */
export const PROTOCOL_VERSION = 1
export const CLIENT_VERSION = '0.1.0'

export interface AppleFoundationModelsOptions {
  /** How to reach the sidecar, e.g. `new NodeStdioTransport()` from `afm-bridge/node`. */
  transport: Transport
  /** Reported to the sidecar in `initialize` (shows up in its debug log). */
  clientInfo?: { name: string; version: string }
  /**
   * Automatic restart after the sidecar crashes. The process is restarted on the next
   * call; after `maxRestarts` crashes within `windowMs` calls fail with `SidecarCrashedError`
   * until the window passes. Default: 3 restarts per 60 s.
   */
  restart?: { maxRestarts?: number; windowMs?: number }
  /** Timeout for starting the sidecar and the `initialize` handshake. Default 10 s. */
  initializeTimeoutMs?: number
  /** Default client-side timeout for every call. Default: none (use `AbortSignal`). */
  requestTimeoutMs?: number
  /** Receives every stderr line of the sidecar. */
  onLog?: (line: string) => void
}

interface Live {
  epoch: number
  peer: RpcPeer
  connection: Connection
  info: ServerInfo
  slot: Slot
}

/** Per-process state that exists before the handshake finishes. */
interface Slot {
  peer?: RpcPeer
  intentional: boolean
  exited?: CloseInfo
  listeners: Map<number, (params: DeltaParams) => void>
  /** Tools by session id, then by name. */
  tools: Map<string, Map<string, Tool<unknown>>>
}

const LOG_TAIL = 20

/**
 * Entry point of afm-bridge. The sidecar starts lazily on the first call.
 *
 * ```ts
 * const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })
 * const session = await afm.createSession({ instructions: 'Answer briefly.' })
 * console.log(await session.respond('Hello'))
 * await afm.close()
 * ```
 */
export class AppleFoundationModels {
  private readonly transport: Transport
  private readonly options: AppleFoundationModelsOptions
  private live: Live | undefined
  private starting: Promise<Live> | undefined
  private epoch = 0
  private crashes: number[] = []
  private closed = false
  private readonly logTail: string[] = []
  private readonly host: SessionHost

  constructor(options: AppleFoundationModelsOptions) {
    this.transport = options.transport
    this.options = options
    this.host = {
      request: (epoch, method, params, opts) => this.requestInEpoch(epoch, method, params, opts),
      listen: (epoch, requestId, listener) => {
        const slot = this.live?.epoch === epoch ? this.live.slot : undefined
        slot?.listeners.set(requestId, listener)
        return () => slot?.listeners.delete(requestId)
      },
      disposed: (epoch, sessionId) => {
        if (this.live?.epoch === epoch) this.live.slot.tools.delete(sessionId)
      },
    }
  }

  /** Handshake result: server version, macOS version and status of every model. Starts the sidecar. */
  async serverInfo(): Promise<ServerInfo> {
    return (await this.connect()).info
  }

  /**
   * Fresh availability of a model. Never throws because the model is unavailable:
   * check `available` and `reason` instead.
   */
  async availability(model: ModelId = 'on-device', options: CallOptions = {}): Promise<ModelStatus> {
    try {
      return await this.request<ModelStatus>('model/status', { model }, options)
    } catch (error) {
      if (error instanceof ModelUnavailableError) {
        return { available: false, reason: error.reason, message: error.message }
      }
      throw error
    }
  }

  /** Number of tokens `text` occupies in the model's context (macOS 26.4+). */
  async tokenCount(text: string, options: CallOptions & { model?: ModelId } = {}): Promise<number> {
    const { model, ...call } = options
    const result = await this.request<{ tokenCount: number }>(
      'model/tokenCount',
      { text, ...(model ? { model } : {}) },
      call,
    )
    return result.tokenCount
  }

  /** Creates a conversation. Throws `ModelUnavailableError` (with `reason`) when the model cannot be used. */
  async createSession(options: SessionOptions = {}): Promise<Session> {
    const live = await this.connect()
    const { signal, tools, ...params } = options
    const result = await this.requestInEpoch<{ sessionId: string; contextSize: number }>(
      live.epoch,
      'session/create',
      tools?.length ? { ...params, tools: tools.map(toolDefinition) } : params,
      { signal },
    )
    if (tools?.length) live.slot.tools.set(result.sessionId, new Map(tools.map((t) => [t.name, t])))
    return new Session(
      this.host,
      live.epoch,
      result.sessionId,
      result.contextSize,
      options.model ?? 'on-device',
    )
  }

  /** Stops the sidecar. Pending calls reject with `ClientClosedError`. The client cannot be reused. */
  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    const live = this.live ?? (await this.starting?.catch(() => undefined))
    this.live = undefined
    if (!live) return
    live.slot.intentional = true
    try {
      await live.peer.request('shutdown', {}, { timeoutMs: 2000, cancelGraceMs: 0 })
    } catch {
      // The process is killed below anyway.
    }
    live.peer.close(new ClientClosedError('The afm-bridge client was closed'))
    await live.connection.close()
  }

  // MARK: - Internals

  private async request<T>(method: string, params: unknown, options: CallOptions = {}): Promise<T> {
    const live = await this.connect()
    return this.requestInEpoch<T>(live.epoch, method, params, options)
  }

  private requestInEpoch<T>(
    epoch: number,
    method: string,
    params: unknown,
    options: RequestOptions = {},
  ): Promise<T> {
    if (this.closed) return Promise.reject(new ClientClosedError('The afm-bridge client was closed'))
    const live = this.live
    if (!live || live.epoch !== epoch) {
      return Promise.reject(
        new SessionLostError(
          'This session belonged to an afm-bridge-server process that is no longer running (it crashed or was restarted). Create a new session.',
          { type: 'sessionLost' },
        ),
      )
    }
    return live.peer.request<T>(method, params, {
      ...options,
      timeoutMs: options.timeoutMs ?? this.options.requestTimeoutMs,
    })
  }

  private connect(): Promise<Live> {
    if (this.closed) return Promise.reject(new ClientClosedError('The afm-bridge client was closed'))
    if (this.live) return Promise.resolve(this.live)
    if (!this.starting) {
      this.starting = this.start().finally(() => {
        this.starting = undefined
      })
    }
    return this.starting
  }

  private async start(): Promise<Live> {
    const { maxRestarts = 3, windowMs = 60_000 } = this.options.restart ?? {}
    const now = Date.now()
    this.crashes = this.crashes.filter((t) => now - t < windowMs)
    if (this.crashes.length > maxRestarts) {
      throw new SidecarCrashedError(
        `afm-bridge-server crashed ${this.crashes.length} times within ${Math.round(windowMs / 1000)} s; not restarting it again yet.${this.formatLogTail()}`,
        { type: 'sidecarCrashed', data: { crashes: this.crashes.length } },
      )
    }

    const epoch = ++this.epoch
    const slot: Slot = { intentional: false, listeners: new Map(), tools: new Map() }
    const connection = await this.transport.connect({
      onMessage: (line) => slot.peer?.handleLine(line),
      onLog: (line) => {
        this.logTail.push(line)
        if (this.logTail.length > LOG_TAIL) this.logTail.shift()
        this.options.onLog?.(line)
      },
      onClose: (info) => this.handleClose(epoch, slot, info),
    })

    const peer = new RpcPeer(connection, {
      onNotification: (method, params) => {
        if (method === 'session/delta') {
          const p = params as DeltaParams
          slot.listeners.get(p.requestId)?.(p)
        }
      },
      onRequest: async (method, params, signal) => {
        if (method !== 'tool/call') {
          throw new AfmError(`Method not found: ${method}`, { type: 'methodNotFound', code: -32601 })
        }
        const {
          sessionId,
          name,
          arguments: args,
        } = params as { sessionId: string; name: string; arguments: unknown }
        const found = slot.tools.get(sessionId)?.get(name)
        if (!found) throw new AfmError(`Unknown tool '${name}'`, { type: 'toolNotFound', code: -32000 })
        return runTool(found, args, { signal, sessionId })
      },
      onPendingChange: (count) => connection.setActive?.(count > 0),
      onProtocolError: (error) => this.options.onLog?.(`[afm-bridge client] ${error.message}`),
    })
    slot.peer = peer
    if (slot.exited) peer.close(this.crashError(slot.exited))

    try {
      const info = await peer.request<ServerInfo>(
        'initialize',
        {
          protocolVersion: PROTOCOL_VERSION,
          client: this.options.clientInfo ?? { name: 'afm-bridge', version: CLIENT_VERSION },
        },
        { timeoutMs: this.options.initializeTimeoutMs ?? 10_000, cancelGraceMs: 0 },
      )
      if (info.protocolVersion !== PROTOCOL_VERSION) {
        throw new ProtocolError(
          `afm-bridge-server ${info.server.version} speaks protocol version ${info.protocolVersion}, this client needs ${PROTOCOL_VERSION}. Install matching versions of afm-bridge and afm-bridge-server.`,
          { type: 'protocolVersionMismatch' },
        )
      }
      if (this.closed) throw new ClientClosedError('The afm-bridge client was closed')
      const live: Live = { epoch, peer, connection, info, slot }
      this.live = live
      return live
    } catch (error) {
      slot.intentional = true
      peer.close(error instanceof Error ? error : new Error(String(error)))
      await connection.close().catch(() => {})
      if (error instanceof RequestTimeoutError) {
        throw new SidecarCrashedError(
          `afm-bridge-server did not answer the initialize handshake within ${this.options.initializeTimeoutMs ?? 10_000} ms.${this.formatLogTail()}`,
          { type: 'sidecarCrashed', cause: error },
        )
      }
      throw error
    }
  }

  private handleClose(epoch: number, slot: Slot, info: CloseInfo) {
    slot.exited = info
    if (this.live?.epoch === epoch) this.live = undefined
    if (slot.intentional || this.closed) {
      slot.peer?.close(new ClientClosedError('The afm-bridge client was closed'))
      return
    }
    this.crashes.push(Date.now())
    slot.peer?.close(this.crashError(info))
  }

  private crashError(info: CloseInfo): SidecarCrashedError {
    const how = info.signal ? `signal ${info.signal}` : `exit code ${info.code}`
    return new SidecarCrashedError(
      `afm-bridge-server stopped unexpectedly (${how}).${this.formatLogTail()}`,
      {
        type: 'sidecarCrashed',
        data: { exitCode: info.code, signal: info.signal },
        cause: info.error,
      },
    )
  }

  private formatLogTail(): string {
    return this.logTail.length > 0 ? `\nLast log lines:\n${this.logTail.join('\n')}` : ''
  }
}
