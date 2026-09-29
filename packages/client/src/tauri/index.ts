import { type Child, Command } from '@tauri-apps/plugin-shell'
import { TransportError } from '../errors.js'
import type { Connection, Transport, TransportHandlers } from '../transport.js'

export interface TauriSidecarTransportOptions {
  /**
   * Sidecar name as listed in `tauri.conf.json > bundle > externalBin` (without the
   * target-triple suffix). Default `binaries/afm-bridge-server`.
   */
  program?: string
  args?: string[]
  /** Extra environment variables for the sidecar. */
  env?: Record<string, string>
  /** Sidecar log level (stderr). Default `warn`. */
  logLevel?: 'error' | 'warn' | 'info' | 'debug'
  /** How long `close()` waits for the sidecar to exit after `shutdown` before killing it. Default 2000 ms. */
  shutdownTimeoutMs?: number
  /**
   * Kill the sidecar when the page goes away (reload, dev-server HMR, navigation).
   * The Rust side keeps the process alive across reloads otherwise. Default true.
   */
  killOnPageHide?: boolean
}

/**
 * Runs the sidecar through Tauri's shell plugin, straight from the webview.
 * Requires `@tauri-apps/plugin-shell` and the capabilities described in the README.
 */
export class TauriSidecarTransport implements Transport {
  constructor(private readonly options: TauriSidecarTransportOptions = {}) {}

  async connect(handlers: TransportHandlers): Promise<Connection> {
    const program = this.options.program ?? 'binaries/afm-bridge-server'
    const command = Command.sidecar(program, this.options.args ?? [], {
      env: { AFM_BRIDGE_LOG: this.options.logLevel ?? 'warn', ...this.options.env },
    })

    let exited = false
    let resolveExit = () => {}
    const exit = new Promise<void>((resolve) => {
      resolveExit = resolve
    })
    command.on('close', ({ code, signal }) => {
      exited = true
      removePageHide()
      handlers.onClose({ code, signal: signal === null ? null : String(signal) })
      resolveExit()
    })
    command.on('error', (error) => handlers.onLog?.(`[tauri shell] ${error}`))
    // The shell plugin emits one event per line; tolerate a trailing newline either way.
    command.stdout.on('data', (data) => forEachLine(data, handlers.onMessage))
    command.stderr.on('data', (data) => forEachLine(data, (line) => handlers.onLog?.(line)))

    let child: Child
    try {
      child = await command.spawn()
    } catch (error) {
      throw new TransportError(
        `Could not start sidecar '${program}': ${error}. Check bundle.externalBin in tauri.conf.json, the binary name suffix (-aarch64-apple-darwin) and the shell:allow-spawn capability.`,
        { type: 'transportError', cause: error },
      )
    }

    const onPageHide = () => {
      if (!exited) void child.kill()
    }
    const removePageHide = () => {
      if (typeof window !== 'undefined') window.removeEventListener('pagehide', onPageHide)
    }
    if ((this.options.killOnPageHide ?? true) && typeof window !== 'undefined') {
      window.addEventListener('pagehide', onPageHide)
    }

    const shutdownTimeoutMs = this.options.shutdownTimeoutMs ?? 2000
    return {
      send(line) {
        if (exited) return
        child
          .write(`${line}\n`)
          .catch((error: unknown) => handlers.onLog?.(`[tauri shell] write failed: ${error}`))
      },
      async close() {
        removePageHide()
        if (exited) return
        // The client sends `shutdown` first, so the sidecar is normally already exiting.
        const timedOut = await Promise.race([
          exit.then(() => false),
          new Promise<boolean>((resolve) => setTimeout(() => resolve(true), shutdownTimeoutMs)),
        ])
        if (timedOut && !exited) await child.kill()
      },
    }
  }
}

function forEachLine(data: string, onLine: (line: string) => void) {
  for (const line of data.split(/\r?\n/)) {
    if (line.length > 0) onLine(line)
  }
}
