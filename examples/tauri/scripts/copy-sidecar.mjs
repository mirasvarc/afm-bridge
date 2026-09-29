// Copies the sidecar from the afm-bridge-darwin-arm64 package to where Tauri expects
// external binaries: src-tauri/binaries/<name>-<target triple>.
import { chmodSync, copyFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const source = createRequire(import.meta.url).resolve('afm-bridge-darwin-arm64/bin/afm-bridge-server')
const target = fileURLToPath(
  new URL('../src-tauri/binaries/afm-bridge-server-aarch64-apple-darwin', import.meta.url),
)
mkdirSync(fileURLToPath(new URL('../src-tauri/binaries/', import.meta.url)), { recursive: true })
copyFileSync(source, target)
chmodSync(target, 0o755)
console.log(`sidecar: ${target}`)
