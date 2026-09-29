#!/usr/bin/env node
// Usage:
//   node chat.mjs "Write a haiku about the sea"   one-shot, streamed to stdout
//   node chat.mjs                                 interactive chat (history is kept)
import { createInterface } from 'node:readline/promises'
import { AppleFoundationModels } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'

const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })

const status = await afm.availability()
if (!status.available) {
  console.error(`The on-device model is unavailable (${status.reason}): ${status.message}`)
  await afm.close()
  process.exit(1)
}

const session = await afm.createSession({ instructions: 'You are a helpful assistant. Answer concisely.' })

// Ctrl+C cancels the current answer; a second Ctrl+C quits.
let controller
process.on('SIGINT', () => {
  if (controller && !controller.signal.aborted) controller.abort()
  else afm.close().then(() => process.exit(130))
})

async function ask(prompt) {
  controller = new AbortController()
  try {
    for await (const chunk of session.stream(prompt, { signal: controller.signal })) {
      if (chunk.done) {
        if (chunk.usage)
          console.error(`\n[${chunk.usage.inputTokens} in / ${chunk.usage.outputTokens} out tokens]`)
        else process.stdout.write('\n')
      } else {
        process.stdout.write(chunk.reset ? `\n${chunk.text}` : chunk.delta)
      }
    }
  } catch (error) {
    if (error.name === 'AbortError') console.error('\n[cancelled]')
    else console.error(`\n${error.name}: ${error.message}`)
  } finally {
    controller = undefined
  }
}

const oneShot = process.argv.slice(2).join(' ')
if (oneShot) {
  await ask(oneShot)
} else {
  console.error(
    `Chatting with ${status.variant ?? 'the on-device model'} (context ${status.contextSize} tokens). Empty line quits.`,
  )
  const rl = createInterface({ input: process.stdin, output: process.stderr, prompt: '\n> ' })
  let inputClosed = false
  rl.on('close', () => {
    inputClosed = true
  })
  rl.prompt()
  for await (const line of rl) {
    const prompt = line.trim()
    if (!prompt) break
    await ask(prompt)
    const info = await session.info()
    if (info.historyTokenCount !== undefined) {
      console.error(`[history ${info.historyTokenCount}/${info.contextSize} tokens]`)
    }
    if (!inputClosed) rl.prompt()
  }
  rl.close()
}

await afm.close()
