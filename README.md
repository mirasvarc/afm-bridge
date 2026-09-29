# afm-bridge

Apple's on-device language model ([Foundation Models](https://developer.apple.com/documentation/foundationmodels))
for JavaScript and TypeScript apps: **Electron**, **Tauri 2** and plain **Node.js**.

- Streaming responses, multi-turn sessions, cancellation with `AbortSignal`
- Structured output from JSON Schema or Zod, validated and typed
- Tool calling: the model calls your JavaScript functions
- Image input (macOS 27)
- Typed errors with a reason, for example when Apple Intelligence is turned off
- No native Node addon: a small Swift sidecar talks JSON-RPC over stdin/stdout, and the
  client is plain TypeScript with zero runtime dependencies

```ts
import { AppleFoundationModels } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'

const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })
const session = await afm.createSession({ instructions: 'Answer briefly.' })
for await (const chunk of session.stream('Write a haiku about the sea')) process.stdout.write(chunk.delta)
await afm.close()
```

## Requirements and limits

| | |
| --- | --- |
| Platform | macOS 26 or newer on Apple silicon. Intel Macs, Windows and Linux are not supported. |
| Apple Intelligence | Must be turned on in System Settings, and the model must be downloaded. |
| Context window | 8192 tokens on macOS 27, less on macOS 26 (4096 on 26.0 to 26.3), shared by instructions, history, prompt and answer. `availability()` reports the actual size. |
| Languages | 24 languages (English, German, French, Spanish, Italian, Portuguese, Japanese, Chinese, Korean, ...). Check `supportedLanguages`. **Czech, for example, is not supported.** |
| Model size | A small model: good at summarizing, extracting, classifying, rewriting and short generation. It is not a source of facts or world knowledge. |
| Guardrails | Apple's safety filters can reject prompts or answers (`GuardrailViolationError`). |
| Newer features | Image input, token usage, `toolCalling` and `reasoningLevel` options need macOS 27. |
| Private Cloud Compute | Not supported (needs a restricted Apple entitlement). `private-cloud` is always reported as unavailable. |

## Install

```bash
npm install afm-bridge
```

The prebuilt sidecar comes in `afm-bridge-darwin-arm64`, an optional dependency that npm
installs only on macOS arm64. With pnpm, add `afm-bridge-darwin-arm64` as a direct
dependency if you need its path at build time (Electron, Tauri). For structured output with
Zod, also install `zod` (version 4).

Entry points:

| Import | Use |
| --- | --- |
| `afm-bridge` | Client, sessions, errors, schema and tool helpers. No Node APIs, works in a webview. |
| `afm-bridge/node` | `NodeStdioTransport`, `resolveSidecarPath()` (Node, Electron main process) |
| `afm-bridge/tauri` | `TauriSidecarTransport` (Tauri webview, needs `@tauri-apps/plugin-shell`) |
| `afm-bridge/zod` | `zodSchema()` (needs `zod`) |

## Quick start: Electron

afm-bridge runs in the **main process**, where it can start the sidecar. The renderer talks
to it over IPC.

```js
// main.js
import { AppleFoundationModels } from 'afm-bridge'
import { NodeStdioTransport } from 'afm-bridge/node'
import { app, ipcMain } from 'electron'

const afm = new AppleFoundationModels({ transport: new NodeStdioTransport() })
const session = afm.createSession({ instructions: 'Answer briefly.' })

ipcMain.handle('ask', async (event, prompt) => {
  let text = ''
  for await (const chunk of (await session).stream(prompt)) {
    if (!chunk.done) event.sender.send('chunk', chunk.delta)
    text = chunk.text
  }
  return text // the final text travels in the reply: IPC does not order `send` against `invoke`
})

app.on('will-quit', () => afm.close())
```

**Packaging:** the sidecar must be outside `app.asar`. With electron-builder:

```yaml
files:
  - "!node_modules/afm-bridge-darwin-arm64/**"
extraResources:
  - from: node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server
    to: afm-bridge-server
mac:
  hardenedRuntime: true
```

`NodeStdioTransport` finds it at `Contents/Resources/afm-bridge-server` automatically.
Electron Forge (`extraResource`) and `asarUnpack` work too. The full example with preload,
renderer, both packagers and signing is in [examples/electron](examples/electron).

## Quick start: Tauri 2

afm-bridge runs **in the webview** and starts the sidecar through the shell plugin.

1. `npm install afm-bridge @tauri-apps/plugin-shell` and in `src-tauri`:
   `cargo add tauri-plugin-shell`, then register `.plugin(tauri_plugin_shell::init())`.
2. Copy `node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server` to
   `src-tauri/binaries/afm-bridge-server-aarch64-apple-darwin` (Tauri needs the target triple
   suffix; run the copy from `beforeDevCommand`/`beforeBuildCommand`) and declare it:
   ```json
   "bundle": {
     "externalBin": ["binaries/afm-bridge-server"],
     "macOS": { "minimumSystemVersion": "26.0", "hardenedRuntime": true }
   }
   ```
3. Allow exactly this sidecar in `src-tauri/capabilities/default.json`:
   ```json
   "permissions": [
     "core:default",
     { "identifier": "shell:allow-spawn",
       "allow": [{ "name": "binaries/afm-bridge-server", "sidecar": true, "args": false }] },
     "shell:allow-stdin-write",
     "shell:allow-kill"
   ]
   ```
4. Use it in the frontend:
   ```js
   import { AppleFoundationModels } from 'afm-bridge'
   import { TauriSidecarTransport } from 'afm-bridge/tauri'

   const afm = new AppleFoundationModels({ transport: new TauriSidecarTransport() })
   const session = await afm.createSession()
   for await (const chunk of session.stream('Write a haiku')) output.textContent = chunk.text
   ```

The full example, including a fix for `tauri build` on Xcode 27, is in
[examples/tauri](examples/tauri).

## Usage

### Availability

```ts
const status = await afm.availability()
if (!status.available) {
  // reason: 'appleIntelligenceNotEnabled' | 'modelNotReady' | 'deviceNotEligible'
  //       | 'unsupportedOS' | 'unsupportedPlatform' | ...
  console.log(status.reason, status.message)
} else {
  console.log(status.contextSize, status.supportedLanguages)
}
```

`availability()` never throws because the model is unavailable. Other calls throw
`ModelUnavailableError` with the same `reason`.

### Sessions

A session is one conversation; the sidecar keeps its history. Only one `respond` or
`stream` can run in a session at a time (a second one fails with `SessionBusyError`), but
many sessions can generate in parallel.

```ts
const session = await afm.createSession({
  instructions: 'You are a helpful assistant.',
  guardrails: 'default', // or 'permissiveContentTransformations'
})

const text = await session.respond('Summarize: ...', {
  temperature: 0.3,
  maximumResponseTokens: 200,
  sampling: { mode: 'topP', threshold: 0.9, seed: 42 }, // or { mode: 'greedy' } / { mode: 'topK', k: 40 }
})

const { text: answer, usage } = await session.generate('...') // usage: token counts (macOS 27)
const info = await session.info() // { contextSize, historyTokenCount, usage, isResponding }
await session.prewarm() // load the model ahead of the first prompt
await session.dispose()
```

### Streaming and cancellation

```ts
const controller = new AbortController()
for await (const chunk of session.stream('Tell me a story', { signal: controller.signal })) {
  if (chunk.done) console.log('\n', chunk.usage)
  else process.stdout.write(chunk.delta) // chunk.text holds the full text so far
}
```

Aborting rejects with `AbortError` and stops the generation in the sidecar; the session stays
usable. Breaking out of the loop cancels too. `timeoutMs` sets a client-side timeout for `respond`, `generate`, `stream` and the other calls that take options. In rare cases
the model rewrites earlier output: the chunk then has `reset: true` and `text` replaces what
you showed.

### Structured output

Pass a JSON Schema or a Zod schema. The model is constrained to the schema, and the result is
validated before it is returned.

```ts
import { zodSchema } from 'afm-bridge/zod'
import { z } from 'zod'

const Book = z.object({
  title: z.string(),
  year: z.number().int().min(1900).max(2030),
  genre: z.enum(['fantasy', 'mystery', 'other']),
  subtitle: z.string().nullable(),
})

const book = await session.respond('Invent a mystery novel', { schema: zodSchema(Book) }) // typed

for await (const chunk of session.stream('Invent a novel', { schema: zodSchema(Book) })) {
  if (!chunk.done) render(chunk.partial) // partial object while it streams
}
```

Plain JSON Schema works the same (`{ schema: { type: 'object', properties: ... } }`, or
`jsonSchema<T>(schema)` for a typed result). Supported: objects (`properties`, `required`,
`additionalProperties: false`), strings with `enum`, `const` and simple `pattern`, `integer`
and `number` with `minimum`/`maximum`, `boolean`, arrays with `items`/`minItems`/`maxItems`,
`anyOf`/`oneOf`, nullable properties, `$defs`/`$ref` including recursion. Anything else
(`maxLength`, `exclusiveMinimum`, ...) fails early with `UnsupportedSchemaError` and a JSON
pointer. The on-device model accepts only simple regex patterns (`\d{3}` works, `[a-z]+` does
not); `zodSchema()` therefore leaves out the regex Zod adds for `.email()` or `.uuid()` and lets
Zod check the format after generation.

### Tools

```ts
import { tool } from 'afm-bridge'

const getWeather = tool({
  name: 'getWeather',
  description: 'Get the current temperature for a city',
  parameters: zodSchema(z.object({ city: z.string() })),
  execute: async ({ city }, { signal }) => fetchWeather(city, { signal }), // any JSON value or string
})

const session = await afm.createSession({ tools: [getWeather] })
await session.respond('Is it warmer in Prague or in Oslo?') // may call getWeather twice
```

Arguments are validated before `execute` runs. A tool that throws or times out (`timeoutMs`,
default 60 s) fails the generation with `ToolExecutionError`. Cancelling the generation aborts
the tool's `signal`.

### Images (macOS 27)

```ts
await session.respond([
  { type: 'text', text: 'What is in this picture?' },
  { type: 'image', path: '/Users/me/photo.jpg' }, // or { type: 'image', data: base64 }
])
```

### Errors

Every error extends `AfmError` with a stable `type`, and `data` with details.

| Class | When |
| --- | --- |
| `ModelUnavailableError` | Model cannot be used; see `reason` |
| `ContextWindowExceededError` | Instructions, history and prompt do not fit (`contextSize`) |
| `GuardrailViolationError`, `RefusalError` | Safety filters rejected the prompt or answer |
| `UnsupportedLanguageError` | The prompt's language is not supported |
| `UnsupportedSchemaError` | The schema uses something outside the supported subset |
| `DecodingError` | The generated value did not validate (`data.path`) |
| `ToolExecutionError` | A tool threw, timed out or got invalid arguments |
| `SessionBusyError` | Another response is running in this session |
| `AbortError`, `RequestTimeoutError` | Cancelled by `signal` / `timeoutMs` |
| `UnsupportedOSError` | A feature needs a newer macOS |
| `SidecarCrashedError` | The sidecar stopped and could not be restarted |
| `SessionLostError` | The session belonged to a sidecar process that crashed; create a new session |
| `TransportError` | The sidecar binary was not found or could not start |

### Process lifecycle

The sidecar starts on the first call. If it crashes, the next call starts a new process
(at most 3 restarts per minute, configurable with `restart`); sessions of the crashed process
reject with `SessionLostError`. `close()` stops it. If your app exits or is killed without
`close()`, the sidecar notices that its stdin closed and exits as well. In Node, an idle sidecar
does not keep the process alive.

```ts
new AppleFoundationModels({
  transport: new NodeStdioTransport({ binaryPath, logLevel: 'debug' }),
  restart: { maxRestarts: 3, windowMs: 60_000 },
  requestTimeoutMs: 30_000,
  onLog: (line) => console.error(line), // sidecar logs (stderr)
})
```

`resolveSidecarPath()` looks for the binary in `AFM_BRIDGE_BINARY`, then
`process.resourcesPath` (packaged Electron app), then the `afm-bridge-darwin-arm64` package.

### Custom transports

`Transport` is a public interface: start the sidecar anywhere that can pass lines of text,
for example behind your own IPC layer. See `NodeStdioTransport` for a reference implementation.

## Signing and notarization

afm-bridge is a library; the host app signs the sidecar together with everything else:

- Sign the nested `afm-bridge-server` with your identity and **hardened runtime**. electron-builder,
  Electron Forge and `tauri build` do this when signing is configured.
- The sidecar needs **no entitlements**. Inheriting the app's entitlements is harmless.
- Notarize the app as usual (Developer ID). Details and verification commands are in the
  example READMEs.

## Build from source

Requires Xcode 27 (the sidecar uses the macOS 27 SDK, and runs on macOS 26+).

```bash
pnpm install
scripts/build-sidecar.sh          # release build to packages/darwin-arm64/bin, signed ad hoc
pnpm build                        # TypeScript client
# or just the sidecar:
swift build -c release --package-path swift
```

Point `NodeStdioTransport({ binaryPath })` or `AFM_BRIDGE_BINARY` at your build.

## Development

```
swift/                 Swift package: afm-bridge-server + AFMBridgeCore (protocol, schema conversion)
packages/client/       npm package afm-bridge
packages/darwin-arm64/ npm package with the prebuilt sidecar
examples/node/         chat, structured output and tool calling from the terminal
examples/electron/     Electron app (installed with npm from packed tarballs, see its README)
examples/tauri/        Tauri 2 app
```

```bash
pnpm lint            # Biome + swift format
pnpm test            # TypeScript unit tests (mock sidecar)
pnpm test:swift      # Swift unit tests
AFM_INTEGRATION=1 pnpm test   # also run tests against the real model
```

Release note: publish `afm-bridge-darwin-arm64` with `npm publish` (pnpm 8 drops the
executable bit of the binary) and `afm-bridge` with `pnpm publish` (rewrites `workspace:*`).

## License

MIT
