import { type ChildProcess, spawn } from 'node:child_process'
import { accessSync, constants, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { ModelUnavailableError, TransportError } from '../errors.js'
import { type Connection, createLineSplitter, type Transport, type TransportHandlers } from '../transport.js'

export interface NodeStdioTransportOptions {
  /** Path to `afm-bridge-server`. Default: `resolveSidecarPath()`. */
  binaryPath?: string
  args?: string[]
  /** Extra environment variables for the sidecar. */
  env?: Record<string, string | undefined>
  /** Sidecar log level (stderr). Default `warn`. */
  logLevel?: 'error' | 'warn' | 'info' | 'debug'
  /** How long `close()` waits for a graceful exit before killing. Default 2000 ms. */
  shutdownTimeoutMs?: number
}

/**
 * Runs the sidecar as a child process and talks over stdin/stdout.
 * Works in Electron's main process, plain Node and CLI tools.
 */
export class NodeStdioTransport implements Transport {
  constructor(private readonly options: NodeStdioTransportOptions = {}) {}

  async connect(handlers: TransportHandlers): Promise<Connection> {
    assertSupportedPlatform()
    const binary = this.options.binaryPath ?? resolveSidecarPath()
    const child = spawn(binary, this.options.args ?? [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, AFM_BRIDGE_LOG: this.options.logLevel ?? 'warn', ...this.options.env },
    })

    await new Promise<void>((resolve, reject) => {
      child.once('spawn', resolve)
      child.once('error', (error) =>
        reject(
          new TransportError(`Could not start afm-bridge-server at ${binary}: ${error.message}`, {
            type: 'transportError',
            cause: error,
          }),
        ),
      )
    })

    let exited = false
    const exit = new Promise<void>((resolve) => {
      child.once('close', (code, signal) => {
        exited = true
        stdout.flush()
        stderr.flush()
        handlers.onClose({ code, signal })
        resolve()
      })
    })
    // Errors after spawn (e.g. EPIPE on a dead process) surface through 'close'.
    child.on('error', () => {})
    child.stdin?.on('error', () => {})

    const stdout = createLineSplitter((line) => handlers.onMessage(line))
    const stderr = createLineSplitter((line) => handlers.onLog?.(line))
    child.stdout?.setEncoding('utf8').on('data', (chunk: string) => stdout.push(chunk))
    child.stderr?.setEncoding('utf8').on('data', (chunk: string) => stderr.push(chunk))

    const shutdownTimeoutMs = this.options.shutdownTimeoutMs ?? 2000
    return {
      send(line) {
        if (!exited && child.stdin?.writable) child.stdin.write(`${line}\n`)
      },
      async close() {
        if (exited) return
        setActive(child, true)
        child.stdin?.end()
        if (await settlesWithin(exit, shutdownTimeoutMs)) return
        child.kill('SIGTERM')
        if (await settlesWithin(exit, 1000)) return
        child.kill('SIGKILL')
        await exit
      },
      setActive(active) {
        if (!exited) setActive(child, active)
      },
    }
  }
}

/**
 * Finds the `afm-bridge-server` binary. Order:
 * 1. `AFM_BRIDGE_BINARY` environment variable
 * 2. Packaged Electron app: `<app>/Contents/Resources/afm-bridge-server` (`process.resourcesPath`)
 * 3. The `afm-bridge-darwin-arm64` package (with `app.asar` rewritten to `app.asar.unpacked`)
 */
export function resolveSidecarPath(): string {
  const tried: string[] = []
  const usable = (candidate: string) => {
    tried.push(candidate)
    try {
      accessSync(candidate, constants.X_OK)
      return true
    } catch {
      return false
    }
  }

  const fromEnv = process.env.AFM_BRIDGE_BINARY
  if (fromEnv) {
    if (usable(fromEnv)) return fromEnv
    throw notFound(tried, 'AFM_BRIDGE_BINARY points to a file that does not exist or is not executable.')
  }

  const resourcesPath = (process as { resourcesPath?: string }).resourcesPath
  if (resourcesPath) {
    const packaged = join(resourcesPath, 'afm-bridge-server')
    if (usable(packaged)) return packaged
  }

  try {
    const fromPackage = createRequire(import.meta.url).resolve(
      'afm-bridge-darwin-arm64/bin/afm-bridge-server',
    )
    const unpacked = fromPackage.replace(/app\.asar([\\/])/, 'app.asar.unpacked$1')
    if (unpacked !== fromPackage && usable(unpacked)) return unpacked
    if (usable(fromPackage)) return fromPackage
  } catch {
    // Package not installed (not on macOS arm64, or optional dependencies were skipped).
  }

  throw notFound(tried)
}

function notFound(tried: string[], hint?: string): TransportError {
  return new TransportError(
    [
      'afm-bridge-server binary not found.',
      hint,
      tried.length > 0 ? `Tried: ${tried.join(', ')}.` : undefined,
      'Fix: install afm-bridge-darwin-arm64 (npm adds it automatically on Apple silicon), build it with `swift build -c release` and pass `binaryPath`, or set AFM_BRIDGE_BINARY.',
    ]
      .filter(Boolean)
      .join(' '),
    { type: 'transportError' },
  )
}

/** Throws `ModelUnavailableError` on platforms where the sidecar cannot run. */
function assertSupportedPlatform() {
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    throw new ModelUnavailableError(
      `Apple Foundation Models need macOS on Apple silicon (this is ${process.platform}/${process.arch})`,
      { type: 'modelUnavailable', data: { model: 'on-device', reason: 'unsupportedPlatform' } },
    )
  }
  const version = macOSVersion()
  if (version !== undefined && version < 26) {
    throw new ModelUnavailableError(
      `Apple Foundation Models need macOS 26 or newer (this is macOS ${version})`,
      {
        type: 'modelUnavailable',
        data: { model: 'on-device', reason: 'unsupportedOS' },
      },
    )
  }
}

function macOSVersion(): number | undefined {
  try {
    const plist = readFileSync('/System/Library/CoreServices/SystemVersion.plist', 'utf8')
    const match = /<key>ProductVersion<\/key>\s*<string>(\d+)/.exec(plist)
    return match?.[1] ? Number(match[1]) : undefined
  } catch {
    return undefined
  }
}

function setActive(child: ChildProcess, active: boolean) {
  for (const handle of [child, child.stdin, child.stdout, child.stderr] as Array<{
    ref?: () => void
    unref?: () => void
  } | null>) {
    if (active) handle?.ref?.()
    else handle?.unref?.()
  }
}

async function settlesWithin(promise: Promise<void>, ms: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(false), ms)
  })
  const result = await Promise.race([promise.then(() => true), timeout])
  clearTimeout(timer)
  return result
}
