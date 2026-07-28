import AppKit
import Foundation

/// GitHub Release API 的精简模型。
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlUrl: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
    }

    /// 去掉前缀 `v` 后的版本号，例如 `v1.2.3` -> `1.2.3`。
    var version: String {
        tagName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }
}

enum UpdateCheckResult: Sendable {
    case noUpdate(currentVersion: String)
    case updateAvailable(release: GitHubRelease, currentVersion: String)
    case failure(Error)
}

enum UpdateError: LocalizedError {
    case alreadyChecking
    case missingLocalVersion
    case invalidRemoteVersion
    case invalidResponse
    case httpStatus(code: Int)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .alreadyChecking:
            return NSLocalizedString("正在检查更新中。", comment: "Update already checking error")
        case .missingLocalVersion:
            return NSLocalizedString("无法读取当前应用版本。", comment: "Update missing local version error")
        case .invalidRemoteVersion:
            return NSLocalizedString("远程版本号无效。", comment: "Update invalid remote version error")
        case .invalidResponse:
            return NSLocalizedString("服务器响应无效。", comment: "Update invalid response error")
        case .httpStatus(let code):
            return String(format: NSLocalizedString("服务器返回错误（%d）。", comment: "Update HTTP status error"), code)
        case .decodeFailed:
            return NSLocalizedString("解析版本信息失败。", comment: "Update decode failed error")
        }
    }
}

/// 检查 GitHub 最新 Release 并提示用户。
///
/// 由于应用处于沙盒中，无法直接替换自身，因此只负责：
/// 1. 拉取远端版本；
/// 2. 与本地 `CFBundleShortVersionString` 比较；
/// 3. 发现新版本时弹窗，点击后跳转到 GitHub Release 页面由用户手动下载覆盖。
actor UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "monkey-wenjun"
    private let repoName = "ClipVault-Swift"
    private let lastCheckKey = "lastUpdateCheckDate"
    private let skipVersionKey = "skippedUpdateVersion"

    private var isChecking = false

    private init() {}

    nonisolated var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 启动时调用：最多每天自动检查一次，静默失败。
    func checkForUpdatesIfNeeded() async {
        guard shouldCheckAutomatically() else { return }
        let result = await performCheck()
        await handle(result: result, manual: false)
    }

    /// 用户手动点击“检查更新”时调用：失败也弹窗提示。
    func checkForUpdatesManually() async {
        let result = await performCheck()
        await handle(result: result, manual: true)
    }

    nonisolated private func shouldCheckAutomatically() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= 86400
    }

    private func performCheck() async -> UpdateCheckResult {
        guard !isChecking else { return .failure(UpdateError.alreadyChecking) }
        isChecking = true
        defer { isChecking = false }

        guard let currentVersion = currentVersion else {
            return .failure(UpdateError.missingLocalVersion)
        }

        do {
            let release = try await fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            let latestVersion = release.version
            guard !latestVersion.isEmpty else {
                return .failure(UpdateError.invalidRemoteVersion)
            }

            if isVersion(latestVersion, greaterThan: currentVersion) {
                let skipped = UserDefaults.standard.string(forKey: skipVersionKey)
                if skipped == latestVersion {
                    return .noUpdate(currentVersion: currentVersion)
                }
                return .updateAvailable(release: release, currentVersion: currentVersion)
            } else {
                return .noUpdate(currentVersion: currentVersion)
            }
        } catch {
            return .failure(error)
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateError.httpStatus(code: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.decodeFailed
        }
    }

    private func isVersion(_ version: String, greaterThan other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private func handle(result: UpdateCheckResult, manual: Bool) async {
        switch result {
        case .noUpdate(let currentVersion):
            if manual {
                await MainActor.run {
                    showNoUpdateAlert(currentVersion: currentVersion)
                }
            }
        case .updateAvailable(let release, let currentVersion):
            await MainActor.run {
                showUpdateAlert(release: release, currentVersion: currentVersion)
            }
        case .failure(let error):
            if manual {
                await MainActor.run {
                    showErrorAlert(error: error)
                }
            }
        }
    }

    @MainActor
    private func showUpdateAlert(release: GitHubRelease, currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("发现新版本", comment: "Update available alert title")

        var info = String(
            format: NSLocalizedString("当前版本：%@\n最新版本：%@", comment: "Update available version info"),
            currentVersion,
            release.version
        )
        if let body = release.body, !body.isEmpty {
            info += "\n\n" + String(body.prefix(500))
        }
        alert.informativeText = info
        alert.alertStyle = .informational

        alert.addButton(withTitle: NSLocalizedString("前往下载", comment: "Download update button"))
        alert.addButton(withTitle: NSLocalizedString("跳过此版本", comment: "Skip this version button"))
        alert.addButton(withTitle: NSLocalizedString("稍后", comment: "Later button"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(release.version, forKey: skipVersionKey)
        default:
            break
        }
    }

    @MainActor
    private func showNoUpdateAlert(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("已是最新版本", comment: "No update alert title")
        alert.informativeText = String(
            format: NSLocalizedString("当前版本 %@ 已是最新版本。", comment: "No update message"),
            currentVersion
        )
        alert.runModal()
    }

    @MainActor
    private func showErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("检查更新失败", comment: "Update check failed alert title")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
