/**
 * A transport starts the sidecar and moves NDJSON lines in both directions.
 * Implement it to run the sidecar somewhere else (for example behind Electron IPC).
 */
export interface Transport {
  /** Starts a new sidecar process. Called again after a crash to restart it. */
  connect(handlers: TransportHandlers): Promise<Connection>
}

export interface TransportHandlers {
  /** One complete protocol line from the sidecar's stdout, without the trailing newline. */
  onMessage(line: string): void
  /** The connection ended (process exited). Called exactly once. */
  onClose(info: CloseInfo): void
  /** One line of the sidecar's stderr log. */
  onLog?(line: string): void
}

export interface CloseInfo {
  code: number | null
  signal: string | null
  error?: Error
}

export interface Connection {
  /** Sends one protocol line. The transport appends the newline. */
  send(line: string): void
  /** Ends the connection gracefully (close stdin, wait, then kill). Resolves when the process is gone. */
  close(): Promise<void>
  /**
   * Hint from the client: `true` while requests are in flight. Node transports use it to
   * keep the event loop alive only while needed, so an idle sidecar never blocks process exit.
   */
  setActive?(active: boolean): void
}

/** Splits a stream of text chunks into lines. Handles `\n` and `\r\n`. */
export function createLineSplitter(onLine: (line: string) => void): {
  push(chunk: string): void
  flush(): void
} {
  let buffer = ''
  return {
    push(chunk) {
      buffer += chunk
      let index = buffer.indexOf('\n')
      while (index !== -1) {
        const line = buffer.slice(0, index).replace(/\r$/, '')
        buffer = buffer.slice(index + 1)
        if (line.length > 0) onLine(line)
        index = buffer.indexOf('\n')
      }
    },
    flush() {
      const rest = buffer.replace(/\r$/, '')
      buffer = ''
      if (rest.length > 0) onLine(rest)
    },
  }
}
