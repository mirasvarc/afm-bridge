// Electron Forge configuration. `pnpm dist:forge` builds out/forge/<name>-darwin-arm64/*.app
const identity = process.env.APPLE_SIGN_IDENTITY // e.g. "Developer ID Application: Name (TEAMID)"

module.exports = {
  outDir: 'out/forge',
  packagerConfig: {
    name: 'AFM Bridge Example',
    asar: true,
    // Copied to Contents/Resources/afm-bridge-server, where resolveSidecarPath() looks first.
    extraResource: ['node_modules/afm-bridge-darwin-arm64/bin/afm-bridge-server'],
    // Keep the duplicate copy out of app.asar and skip build output and tooling.
    ignore: [
      /^\/node_modules\/afm-bridge-darwin-arm64/,
      /^\/out/,
      /^\/forge\.config\.cjs$/,
      /^\/electron-builder\.yml$/,
    ],
    ...(identity && {
      osxSign: {
        identity,
        optionsForFile: () => ({ hardenedRuntime: true, entitlements: 'entitlements.mac.plist' }),
      },
    }),
  },
  makers: [{ name: '@electron-forge/maker-zip', platforms: ['darwin'] }],
}
