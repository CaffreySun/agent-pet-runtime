import AppKit
import Darwin

// A pet has no dock presence and no windows of its own to open, so `.accessory`
// is the right activation policy: it appears in the menu bar and nowhere else.
let application = NSApplication.shared

if CommandLine.arguments.contains("--diagnose") {
    application.setActivationPolicy(.prohibited)
    exit(Diagnose.run())
}

// Headless operations, so everything the manager window does is also
// scriptable — and verifiable without a screen.
let headlessFlags = ["--status", "--configure", "--unconfigure", "--help", "-h", "--version"]
if headlessFlags.contains(where: { CommandLine.arguments.contains($0) }) {
    application.setActivationPolicy(.prohibited)
    exit(CommandLineTool.run(arguments: CommandLine.arguments))
}

application.setActivationPolicy(.accessory)

/// Asks for a working set of file descriptors.
///
/// A GUI process launched by launchd gets a soft limit of 256, and the bridge
/// holds one descriptor and one thread per agent connection. Under the limit
/// `accept` fails, which the bridge now survives — but surviving is worse than
/// not hitting it, and a pet watching twenty sessions across four agents should
/// not be the thing that finds the ceiling.
func raiseFileDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = min(limit.rlim_max, 4096)
    guard limit.rlim_cur < wanted else { return }
    limit.rlim_cur = wanted
    setrlimit(RLIMIT_NOFILE, &limit)
}

raiseFileDescriptorLimit()

let delegate = AppDelegate()
application.delegate = delegate
application.run()
