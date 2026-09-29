# afm-bridge-darwin-arm64

Prebuilt `afm-bridge-server` sidecar for [afm-bridge](https://www.npmjs.com/package/afm-bridge)
(macOS 26+, Apple silicon). You do not install this package directly: `afm-bridge` lists it in
`optionalDependencies`, so npm installs it only on macOS arm64.
