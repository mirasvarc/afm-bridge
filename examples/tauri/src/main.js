// Tauri frontend: afm-bridge runs directly in the webview and starts the sidecar
// through the shell plugin. No Rust code is needed for the model itself.
import { invoke } from '@tauri-apps/api/core'
import { AppleFoundationModels, SessionLostError } from 'afm-bridge'
import { TauriSidecarTransport } from 'afm-bridge/tauri'

const afm = new AppleFoundationModels({
  transport: new TauriSidecarTransport(),
  onLog: (line) => console.warn(`[afm-bridge-server] ${line}`),
})

const $ = (id) => document.getElementById(id)
const log = $('log')
const promptInput = $('prompt')
let session // Promise<Session>, one conversation at a time
let controller // AbortController of the running answer

function getSession() {
  session ??= afm.createSession({ instructions: 'You are a helpful assistant. Answer concisely.' })
  return session
}

function addMessage(kind, text = '') {
  const el = document.createElement('p')
  el.className = `message ${kind}`
  el.textContent = text
  log.append(el)
  log.scrollTop = log.scrollHeight
  return el
}

function setBusy(busy) {
  $('send').disabled = busy
  $('stop').disabled = !busy
  $('reset').disabled = busy
}

async function checkAvailability() {
  const status = await afm.availability()
  if (status.available) {
    $('status').textContent =
      `${status.variant ?? 'Apple on-device model'} · context ${status.contextSize} tokens`
    $('send').disabled = false
  } else {
    $('status').textContent = `Unavailable (${status.reason}): ${status.message}`
  }
  return status
}

/** Streams the answer into the log and resolves with the final text. */
async function ask(prompt) {
  addMessage('user', prompt)
  const answer = addMessage('assistant')
  setBusy(true)
  controller = new AbortController()
  try {
    const s = await getSession()
    for await (const chunk of s.stream(prompt, { signal: controller.signal })) {
      answer.textContent = chunk.text
      log.scrollTop = log.scrollHeight
      if (chunk.done && chunk.usage) {
        const meta = document.createElement('span')
        meta.className = 'meta'
        meta.textContent = `\n${chunk.usage.inputTokens} in / ${chunk.usage.outputTokens} out tokens`
        answer.append(meta)
      }
      if (chunk.done) return chunk.text
    }
  } catch (error) {
    // The sidecar crashed and was restarted: the next message starts a new conversation.
    if (error instanceof SessionLostError) session = undefined
    addMessage('error', error.name === 'AbortError' ? 'Stopped.' : `${error.name}: ${error.message}`)
    throw error
  } finally {
    controller = undefined
    setBusy(false)
  }
}

$('form').addEventListener('submit', (event) => {
  event.preventDefault()
  const prompt = promptInput.value.trim()
  if (!prompt || controller) return
  promptInput.value = ''
  ask(prompt).catch(() => {})
})

promptInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault()
    $('form').requestSubmit()
  }
})

$('stop').addEventListener('click', () => controller?.abort())

$('reset').addEventListener('click', async () => {
  const old = session
  session = undefined
  log.replaceChildren()
  await old?.then((s) => s.dispose()).catch(() => {})
})

const ready = checkAvailability().catch((error) => {
  $('status').textContent = `${error.name}: ${error.message}`
})

// `pnpm selftest` (AFM_EXAMPLE_SELFTEST=1) drives the UI once and exits, so the example
// can be checked from a terminal. The two commands live in src-tauri/src/main.rs.
if (await invoke('self_test_enabled')) {
  try {
    await ready
    const status = await afm.availability()
    if (!status.available) throw new Error(`model unavailable: ${status.reason}`)
    await ask('My name is Ada. Reply with one short sentence.')
    const answer = await ask('What is my name? Answer with just the name.')
    if (!/ada/i.test(answer)) throw new Error(`conversation memory failed, got: ${answer}`)
    await afm.close()
    await invoke('self_test_finished', { ok: true, message: answer })
  } catch (error) {
    await invoke('self_test_finished', { ok: false, message: `${error.name}: ${error.message}` })
  }
}
