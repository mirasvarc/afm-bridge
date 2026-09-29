// Exposes a small, safe API to the renderer. Sandboxed preloads must be CommonJS.
const { contextBridge, ipcRenderer } = require('electron')

let nextId = 1

contextBridge.exposeInMainWorld('afm', {
  availability: () => ipcRenderer.invoke('afm:availability'),

  /**
   * Streams an answer. `onChunk` receives `{ delta, text, reset? }` while it is generated.
   * Returns `{ id, result }`; `result` resolves to `{ ok: true, text, usage? }` or `{ ok: false, error }`.
   */
  ask(prompt, onChunk) {
    const id = nextId++
    const listener = (_event, chunk) => {
      if (chunk.id === id) onChunk(chunk)
    }
    ipcRenderer.on('afm:chunk', listener)
    const result = ipcRenderer
      .invoke('afm:ask', { id, prompt })
      .finally(() => ipcRenderer.removeListener('afm:chunk', listener))
    return { id, result }
  },

  cancel: (id) => ipcRenderer.send('afm:cancel', id),
  reset: () => ipcRenderer.invoke('afm:reset'),
})
