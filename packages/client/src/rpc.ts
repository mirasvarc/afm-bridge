import {
  AbortError,
  AfmError,
  errorFromRpc,
  ProtocolError,
  RequestTimeoutError,
  type RpcErrorPayload,
} from './errors.js'
import type { Connection } from './transport.js'

export interface RequestOptions {
  signal?: AbortSignal | undefined
  timeoutMs?: number | undefined
  /** Called with the request id right before the request is written. */
  onStart?: (id: number) => void
  /** How long to wait for the peer to confirm a cancel before rejecting anyway. Default 5000 ms. */
  cancelGraceMs?: number
}

type IncomingRequestHandler = (method: string, params: unknown, signal: AbortSignal) => Promise<unknown>

interface Pending {
  resolve(value: unknown): void
  reject(error: unknown): void
  cleanup(): void
}

const DEFAULT_CANCEL_GRACE_MS = 5000

/** JSON-RPC 2.0 peer over one connection. Both sides can send requests. */
export class RpcPeer {
  private nextId = 1
  private readonly pending = new Map<number, Pending>()
  private readonly incoming = new Map<string | number, AbortController>()
  private closedError: Error | undefined

  constructor(
    private readonly connection: Connection,
    private readonly handlers: {
      onNotification(method: string, params: unknown): void
      onRequest?: IncomingRequestHandler
      onPendingChange?(count: number): void
      onProtocolError?(error: Error): void
    },
  ) {}

  get pendingCount(): number {
    return this.pending.size
  }

  request<T>(method: string, params: unknown, options: RequestOptions = {}): Promise<T> {
    if (this.closedError) return Promise.reject(this.closedError)
    const { signal, timeoutMs } = options
    if (signal?.aborted) return Promise.reject(new AbortError())

    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined
      let graceTimer: ReturnType<typeof setTimeout> | undefined
      let cancelError: AfmError | undefined

      const cancel = (error: AfmError) => {
        if (cancelError || !this.pending.has(id)) return
        cancelError = error
        this.notify('cancel', { id })
        // Wait for the sidecar's answer so the session is free again when we reject,
        // but never hang if the sidecar does not answer.
        const grace = options.cancelGraceMs ?? DEFAULT_CANCEL_GRACE_MS
        if (grace <= 0) this.settle(id, { error })
        else graceTimer = setTimeout(() => this.settle(id, { error }), grace)
      }
      const onAbort = () => cancel(new AbortError())

      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        // A cancelled request is answered with `cancelled`; report the reason we cancelled for.
        reject: (error) =>
          reject(
            cancelError && error instanceof AfmError && error.type === 'cancelled' ? cancelError : error,
          ),
        cleanup: () => {
          if (timer) clearTimeout(timer)
          if (graceTimer) clearTimeout(graceTimer)
          signal?.removeEventListener('abort', onAbort)
        },
      })
      this.handlers.onPendingChange?.(this.pending.size)

      signal?.addEventListener('abort', onAbort, { once: true })
      if (timeoutMs !== undefined) {
        timer = setTimeout(
          () => cancel(new RequestTimeoutError(`Request '${method}' timed out after ${timeoutMs} ms`)),
          timeoutMs,
        )
      }
      options.onStart?.(id)
      this.write({ jsonrpc: '2.0', id, method, params })
    })
  }

  notify(method: string, params: unknown): void {
    if (this.closedError) return
    this.write({ jsonrpc: '2.0', method, params })
  }

  /** Feeds one line received from the connection. */
  handleLine(line: string): void {
    let message: Record<string, unknown>
    try {
      message = JSON.parse(line)
    } catch {
      this.handlers.onProtocolError?.(new ProtocolError(`Sidecar sent invalid JSON: ${line.slice(0, 200)}`))
      return
    }
    if (typeof message !== 'object' || message === null || message.jsonrpc !== '2.0') {
      this.handlers.onProtocolError?.(
        new ProtocolError(`Sidecar sent a non JSON-RPC message: ${line.slice(0, 200)}`),
      )
      return
    }
    const { id, method } = message
    if (typeof method === 'string') {
      if (id === undefined) this.handleNotification(method, message.params)
      else this.handleIncomingRequest(id as string | number, method, message.params)
      return
    }
    if (typeof id === 'number') {
      if ('error' in message) this.settle(id, { error: errorFromRpc(message.error as RpcErrorPayload) })
      else this.settle(id, { result: message.result })
      return
    }
    // Error without id: the sidecar could not parse something we sent.
    if ('error' in message) this.handlers.onProtocolError?.(errorFromRpc(message.error as RpcErrorPayload))
  }

  /** Rejects everything in flight; later calls reject with the same error. */
  close(error: Error): void {
    if (this.closedError) return
    this.closedError = error
    for (const id of [...this.pending.keys()]) this.settle(id, { error })
    for (const controller of this.incoming.values()) controller.abort()
    this.incoming.clear()
  }

  private handleNotification(method: string, params: unknown) {
    if (method === 'cancel') {
      const id = (params as { id?: string | number } | undefined)?.id
      if (id !== undefined) this.incoming.get(id)?.abort()
      return
    }
    this.handlers.onNotification(method, params)
  }

  private handleIncomingRequest(id: string | number, method: string, params: unknown) {
    const handler = this.handlers.onRequest
    if (!handler) {
      this.write({
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: `Method not found: ${method}`, data: { type: 'methodNotFound' } },
      })
      return
    }
    const controller = new AbortController()
    this.incoming.set(id, controller)
    handler(method, params, controller.signal).then(
      (result) => {
        this.incoming.delete(id)
        this.write({ jsonrpc: '2.0', id, result })
      },
      (error: unknown) => {
        this.incoming.delete(id)
        const payload =
          error instanceof AfmError && error.code !== undefined
            ? { code: error.code, message: error.message, data: { ...error.data, type: error.type } }
            : {
                code: -32000,
                message: error instanceof Error ? error.message : String(error),
                data: { type: 'handlerError' },
              }
        this.write({ jsonrpc: '2.0', id, error: payload })
      },
    )
  }

  private settle(id: number, outcome: { result?: unknown; error?: unknown }) {
    const entry = this.pending.get(id)
    if (!entry) return
    this.pending.delete(id)
    entry.cleanup()
    this.handlers.onPendingChange?.(this.pending.size)
    if ('error' in outcome && outcome.error !== undefined) entry.reject(outcome.error)
    else entry.resolve(outcome.result)
  }

  private write(message: unknown) {
    if (this.closedError) return
    try {
      this.connection.send(JSON.stringify(message))
    } catch (error) {
      this.handlers.onProtocolError?.(error instanceof Error ? error : new Error(String(error)))
    }
  }
}
