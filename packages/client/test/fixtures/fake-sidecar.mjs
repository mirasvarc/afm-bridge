#!/usr/bin/env node
// Minimal stand-in for afm-bridge-server used by node-transport.test.ts.
import { createInterface } from 'node:readline'

const write = (m) => process.stdout.write(`${JSON.stringify(m)}\n`)
process.stderr.write(`fake sidecar started ${process.env.AFM_BRIDGE_LOG}\n`)

const rl = createInterface({ input: process.stdin })
rl.on('line', (line) => {
  const { id, method, params } = JSON.parse(line)
  switch (method) {
    case 'initialize':
      return write({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: 1,
          server: { name: 'afm-bridge-server', version: 'fake' },
          os: { version: '27.0' },
          models: {
            'on-device': { available: true, contextSize: 8192, capabilities: [], supportedLanguages: ['en'] },
          },
        },
      })
    case 'session/create':
      return write({ jsonrpc: '2.0', id, result: { sessionId: 'a', contextSize: 8192 } })
    case 'session/respond': {
      // Split one message across two writes to exercise line framing.
      const delta = JSON.stringify({
        jsonrpc: '2.0',
        method: 'session/delta',
        params: { requestId: id, delta: 'Hel' },
      })
      process.stdout.write(delta.slice(0, 10))
      setTimeout(() => {
        process.stdout.write(`${delta.slice(10)}\n`)
        write({ jsonrpc: '2.0', method: 'session/delta', params: { requestId: id, delta: 'lo' } })
        write({ jsonrpc: '2.0', id, result: { text: `Hello (${params.prompt})` } })
      }, 5)
      return
    }
    case 'crash':
      process.stderr.write('about to crash\n')
      process.exit(3)
      return
    case 'shutdown':
      write({ jsonrpc: '2.0', id, result: {} })
      process.exit(0)
      return
  }
})
rl.on('close', () => {
  process.stderr.write('stdin closed\n')
  process.exit(0)
})
