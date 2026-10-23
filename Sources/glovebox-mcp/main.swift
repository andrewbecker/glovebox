import GloveboxServer
import Foundation

// With SIGPIPE ignored, writing to a pipe whose reader has gone (a simctl that
// exited early, a closed stderr) fails with an error instead of killing the
// server.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
if CLI.wantsServer(arguments) {
    try await GloveboxServer.run()
} else {
    exit(await CLI.run(arguments).rawValue)
}
