import AFMBridgeCore
import Foundation

// A write to a closed stdout must fail with an error we handle, not kill us silently.
signal(SIGPIPE, SIG_IGN)

let server = Server(engine: FoundationModelsEngine(), sink: StdoutSink(), onExit: { code in exit(code) })
Log.info("\(serverName) \(serverVersion) started, pid \(getpid())")

do {
  for try await line in FileHandle.standardInput.bytes.lines {
    await server.handle(line: line)
  }
} catch {
  Log.error("reading stdin failed: \(error)")
}
await server.handleEOF()
