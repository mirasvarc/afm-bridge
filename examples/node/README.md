# afm-bridge Node example

Streams answers from the on-device model in the terminal.

```bash
# from the repository root
pnpm install
scripts/build-sidecar.sh          # builds packages/darwin-arm64/bin/afm-bridge-server
pnpm --filter afm-bridge build

cd examples/node
node chat.mjs "Write a haiku about the sea."   # one-shot
node chat.mjs                                  # interactive chat, empty line quits
```

Ctrl+C cancels the current answer, a second Ctrl+C quits.

Requirements: macOS 26+ on Apple silicon with Apple Intelligence turned on. The model does not
support every language (Czech, for example, is not supported); `availability()` lists them.
