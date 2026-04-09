import Foundation

struct AppDemoModeController {
    let environment: [String: String]
    let userDefaults: UserDefaults

    init(
        environment: [String: String],
        userDefaults: UserDefaults = .standard
    ) {
        self.environment = environment
        self.userDefaults = userDefaults
    }

    func shouldLaunchInDemoMode() -> Bool {
        if environment[AppDemoScenario.launchEnvironmentKey] == "1" {
            return true
        }
        return userDefaults.bool(forKey: AppDemoScenario.defaultsKey)
    }

    func setStoredDemoModeEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: AppDemoScenario.defaultsKey)
    }

    static func assistantReply(
        promptSummary: String,
        attachmentCount: Int,
        threadID: String,
        workspaceRoot: String
    ) -> String {
        let normalized = promptSummary.lowercased()
        let attachmentSummary = if attachmentCount == 0 {
            ""
        } else {
            " I also kept the attached \(attachmentCount == 1 ? "artifact" : "artifacts") visible in the composer flow."
        }
        let projectName = workspaceRoot.split(separator: "/").last.map(String.init) ?? "this project"

        if normalized.contains("demo") || normalized.contains("reviewer") {
            return "Demo mode stays on the same thread and returns a deterministic assistant reply, so reviewers can verify the browser, transcript, composer, and reconnect shape without a live Mac.\(attachmentSummary)"
        }
        if normalized.contains("testflight") || normalized.contains("beta") {
            return "For \(projectName), the review-safe summary is: the latest internal 0.9.1 build is ready, and the remaining App Store step is attaching the intended build to version 0.9.0 after the final metadata and review pass.\(attachmentSummary)"
        }
        if normalized.contains("browser") || normalized.contains("thread") || normalized.contains("project") {
            return "The Project and Thread browser stays honest in demo mode too: you can switch projects, reopen an existing thread, and keep using thread \(threadID) after a reply.\(attachmentSummary)"
        }

        return "Demo mode handled that prompt locally for \(projectName) and kept the same active thread so the reviewer can continue exploring the real app surfaces without any SSH or tailscale setup.\(attachmentSummary)"
    }
}
