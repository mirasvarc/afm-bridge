import { AbortError, AfmError, ClientClosedError, SessionLostError, SessionNotFoundError } from './errors.js'
import type { RequestOptions } from './rpc.js'
import { type SchemaInput, type StructuredSchema, toStructuredSchema } from './schema.js'
import type {
  GenerateResult,
  GenerationOptions,
  ModelId,
  Prompt,
  RespondOptions,
  SessionInfo,
  StreamChunk,
  StructuredOptions,
  StructuredResult,
  StructuredStreamChunk,
  Usage,
} from './types.js'

/** What a session needs from the client. Internal. */
export interface SessionHost {
  request<T>(epoch: number, method: string, params: unknown, options?: RequestOptions): Promise<T>
  listen(epoch: number, requestId: number, listener: (params: DeltaParams) => void): () => void
  disposed(epoch: number, sessionId: string): void
}

export interface DeltaParams {
  requestId: number
  delta?: string
  reset?: boolean
  text?: string
  partial?: unknown
}

interface RespondResult {
  text: string
  content?: unknown
  usage?: Usage
}

type AnyOptions = RespondOptions & { schema?: SchemaInput<unknown> }

/**
 * A conversation with the model. The sidecar keeps its history, so every call sees
 * the previous prompts and responses. Only one `respond`/`stream` may run at a time.
 */
export class Session {
  private disposed = false

  /** @internal Use `AppleFoundationModels.createSession()`. */
  constructor(
    private readonly host: SessionHost,
    private readonly epoch: number,
    readonly id: string,
    /** Context window in tokens. */
    readonly contextSize: number,
    readonly model: ModelId,
  ) {}

  /**
   * Generates a complete response. Returns the text, or with `schema` the parsed and
   * validated value.
   */
  respond(prompt: Prompt, options?: RespondOptions & { schema?: undefined }): Promise<string>
  respond<T>(prompt: Prompt, options: StructuredOptions<T>): Promise<T>
  async respond(prompt: Prompt, options: AnyOptions = {}): Promise<unknown> {
    const result = await this.generate(prompt, options as StructuredOptions<unknown>)
    return options.schema ? (result as StructuredResult<unknown>).content : result.text
  }

  /** Like `respond`, but also returns token usage (macOS 27+). */
  generate(prompt: Prompt, options?: RespondOptions & { schema?: undefined }): Promise<GenerateResult>
  generate<T>(prompt: Prompt, options: StructuredOptions<T>): Promise<StructuredResult<T>>
  async generate(
    prompt: Prompt,
    options: AnyOptions = {},
  ): Promise<GenerateResult | StructuredResult<unknown>> {
    const { signal, timeoutMs } = options
    const schema = options.schema ? toStructuredSchema(options.schema) : undefined
    const result = await this.call<RespondResult>(
      'session/respond',
      this.respondParams(prompt, options, schema),
      {
        signal,
        timeoutMs,
      },
    )
    if (!schema) return withUsage({ text: result.text }, result.usage)
    return withUsage({ content: parseContent(schema, result), text: result.text }, result.usage)
  }

  /**
   * Streams the response. Text: each chunk carries the new `delta` and the full `text`
   * so far. With `schema`: each chunk carries the `partial` value so far. The last chunk
   * has `done: true` with the complete result. Breaking out of the loop cancels the generation.
   */
  stream(
    prompt: Prompt,
    options?: RespondOptions & { schema?: undefined },
  ): AsyncGenerator<StreamChunk, void, undefined>
  stream<T>(
    prompt: Prompt,
    options: StructuredOptions<T>,
  ): AsyncGenerator<StructuredStreamChunk<T>, void, undefined>
  async *stream(
    prompt: Prompt,
    options: AnyOptions = {},
  ): AsyncGenerator<StreamChunk | StructuredStreamChunk<unknown>, void, undefined> {
    const { signal, timeoutMs } = options
    if (signal?.aborted) throw new AbortError()
    this.assertUsable()
    const schema = options.schema ? toStructuredSchema(options.schema) : undefined

    const controller = new AbortController()
    const onAbort = () => controller.abort()
    signal?.addEventListener('abort', onAbort, { once: true })

    const queue = new ChunkQueue()
    let text = ''
    let unsubscribe = () => {}
    const request = this.host.request<RespondResult>(
      this.epoch,
      'session/respond',
      { ...this.respondParams(prompt, options, schema), stream: true },
      {
        signal: controller.signal,
        timeoutMs,
        onStart: (id) => {
          unsubscribe = this.host.listen(this.epoch, id, (p) => {
            if (schema) {
              if (p.partial !== undefined) queue.push({ done: false, partial: p.partial })
            } else if (p.reset) {
              text = p.text ?? ''
              queue.push({ done: false, delta: '', text, reset: true })
            } else if (p.delta) {
              text += p.delta
              queue.push({ done: false, delta: p.delta, text })
            }
          })
        },
      },
    )
    request.then(
      (result) => queue.end(result),
      (error: unknown) => queue.fail(error),
    )

    let finished = false
    try {
      while (true) {
        const item = await queue.next()
        if (item.kind === 'chunk') {
          yield item.chunk
          continue
        }
        finished = true
        const { result } = item
        yield schema
          ? withUsage(
              { done: true as const, content: parseContent(schema, result), text: result.text },
              result.usage,
            )
          : withUsage({ done: true as const, delta: '' as const, text: result.text }, result.usage)
        return
      }
    } finally {
      unsubscribe()
      signal?.removeEventListener('abort', onAbort)
      if (!finished) {
        // The consumer stopped early or an error was thrown: make sure the
        // generation is cancelled and the session is free before we return.
        controller.abort()
        await request.catch(() => {})
      }
    }
  }

  /** Loads model resources ahead of time to reduce the latency of the first response. */
  async prewarm(promptPrefix?: string): Promise<void> {
    await this.call('session/prewarm', { sessionId: this.id, ...(promptPrefix ? { promptPrefix } : {}) })
  }

  /** Context usage of the session. */
  async info(): Promise<SessionInfo> {
    return this.call<SessionInfo>('session/info', { sessionId: this.id })
  }

  /** Frees the session in the sidecar and cancels a running generation. Safe to call twice. */
  async dispose(): Promise<void> {
    if (this.disposed) return
    this.disposed = true
    this.host.disposed(this.epoch, this.id)
    try {
      await this.host.request(this.epoch, 'session/dispose', { sessionId: this.id })
    } catch (error) {
      // Nothing to free when the process is already gone.
      if (error instanceof SessionLostError || error instanceof ClientClosedError) return
      throw error
    }
  }

  private call<T>(method: string, params: unknown, options?: RequestOptions): Promise<T> {
    try {
      this.assertUsable()
    } catch (error) {
      return Promise.reject(error)
    }
    return this.host.request<T>(this.epoch, method, params, options)
  }

  private assertUsable() {
    if (this.disposed) {
      throw new SessionNotFoundError(`Session ${this.id} was disposed`, {
        type: 'sessionNotFound',
        data: { sessionId: this.id },
      })
    }
  }

  private respondParams(prompt: Prompt, options: AnyOptions, schema: StructuredSchema<unknown> | undefined) {
    const { temperature, maximumResponseTokens, sampling, toolCalling, reasoningLevel } = options
    const generation: GenerationOptions = {
      temperature,
      maximumResponseTokens,
      sampling,
      toolCalling,
      reasoningLevel,
    }
    const defined = Object.fromEntries(Object.entries(generation).filter(([, v]) => v !== undefined))
    return {
      sessionId: this.id,
      prompt,
      ...(Object.keys(defined).length > 0 ? { options: defined } : {}),
      ...(schema ? { schema: schema.jsonSchema } : {}),
      ...(schema && options.includeSchemaInPrompt !== undefined
        ? { includeSchemaInPrompt: options.includeSchemaInPrompt }
        : {}),
    }
  }
}

function parseContent(schema: StructuredSchema<unknown>, result: RespondResult): unknown {
  return schema.parse(result.content !== undefined ? result.content : JSON.parse(result.text))
}

function withUsage<T extends object>(value: T, usage: Usage | undefined): T & { usage?: Usage } {
  return usage ? { ...value, usage } : value
}

type QueueItem =
  | { kind: 'chunk'; chunk: StreamChunk | StructuredStreamChunk<unknown> }
  | { kind: 'end'; result: RespondResult }

/** Single-consumer queue that delivers buffered chunks before an error. */
class ChunkQueue {
  private readonly items: QueueItem[] = []
  private error: { value: unknown } | undefined
  private waiter: (() => void) | undefined

  push(chunk: StreamChunk | StructuredStreamChunk<unknown>) {
    this.items.push({ kind: 'chunk', chunk })
    this.wake()
  }

  end(result: RespondResult) {
    this.items.push({ kind: 'end', result })
    this.wake()
  }

  fail(error: unknown) {
    this.error = { value: error }
    this.wake()
  }

  async next(): Promise<QueueItem> {
    while (true) {
      const item = this.items.shift()
      if (item) return item
      if (this.error)
        throw this.error.value instanceof Error ? this.error.value : new AfmError(String(this.error.value))
      await new Promise<void>((resolve) => {
        this.waiter = resolve
      })
    }
  }

  private wake() {
    const waiter = this.waiter
    this.waiter = undefined
    waiter?.()
  }
}
