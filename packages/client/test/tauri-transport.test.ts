import { afterEach, describe, expect, it, vi } from 'vitest'
import type { TransportHandlers } from '../src/index.js'
import { MockProcess } from './mock-sidecar.js'

// A fake of @tauri-apps/plugin-shell whose child is the in-memory mock sidecar.
type Listener = (payload: unknown) => void
class Emitter {
  private listeners = new Map<string, Listener[]>()
  on(event: string, listener: Listener) {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener])
    return this
  }
  emit(event: string, payload: unknown) {
    for (const l of this.listeners.get(event) ?? []) l(payload)
  }
}

const shell = vi.hoisted(() => ({
  spawned: [] as Array<{ program: string; options: unknown; process: unknown; killed: boolean }>,
  failSpawn: false,
  trailingNewline: false,
}))

vi.mock('@tauri-apps/plugin-shell', () => {
  class Command extends Emitter {
    stdout = new Emitter()
    stderr = new Emitter()
    constructor(
      readonly program: string,
      readonly options: unknown,
    ) {
      super()
    }
    static sidecar(program: string, _args: string[], options: unknown) {
      return new Command(program, options)
    }
    async spawn() {
      if (shell.failSpawn) throw 'Scoped command binaries/afm-bridge-server not found'
      const nl = shell.trailingNewline ? '\n' : ''
      const handlers: TransportHandlers = {
        onMessage: (line) => this.stdout.emit('data', line + nl),
        onLog: (line) => this.stderr.emit('data', line + nl),
        onClose: ({ code }) => this.emit('close', { code, signal: null }),
      }
      const process = new MockProcess({}, handlers)
      const record = { program: this.program, options: this.options, process, killed: false }
      shell.spawned.push(record)
      return {
        pid: 1,
        write: async (data: string) => {
          expect(data.endsWith('\n')).toBe(true)
          process.connection.send(data.trimEnd())
        },
        kill: async () => {
          record.killed = true
          process.crash(0)
        },
      }
    }
  }
  return { Command }
})

const { AppleFoundationModels, TransportError } = await import('../src/index.js')
const { TauriSidecarTransport } = await import('../src/tauri/index.js')

describe('TauriSidecarTransport', () => {
  afterEach(() => {
    shell.spawned.length = 0
    shell.failSpawn = false
    shell.trailingNewline = false
    Reflect.deleteProperty(globalThis, 'window')
  })

  it.each([false, true])(
    'talks to the sidecar through the shell plugin (trailing newline: %s)',
    async (nl) => {
      shell.trailingNewline = nl
      const afm = new AppleFoundationModels({ transport: new TauriSidecarTransport({ logLevel: 'debug' }) })
      const session = await afm.createSession()
      const chunks: string[] = []
      for await (const chunk of session.stream('x')) chunks.push(chunk.text)
      expect(chunks.at(-1)).toBe('Hello!')
      expect(shell.spawned[0]?.program).toBe('binaries/afm-bridge-server')
      expect(shell.spawned[0]?.options).toEqual({ env: { AFM_BRIDGE_LOG: 'debug' } })
      await afm.close()
      const process = shell.spawned[0]?.process as MockProcess
      expect(process.requests('shutdown')).toHaveLength(1)
      expect(process.alive).toBe(false)
    },
  )

  it('explains a failed spawn', async () => {
    shell.failSpawn = true
    const afm = new AppleFoundationModels({ transport: new TauriSidecarTransport() })
    const error = await afm.serverInfo().catch((e) => e)
    expect(error).toBeInstanceOf(TransportError)
    expect(error.message).toContain('externalBin')
  })

  it('kills the sidecar when the page is hidden (reload, HMR)', async () => {
    const fakeWindow = new EventTarget()
    Object.assign(globalThis, { window: fakeWindow })
    const afm = new AppleFoundationModels({ transport: new TauriSidecarTransport() })
    await afm.serverInfo()
    fakeWindow.dispatchEvent(new Event('pagehide'))
    await vi.waitFor(() => expect(shell.spawned[0]?.killed).toBe(true))
  })
})
