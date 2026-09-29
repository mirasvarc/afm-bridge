import type { DeepPartial, SchemaInput } from './schema.js'
import type { Tool } from './tool.js'

/** Which model to use. `private-cloud` is reserved; see PROTOCOL.md section 10. */
export type ModelId = 'on-device' | 'private-cloud'

export type UnavailableReason =
  /** The Mac cannot run Apple Intelligence (Apple silicon required). */
  | 'deviceNotEligible'
  /** Apple Intelligence is switched off in System Settings. */
  | 'appleIntelligenceNotEnabled'
  /** Model assets are still downloading or being prepared. Try again later. */
  | 'modelNotReady'
  /** Private Cloud Compute: the system is not ready yet. */
  | 'systemNotReady'
  /** macOS is too old (afm-bridge needs macOS 26 or newer). */
  | 'unsupportedOS'
  /** Not macOS on Apple silicon (detected by the client, the sidecar never starts). */
  | 'unsupportedPlatform'
  /** The model needs an entitlement afm-bridge does not have. */
  | 'requiresEntitlement'
  | 'unknown'

export type Capability = 'vision' | 'guidedGeneration' | 'reasoning' | 'toolCalling'

export type ModelStatus =
  | {
      available: true
      /** Context window in tokens (instructions + history + prompt + response). */
      contextSize: number
      /** Model variant name, macOS 27+. */
      variant?: string
      /** Empty on macOS 26, which does not report capabilities. */
      capabilities: Capability[]
      /** BCP 47 codes, for example `en`, `en-GB`, `de`. */
      supportedLanguages: string[]
    }
  | { available: false; reason: UnavailableReason; message: string }

export type Sampling =
  | { mode: 'greedy' }
  | { mode: 'topK'; k: number; seed?: number }
  | { mode: 'topP'; threshold: number; seed?: number }

export interface GenerationOptions {
  temperature?: number
  maximumResponseTokens?: number
  sampling?: Sampling
  /** macOS 27+. */
  toolCalling?: 'allowed' | 'required' | 'disallowed'
  /** macOS 27+, only for models with the `reasoning` capability. */
  reasoningLevel?: 'light' | 'moderate' | 'deep'
}

export type PromptPart =
  | { type: 'text'; text: string }
  | { type: 'image'; path: string }
  | { type: 'image'; data: string; mimeType?: string }

export type Prompt = string | PromptPart[]

export interface Usage {
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningTokens: number
}

export interface ServerInfo {
  protocolVersion: number
  server: { name: string; version: string }
  os: { version: string }
  models: Record<ModelId, ModelStatus>
}

export interface SessionOptions {
  model?: ModelId
  /** System instructions that apply to the whole conversation. */
  instructions?: string
  guardrails?: 'default' | 'permissiveContentTransformations'
  useCase?: 'general' | 'contentTagging'
  /** Functions the model may call while responding. */
  // biome-ignore lint/suspicious/noExplicitAny: tools with different argument types
  tools?: Array<Tool<any>>
  signal?: AbortSignal
}

export interface CallOptions {
  /** Cancels the request. The promise rejects with `AbortError`. */
  signal?: AbortSignal
  /** Client-side timeout; rejects with `RequestTimeoutError` and cancels the request. */
  timeoutMs?: number
}

export type RespondOptions = GenerationOptions &
  CallOptions & {
    /** Whether the schema is also described in the prompt (default true). Only with `schema`. */
    includeSchemaInPrompt?: boolean
  }

/** Options that request structured output: the response is parsed and validated as `T`. */
export type StructuredOptions<T> = RespondOptions & { schema: SchemaInput<T> }

export interface StructuredResult<T> {
  /** Parsed and validated value. */
  content: T
  /** The same value as JSON text. */
  text: string
  usage?: Usage
}

export type StructuredStreamChunk<T> =
  | { done: false; partial: DeepPartial<T> }
  | { done: true; content: T; text: string; usage?: Usage }

export interface GenerateResult {
  text: string
  /** Tokens used by this request (macOS 27+). */
  usage?: Usage
}

export type StreamChunk =
  | {
      done: false
      /** Text appended since the previous chunk. Empty when `reset` is true. */
      delta: string
      /** Full text so far. */
      text: string
      /** The model rewrote earlier output; replace what you showed with `text`. */
      reset?: boolean
    }
  | { done: true; delta: ''; text: string; usage?: Usage }

export interface SessionInfo {
  model: ModelId
  contextSize: number
  isResponding: boolean
  /** Tokens currently occupied by the conversation history (macOS 26.4+). */
  historyTokenCount?: number
  /** Cumulative usage of the session (macOS 27+). */
  usage?: Usage
}
