// Electron main process. afm-bridge runs here (it needs Node to spawn the sidecar);
// the renderer talks to it over IPC through preload.cjs.
import { fileURLToPath } from 'node:url'
import { AppleFoundationModels, SessionLostError } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'
import { app, BrowserWindow, ipcMain } from 'electron'

// In a packaged app the binary is found in Contents/Resources (see electron-builder.yml
// and forge.config.cjs); during development it comes from node_modules.
const afm = new AppleFoundationModels({
  transport: new NodeStdioTransport(),
  onLog: (line) => console.error(`[afm-bridge-server] ${line}`),
})

/** One conversation per window, so the model remembers earlier messages. */
const sessions = new Map()
/** Running generations by request id, for cancellation. */
const running = new Map()

async function sessionFor(webContents) {
  let session = sessions.get(webContents.id)
  if (!session) {
    session = afm.createSession({ instructions: 'You are a helpful assistant. Answer concisely.' })
    sessions.set(webContents.id, session)
    webContents.once('destroyed', () => {
      sessions.delete(webContents.id)
      session.then((s) => s.dispose()).catch(() => {})
    })
  }
  try {
    return await session
  } catch (error) {
    sessions.delete(webContents.id)
    throw error
  }
}

/** Errors lose their class over IPC; send the fields the renderer needs. */
function serialize(error) {
  return { name: error.name, type: error.type, message: error.message, data: error.data }
}

ipcMain.handle('afm:availability', () => afm.availability())

ipcMain.handle('afm:ask', async (event, { id, prompt }) => {
  const controller = new AbortController()
  running.set(id, controller)
  try {
    const session = await sessionFor(event.sender)
    for await (const chunk of session.stream(prompt, { signal: controller.signal })) {
      // Chunks are for live display. Electron does not order `send` messages against
      // the `invoke` reply, so the final text and usage travel in the reply itself.
      if (chunk.done) return { ok: true, text: chunk.text, usage: chunk.usage }
      if (!event.sender.isDestroyed()) event.sender.send('afm:chunk', { id, ...chunk })
    }
    return { ok: true, text: '' }
  } catch (error) {
    // The sidecar crashed and was restarted: start a fresh conversation next time.
    if (error instanceof SessionLostError) sessions.delete(event.sender.id)
    return { ok: false, error: serialize(error) }
  } finally {
    running.delete(id)
  }
})

ipcMain.on('afm:cancel', (_event, id) => running.get(id)?.abort())

ipcMain.handle('afm:reset', async (event) => {
  const session = sessions.get(event.sender.id)
  sessions.delete(event.sender.id)
  await session?.then((s) => s.dispose()).catch(() => {})
})

function createWindow() {
  const win = new BrowserWindow({
    width: 760,
    height: 620,
    show: !process.env.AFM_EXAMPLE_SELFTEST,
    webPreferences: {
      preload: fileURLToPath(new URL('./preload.cjs', import.meta.url)),
      contextIsolation: true,
      sandbox: true,
    },
  })
  win.loadFile(fileURLToPath(new URL('./index.html', import.meta.url)))
  if (process.env.AFM_EXAMPLE_SELFTEST) runSelfTest(win)
}

// AFM_EXAMPLE_SELFTEST=1 drives the real UI once and exits, so the example can be
// checked from a terminal (also works on the packaged .app).
function runSelfTest(win) {
  win.webContents.once('did-finish-load', async () => {
    try {
      const text = await win.webContents.executeJavaScript('window.selfTest()')
      console.log(`SELFTEST OK: ${text}`)
      app.exitCode = 0
    } catch (error) {
      console.log(`SELFTEST FAILED: ${error.message}`)
      app.exitCode = 1
    }
    app.quit()
  })
}

app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())

// Stop the sidecar before quitting. (If the app is killed, the sidecar still exits
// on its own because its stdin closes.)
let closing = false
app.on('will-quit', (event) => {
  if (closing) return
  closing = true
  event.preventDefault()
  afm.close().finally(() => app.quit())
})
