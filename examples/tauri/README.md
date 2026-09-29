# afm-bridge Tauri 2 example

A chat window that streams answers from Apple's on-device model. afm-bridge runs **in the
webview** and starts the sidecar through Tauri's shell plugin (`TauriSidecarTransport`). The
Rust side only registers the plugin; no Rust code is needed for the model.

| File | Role |
| --- | --- |
| `src/main.js` | `AppleFoundationModels` + `TauriSidecarTransport`, UI logic |
| `src-tauri/tauri.conf.json` | `bundle.externalBin`, CSP, minimum macOS |
| `src-tauri/capabilities/default.json` | Shell permissions for the sidecar |
| `src-tauri/src/main.rs` | Registers `tauri-plugin-shell` (+ two self-test commands) |
| `scripts/copy-sidecar.mjs` | Copies the sidecar to `src-tauri/binaries/afm-bridge-server-aarch64-apple-darwin` |

## Run it

Needs Rust (`rustup`, target `aarch64-apple-darwin`). The Tauri CLI comes from npm.

```bash
# repository root
pnpm install
scripts/build-sidecar.sh     # builds the sidecar into packages/darwin-arm64/bin
pnpm build                   # builds the afm-bridge client

cd examples/tauri
pnpm dev                     # opens the window (first Rust build takes a minute)
pnpm selftest                # headless check: asks two questions, prints SELFTEST OK/FAILED, exits
pnpm build                   # src-tauri/target/release/bundle/macos/AFM Bridge Tauri Example.app
```

## Adding afm-bridge to your Tauri app

1. Install: `npm i afm-bridge @tauri-apps/plugin-shell` and `cargo add tauri-plugin-shell`
   (in `src-tauri`). Register the plugin: `.plugin(tauri_plugin_shell::init())`.
2. **Sidecar binary.** Tauri wants external binaries named with the target triple. Copy
   `node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server` to
   `src-tauri/binaries/afm-bridge-server-aarch64-apple-darwin` (see `scripts/copy-sidecar.mjs`;
   run it from `beforeDevCommand` / `beforeBuildCommand`) and declare it without the suffix:
   ```json
   "bundle": {
     "externalBin": ["binaries/afm-bridge-server"],
     "macOS": { "minimumSystemVersion": "26.0", "hardenedRuntime": true }
   }
   ```
   In the bundle it ends up at `Contents/MacOS/afm-bridge-server`.
3. **Capabilities.** Allow exactly this sidecar, plus writing to its stdin and killing it:
   ```json
   "permissions": [
     "core:default",
     { "identifier": "shell:allow-spawn",
       "allow": [{ "name": "binaries/afm-bridge-server", "sidecar": true, "args": false }] },
     "shell:allow-stdin-write",
     "shell:allow-kill"
   ]
   ```
4. **Use it in the frontend:**
   ```js
   import { AppleFoundationModels } from 'afm-bridge'
   import { TauriSidecarTransport } from 'afm-bridge/tauri'

   const afm = new AppleFoundationModels({ transport: new TauriSidecarTransport() })
   const session = await afm.createSession({ instructions: 'Answer briefly.' })
   for await (const chunk of session.stream('Write a haiku')) output.textContent = chunk.text
   ```
   `TauriSidecarTransport` takes `program` if you name the binary differently.

## Signing and notarization

`tauri build` signs the app and the sidecar when a signing identity is set, with the hardened
runtime from `bundle.macOS.hardenedRuntime`. The sidecar needs no entitlements.

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" pnpm build
# notarization: also set APPLE_ID, APPLE_PASSWORD (app-specific) and APPLE_TEAM_ID
codesign --verify --deep --strict "src-tauri/target/release/bundle/macos/AFM Bridge Tauri Example.app"
```

This example was verified with an `Apple Development` identity (signed sidecar with hardened
runtime, `LSMinimumSystemVersion` 26.0, self-test passing on the built app). Notarization was
not tested.

## Notes

- **Page reloads.** The sidecar process belongs to the Rust side and survives a webview reload
  (including dev-server HMR). `TauriSidecarTransport` kills it on `pagehide` so reloads do not
  pile up processes (`killOnPageHide: false` turns this off). Quitting the app, even with
  `kill -9`, leaves no sidecar behind (verified).
- **`tauri build` fails with "can't find crate for `phf_macros`" / "mis-aligned LINKEDIT
  string pool"** on Xcode 27: its `strip` corrupts proc-macro libraries built for macOS 26+.
  `src-tauri/Cargo.toml` keeps build scripts and proc macros unstripped:
  ```toml
  [profile.release.build-override]
  strip = "none"
  ```
