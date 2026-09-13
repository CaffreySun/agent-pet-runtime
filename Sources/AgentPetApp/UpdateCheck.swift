import AgentPetCore
import Foundation

/// The app's only network request.
///
/// It reads the project's public release feed and nothing else: no identifiers,
/// no usage, no machine details — the same request any browser would make.
/// Everything else this app does stays on the machine.
enum UpdateCheck {

    struct Release: Sendable, Equatable {
        let version: String
        let page: URL
    }

    enum Outcome: Sendable, Equatable {
        case upToDate(current: String)
        case available(Release, current: String)
        case failed(String)
    }

    static let releasePage = "https://github.com/dncore/agent-pet-runtime/releases"

    /// The version of the running bundle, as the About panel shows it.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? DiagnosticsBundle.currentAppInfo().version
    }

    /// Asks GitHub what the latest release is.
    static func latestRelease(timeout: TimeInterval = 10) async -> Result<Release, Error> {
        guard let url = URL(string: "https://api.github.com/repos/dncore/agent-pet-runtime/releases/latest")
        else { return .failure(UpdateCheckError.badResponse) }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(UpdateCheckError.badResponse)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let link = object["html_url"] as? String,
                  let page = URL(string: link)
            else { return .failure(UpdateCheckError.badResponse) }

            return .success(Release(version: tag, page: page))
        } catch {
            return .failure(error)
        }
    }

    /// The whole decision, so the caller only has to present it.
    static func compare(latest: Release, current: String = currentVersion) -> Outcome {
        AppVersion.isNewer(latest.version, than: current)
            ? .available(latest, current: current)
            : .upToDate(current: current)
    }

    static func run(timeout: TimeInterval = 10) async -> Outcome {
        switch await latestRelease(timeout: timeout) {
        case .success(let release):
            return compare(latest: release)
        case .failure(let error):
            return .failed(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No network connection."
            case .timedOut:
                return "GitHub did not answer in time."
            default:
                return "Could not reach GitHub (\(urlError.code.rawValue))."
            }
        }
        return "\(error)"
    }
}

enum UpdateCheckError: Error, Equatable {
    case badResponse
}
