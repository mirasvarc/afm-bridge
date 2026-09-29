import type { UnavailableReason } from './types.js'

export interface RpcErrorPayload {
  code: number
  message: string
  data?: Record<string, unknown> & { type?: string }
}

/** Base class of every error thrown by afm-bridge. `type` matches PROTOCOL.md section 7. */
export class AfmError extends Error {
  override name = 'AfmError'
  readonly type: string
  readonly code: number | undefined
  readonly data: Record<string, unknown>

  constructor(
    message: string,
    init: { type?: string; code?: number; data?: Record<string, unknown>; cause?: unknown } = {},
  ) {
    super(message, init.cause === undefined ? undefined : { cause: init.cause })
    this.type = init.type ?? 'generationFailed'
    this.code = init.code
    this.data = init.data ?? {}
  }
}

/** Framing, version or JSON-RPC level problem between client and sidecar. */
export class ProtocolError extends AfmError {
  override name = 'ProtocolError'
}
export class InvalidParamsError extends AfmError {
  override name = 'InvalidParamsError'
}
/** The request was cancelled through an `AbortSignal`. Has `name === 'AbortError'` like DOM aborts. */
export class AbortError extends AfmError {
  override name = 'AbortError'
  constructor(message = 'The operation was aborted', init: ConstructorParameters<typeof AfmError>[1] = {}) {
    super(message, { type: 'cancelled', code: -32800, ...init })
  }
}
export class ModelUnavailableError extends AfmError {
  override name = 'ModelUnavailableError'
  get reason(): UnavailableReason {
    return (this.data.reason as UnavailableReason | undefined) ?? 'unknown'
  }
}
export class UnsupportedOSError extends AfmError {
  override name = 'UnsupportedOSError'
}
export class SessionNotFoundError extends AfmError {
  override name = 'SessionNotFoundError'
}
/** Another `respond`/`stream` is already running in this session. */
export class SessionBusyError extends AfmError {
  override name = 'SessionBusyError'
}
export class ContextWindowExceededError extends AfmError {
  override name = 'ContextWindowExceededError'
  get contextSize(): number | undefined {
    return this.data.contextSize as number | undefined
  }
  get tokenCount(): number | undefined {
    return this.data.tokenCount as number | undefined
  }
}
export class GuardrailViolationError extends AfmError {
  override name = 'GuardrailViolationError'
}
export class RefusalError extends AfmError {
  override name = 'RefusalError'
}
export class UnsupportedLanguageError extends AfmError {
  override name = 'UnsupportedLanguageError'
  get languageCode(): string | undefined {
    return this.data.languageCode as string | undefined
  }
}
export class UnsupportedCapabilityError extends AfmError {
  override name = 'UnsupportedCapabilityError'
}
export class UnsupportedSchemaError extends AfmError {
  override name = 'UnsupportedSchemaError'
}
export class DecodingError extends AfmError {
  override name = 'DecodingError'
}
export class RateLimitedError extends AfmError {
  override name = 'RateLimitedError'
}
export class GenerationTimeoutError extends AfmError {
  override name = 'GenerationTimeoutError'
}
export class ToolExecutionError extends AfmError {
  override name = 'ToolExecutionError'
}
export class QuotaExceededError extends AfmError {
  override name = 'QuotaExceededError'
}
export class NetworkError extends AfmError {
  override name = 'NetworkError'
}
export class ServiceUnavailableError extends AfmError {
  override name = 'ServiceUnavailableError'
}

// Client-only errors (never sent over the wire).

/** The sidecar process died and could not be (re)started. */
export class SidecarCrashedError extends AfmError {
  override name = 'SidecarCrashedError'
}
/** The session lived in a sidecar process that has since crashed or been closed. Create a new one. */
export class SessionLostError extends AfmError {
  override name = 'SessionLostError'
}
/** Spawning the sidecar failed (binary missing, not executable, ...). */
export class TransportError extends AfmError {
  override name = 'TransportError'
}
/** The client-side `timeoutMs` elapsed. */
export class RequestTimeoutError extends AfmError {
  override name = 'RequestTimeoutError'
}
/** `close()` was called on the client. */
export class ClientClosedError extends AfmError {
  override name = 'ClientClosedError'
}

type ErrorClass = new (message: string, init: ConstructorParameters<typeof AfmError>[1]) => AfmError

const byType: Record<string, ErrorClass> = {
  parseError: ProtocolError,
  invalidRequest: ProtocolError,
  methodNotFound: ProtocolError,
  protocolVersionMismatch: ProtocolError,
  notInitialized: ProtocolError,
  invalidParams: InvalidParamsError,
  cancelled: AbortError,
  modelUnavailable: ModelUnavailableError,
  unsupportedOS: UnsupportedOSError,
  sessionNotFound: SessionNotFoundError,
  sessionBusy: SessionBusyError,
  contextWindowExceeded: ContextWindowExceededError,
  guardrailViolation: GuardrailViolationError,
  refusal: RefusalError,
  unsupportedLanguage: UnsupportedLanguageError,
  unsupportedCapability: UnsupportedCapabilityError,
  unsupportedSchema: UnsupportedSchemaError,
  decodingFailure: DecodingError,
  rateLimited: RateLimitedError,
  timeout: GenerationTimeoutError,
  toolExecution: ToolExecutionError,
  quotaExceeded: QuotaExceededError,
  networkFailure: NetworkError,
  serviceUnavailable: ServiceUnavailableError,
}

/** Builds the typed error for a JSON-RPC error object. Unknown types become a plain `AfmError`. */
export function errorFromRpc(payload: RpcErrorPayload): AfmError {
  const { type = 'unknown', ...data } = payload.data ?? {}
  if (type === 'assetsUnavailable') {
    return new ModelUnavailableError(payload.message, {
      type,
      code: payload.code,
      data: { ...data, reason: 'modelNotReady' },
    })
  }
  const Class = byType[type] ?? AfmError
  return new Class(payload.message, { type, code: payload.code, data })
}
