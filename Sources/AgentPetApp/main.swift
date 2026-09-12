import AppKit

// A pet has no dock presence and no windows of its own to open, so `.accessory`
// is the right activation policy: it appears in the menu bar and nowhere else.
let application = NSApplication.shared

if CommandLine.arguments.contains("--diagnose") {
    application.setActivationPolicy(.prohibited)
    exit(Diagnose.run())
}

application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
