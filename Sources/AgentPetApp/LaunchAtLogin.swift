import Foundation
import ServiceManagement

/// Registers the app to start at login.
///
/// `SMAppService.mainApp` identifies the app by its bundle, so this only works
/// from a real `.app`. Running from `swift run` there is no bundle to register,
/// and the failure is reported rather than swallowed so the settings pane can
/// explain why the toggle will not stick.
enum LaunchAtLogin {

    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS is waiting for the user to approve it.
        case requiresApproval
        case notBundled
        case failed(String)

        var isOn: Bool { self == .enabled }

        var explanation: String? {
            switch self {
            case .enabled:
                return nil
            case .disabled:
                return nil
            case .requiresApproval:
                return "Approve Agent Pet Runtime in System Settings › General › Login Items."
            case .notBundled:
                return "Only available when running from an installed app bundle."
            case .failed(let message):
                return message
            }
        }
    }

    static var state: State {
        // A `swift run` binary has no bundle identifier, and the service would
        // throw rather than report a sensible status.
        guard Bundle.main.bundleIdentifier != nil else { return .notBundled }

        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .notRegistered:    return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notBundled
        @unknown default:       return .disabled
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        guard Bundle.main.bundleIdentifier != nil else { return .notBundled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        return state
    }
}
