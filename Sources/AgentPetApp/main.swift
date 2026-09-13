import AppKit

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

let delegate = AppDelegate()
application.delegate = delegate
application.run()
