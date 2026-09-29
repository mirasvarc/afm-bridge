// Renderer: no Node access, only the `window.afm` API from preload.cjs.
const $ = (id) => document.getElementById(id)
const log = $('log')
const promptInput = $('prompt')
let current // { id, result } of the running request

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
  const status = await window.afm.availability()
  if (status.available) {
    $('status').textContent =
      `${status.variant ?? 'Apple on-device model'} · context ${status.contextSize} tokens`
    $('send').disabled = false
  } else {
    // Typed reason, e.g. appleIntelligenceNotEnabled or unsupportedPlatform.
    $('status').textContent = `Unavailable (${status.reason}): ${status.message}`
  }
  return status
}

/** Sends a prompt and streams the answer into the log. Resolves with the final text. */
async function ask(prompt) {
  addMessage('user', prompt)
  const answer = addMessage('assistant')
  setBusy(true)
  current = window.afm.ask(prompt, (chunk) => {
    answer.textContent = chunk.text
    log.scrollTop = log.scrollHeight
  })
  const result = await current.result
  current = undefined
  setBusy(false)
  if (!result.ok) {
    const { name, message } = result.error
    addMessage('error', name === 'AbortError' ? 'Stopped.' : `${name}: ${message}`)
    throw Object.assign(new Error(message), result.error)
  }
  answer.textContent = result.text
  if (result.usage) {
    const meta = document.createElement('span')
    meta.className = 'meta'
    meta.textContent = `\n${result.usage.inputTokens} in / ${result.usage.outputTokens} out tokens`
    answer.append(meta)
  }
  return result.text
}

$('form').addEventListener('submit', (event) => {
  event.preventDefault()
  const prompt = promptInput.value.trim()
  if (!prompt || current) return
  promptInput.value = ''
  ask(prompt).catch(() => {})
})

promptInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault()
    $('form').requestSubmit()
  }
})

$('stop').addEventListener('click', () => current && window.afm.cancel(current.id))

$('reset').addEventListener('click', async () => {
  await window.afm.reset()
  log.replaceChildren()
})

const ready = checkAvailability().catch((error) => {
  $('status').textContent = `Error: ${error.message}`
})

// Used by `AFM_EXAMPLE_SELFTEST=1`: exercises IPC, streaming and conversation memory.
window.selfTest = async () => {
  await ready
  const status = await window.afm.availability()
  if (!status.available) throw new Error(`model unavailable: ${status.reason}`)
  await ask('My name is Ada. Reply with one short sentence.')
  const answer = await ask('What is my name? Answer with just the name.')
  if (!/ada/i.test(answer)) throw new Error(`conversation memory failed, got: ${answer}`)
  return answer
}
