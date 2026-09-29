import { defineConfig } from 'vite'

// Tauri expects a fixed port and no screen clearing so its own output stays visible.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: 'safari18', outDir: 'dist' },
})
