import { chmodSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { AppleFoundationModels, SidecarCrashedError, TransportError } from '../src/index.js'
import { NodeStdioTransport, resolveSidecarPath } from '../src/node/index.js'

const fake = fileURLToPath(new URL('./fixtures/fake-sidecar.mjs', import.meta.url))
const onMacArm = process.platform === 'darwin' && process.arch === 'arm64'

beforeAll(() => chmodSync(fake, 0o755))

describe.runIf(onMacArm)('NodeStdioTransport', () => {
  let afm: AppleFoundationModels | undefined
  afterEach(async () => {
    await afm?.close()
    afm = undefined
  })

  it('runs a full exchange over stdio, including split lines and stderr logs', async () => {
    const logs: string[] = []
    afm = new AppleFoundationModels({
      transport: new NodeStdioTransport({ binaryPath: fake, logLevel: 'debug' }),
      onLog: (l) => logs.push(l),
    })
    const session = await afm.createSession()
    const deltas: string[] = []
    let final = ''
    for await (const chunk of session.stream('hi')) {
      if (chunk.done) final = chunk.text
      else deltas.push(chunk.delta)
    }
    expect(deltas).toEqual(['Hel', 'lo'])
    expect(final).toBe('Hello (hi)')
    expect(logs).toContain('fake sidecar started debug')
  })

  it('detects a crash and restarts on the next call', async () => {
    afm = new AppleFoundationModels({ transport: new NodeStdioTransport({ binaryPath: fake }) })
    await afm.serverInfo()
    // biome-ignore lint/suspicious/noExplicitAny: reach into the client to trigger a crash
    const live = (afm as any).live
    const error = await live.peer.request('crash', {}).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(SidecarCrashedError)
    expect((error as Error).message).toContain('exit code 3')
    expect((error as Error).message).toContain('about to crash')
    await expect(afm.serverInfo()).resolves.toMatchObject({ server: { version: 'fake' } })
  })

  it('reports a missing binary as TransportError', async () => {
    afm = new AppleFoundationModels({
      transport: new NodeStdioTransport({ binaryPath: '/nonexistent/afm-bridge-server' }),
    })
    await expect(afm.serverInfo()).rejects.toBeInstanceOf(TransportError)
  })
})

describe('resolveSidecarPath', () => {
  const saved = process.env.AFM_BRIDGE_BINARY
  afterEach(() => {
    if (saved === undefined) delete process.env.AFM_BRIDGE_BINARY
    else process.env.AFM_BRIDGE_BINARY = saved
  })

  it('uses AFM_BRIDGE_BINARY when set', () => {
    process.env.AFM_BRIDGE_BINARY = fake
    expect(resolveSidecarPath()).toBe(fake)
  })

  it('explains what to do when AFM_BRIDGE_BINARY is wrong', () => {
    process.env.AFM_BRIDGE_BINARY = '/nope/afm-bridge-server'
    expect(() => resolveSidecarPath()).toThrow(/AFM_BRIDGE_BINARY points to a file/)
  })
})
