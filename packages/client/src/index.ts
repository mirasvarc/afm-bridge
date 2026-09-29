// Core entry point: no Node APIs, safe to import in a browser or webview.
export {
  AppleFoundationModels,
  type AppleFoundationModelsOptions,
  CLIENT_VERSION,
  PROTOCOL_VERSION,
} from './client.js'
export * from './errors.js'
export { Session } from './session.js'
export type { CloseInfo, Connection, Transport, TransportHandlers } from './transport.js'
export { createLineSplitter } from './transport.js'
export type * from './types.js'
