import Foundation

/// Whether the app was started to do something other than be a desktop pet.
///
/// No argument-free launch is ever headless, so the normal case is unaffected.
/// What this guards against is a diagnostic run — on a CI runner, or over ssh —
/// reaching a modal alert or an infinite loop that only a human could end.
enum HeadlessMode {

    /// Flags that mean "do the thing and exit".
    private static let nonInteractiveFlags = [
        "--diagnose",
        "--selftest",
        "--status",
        "--configure",
        "--unconfigure",
        "--version",
        "--help",
    ]

    static var isActive: Bool {
        CommandLine.arguments.contains { argument in
            nonInteractiveFlags.contains(argument)
        }
    }
}
