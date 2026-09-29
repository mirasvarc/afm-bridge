# afm-bridge Electron example

A chat window that streams answers from Apple's on-device model. afm-bridge runs in the
**main process** (it needs Node to start the sidecar); the renderer talks to it over IPC.

| File | Role |
| --- | --- |
| `main.js` | Creates `AppleFoundationModels`, one session per window, IPC handlers, closes the sidecar on quit |
| `preload.cjs` | Exposes `window.afm` (`availability`, `ask`, `cancel`, `reset`) to the sandboxed renderer |
| `renderer.js`, `index.html`, `style.css` | UI, no Node access |
| `electron-builder.yml` | Packaging with electron-builder |
| `forge.config.cjs` | Packaging with Electron Forge |
| `entitlements.mac.plist` | Hardened runtime entitlements |

## Run it

This example installs afm-bridge from packed tarballs with **npm**, exactly like an app that
installs it from the registry. (It is not part of the pnpm workspace: Electron Forge does not
support pnpm's default `node_modules` layout.)

```bash
# repository root
pnpm install
scripts/build-sidecar.sh     # builds the sidecar into packages/darwin-arm64/bin
pnpm build                   # builds the afm-bridge client
scripts/pack-local.sh        # packs both into examples/electron/vendor/*.tgz

cd examples/electron
npm install
npm start                    # opens the window
npm run selftest             # headless check: asks two questions, prints SELFTEST OK/FAILED, exits
```

After changing the client or the sidecar, run `scripts/pack-local.sh` and `npm install` again.

## Package the app

The sidecar must end up **outside `app.asar`** (a binary inside an archive cannot be executed).
Both configurations copy it to `Contents/Resources/afm-bridge-server`, which is the first place
`resolveSidecarPath()` looks in a packaged app, and exclude the duplicate in `node_modules`.

```bash
npm run dist:builder   # electron-builder -> out/builder/mac-arm64/AFM Bridge Example.app
npm run dist:forge     # Electron Forge   -> out/forge/AFM Bridge Example-darwin-arm64/AFM Bridge Example.app
```

electron-builder (`electron-builder.yml`):

```yaml
files:
  - "!node_modules/afm-bridge-darwin-arm64/**"
extraResources:
  - from: node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server
    to: afm-bridge-server
```

Electron Forge (`forge.config.cjs`):

```js
packagerConfig: {
  asar: true,
  extraResource: ['node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server'],
  ignore: [/^\/node_modules\/afm-bridge-darwin-arm64/],
}
```

Alternative for either tool: keep the package in `node_modules` and unpack it with
`asarUnpack: ["node_modules/afm-bridge-darwin-arm64/**"]`. `resolveSidecarPath()` rewrites
`app.asar` to `app.asar.unpacked` automatically.

With **pnpm** in your own app, add `afm-bridge-darwin-arm64` as a direct dependency (npm and
yarn hoist it automatically) so that `node_modules/afm-bridge-darwin-arm64` exists, and follow
the Forge docs for pnpm (`node-linker=hoisted`).

## Signing and notarization

The sidecar is a nested executable, so the host app signs it together with everything else:

- **Hardened runtime** on (`hardenedRuntime: true` / `osxSign.optionsForFile`).
- **Entitlements:** Electron needs `com.apple.security.cs.allow-jit`. The sidecar itself needs
  none; inheriting the app's entitlements is harmless.
- **Identity:** use a `Developer ID Application` certificate for distribution outside the App
  Store. For a local test, an `Apple Development` identity works:
  ```bash
  npx electron-builder --mac --dir -c.mac.identity="Apple Development: Your Name (TEAMID)"
  APPLE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" npm run dist:forge
  ```
- **Notarization** (needs Developer ID): electron-builder `mac.notarize: true` with
  `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`; Forge `packagerConfig.osxNotarize`.
- Check the result:
  ```bash
  codesign --verify --deep --strict "AFM Bridge Example.app"
  codesign -dv "AFM Bridge Example.app/Contents/Resources/afm-bridge-server"   # flags=...(runtime)
  AFM_EXAMPLE_SELFTEST=1 "AFM Bridge Example.app/Contents/MacOS/AFM Bridge Example"
  ```

Both packaged variants of this example were verified this way (signed with an Apple Development
identity, hardened runtime, self-test passing). Notarization was not tested.

## Notes

- **Stream ordering over IPC.** Electron does not order `webContents.send` messages against
  the reply of `ipcRenderer.invoke`, so the last chunk could arrive after the call resolved.
  `main.js` therefore returns the final text and usage in the `invoke` reply and uses
  `send` only for live display.
- **Quitting.** `main.js` calls `afm.close()` in `will-quit`. If the app is killed, the sidecar
  still exits on its own because its stdin closes (verified with `kill -9`).
- **Errors over IPC** lose their class; the example sends `name`, `type`, `message` and `data`.
