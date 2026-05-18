import AppKit
import Foundation

/// GitHub Release API 自动更新检查器。
///
/// **设计目标**：用户能知道有新版可用 + 一键引导安装，不上 Sparkle（避免 Developer ID 强依赖）。
///
/// 工作流：
/// 1. App 启动 60s 后 + 每 24h 自动 GET `https://api.github.com/repos/<owner>/<repo>/releases/latest`
/// 2. 对比 latest tag (`v1.3.0`) vs 当前 `CFBundleShortVersionString` (`1.3.0`)
/// 3. 有新版 → `hasUpdate = true`，触发 UI 通知（设置面板 + 菜单栏小红点）
/// 4. 用户点「下载并安装」→ 后台 download DMG 到 ~/Downloads → `hdiutil attach` 挂载
///    → `open <volumePath>` 让 Finder 弹出已挂载的 DMG 窗口 → 用户拖到 Applications
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    // MARK: - State (observable, UI 绑定)

    /// 当前安装版本（从 Info.plist 读）
    let currentVersion: String

    /// 远端最新版本（首次成功检查后填）
    private(set) var latestVersion: String?

    /// 最新版的 DMG 直链
    private(set) var latestDownloadURL: URL?

    /// 最新版的 Release Notes（GitHub release body markdown）
    private(set) var latestNotes: String = ""

    /// 上次检查时间，UI 显示用
    private(set) var lastCheckedAt: Date?

    /// 是否正在检查 / 下载
    private(set) var isChecking = false
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0  // 0.0 ~ 1.0

    /// 最近一次错误（检查失败 / 下载失败）
    private(set) var lastError: String?

    /// 有新版可用（latest > current 且 download URL 有效）
    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return UpdateChecker.compare(latest, isNewerThan: currentVersion) && latestDownloadURL != nil
    }

    // MARK: - 配置

    private static let owner = "basionwang-bot"
    private static let repo = "HermesPet"
    private static let checkInterval: TimeInterval = 24 * 60 * 60   // 24h

    private var periodicTask: Task<Void, Never>?

    private init() {
        let info = Bundle.main.infoDictionary
        self.currentVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - 启动调度

    /// AppDelegate 启动时调一次。延迟 60s 首次检查（避免抢启动资源），之后每 24h 一次。
    func start() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await self?.check(silently: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.checkInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.check(silently: true)
            }
        }
    }

    /// 用户手动从设置面板点「检查更新」时调（silently=false → 即便没新版也通知）
    func check(silently: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }

        let urlString = "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HermesPet/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "GitHub 返回 HTTP \(code)"
                return
            }
            try parseRelease(data: data)
        } catch {
            lastError = "检查失败：\(error.localizedDescription)"
        }

        if !silently, !hasUpdate {
            // 手动触发但没新版 → 弹个温和提示，让用户知道点击有反馈
            NotificationCenter.default.post(
                name: .init("HermesPetUpdateCheckResult"),
                object: nil,
                userInfo: ["hasUpdate": false]
            )
        }
        if hasUpdate {
            NotificationCenter.default.post(
                name: .init("HermesPetUpdateAvailable"),
                object: nil,
                userInfo: [
                    "version": latestVersion ?? "",
                    "silently": silently
                ]
            )
        }
    }

    private func parseRelease(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = "解析失败：响应不是 JSON 对象"
            return
        }
        guard let tag = json["tag_name"] as? String else {
            lastError = "解析失败：缺少 tag_name"
            return
        }
        // GitHub tag 一般带 `v` 前缀（v1.3.0），剥掉再比对
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        self.latestVersion = version
        self.latestNotes = (json["body"] as? String) ?? ""

        // 从 assets 找 .dmg 文件
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.hasSuffix(".dmg"),
                   let urlStr = asset["browser_download_url"] as? String,
                   let url = URL(string: urlStr) {
                    self.latestDownloadURL = url
                    break
                }
            }
        }
        if latestDownloadURL == nil {
            lastError = "未在 release 中找到 DMG 资产"
        }
    }

    // MARK: - 下载 + 引导安装

    /// 用户点「下载并安装」按钮调。
    /// 完成后会自动 `hdiutil attach` 挂载 DMG → `open` 让 Finder 弹出窗口让用户拖到 Applications
    func downloadAndInstall() async {
        guard let dlURL = latestDownloadURL else {
            lastError = "下载链接缺失"
            return
        }
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        lastError = nil
        defer { isDownloading = false }

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let fileName = dlURL.lastPathComponent.isEmpty
            ? "HermesPet-\(latestVersion ?? "latest").dmg"
            : dlURL.lastPathComponent
        let destination = downloadsDir.appendingPathComponent(fileName)

        // 已存在同名文件 → 删了重新下，避免老缓存覆盖新版
        try? FileManager.default.removeItem(at: destination)

        do {
            let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            let (tempURL, response) = try await URLSession.shared.download(from: dlURL, progress: progressHandler)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "下载失败：HTTP \(code)"
                return
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // 挂载 DMG，挂载完成后 open 让 Finder 显示
            attach(dmgPath: destination.path)
        } catch {
            lastError = "下载失败：\(error.localizedDescription)"
        }
    }

    private func attach(dmgPath: String) {
        let proc = Process()
        proc.launchPath = "/usr/bin/hdiutil"
        proc.arguments = ["attach", dmgPath, "-nobrowse", "-noverify", "-noautoopen"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                // hdiutil attach 输出格式示例：
                //   /dev/disk6s1	Apple_HFS	/Volumes/Hermes 桌宠
                // 我们 grep `/Volumes/` 行第三列拿挂载路径
                if let line = output.split(separator: "\n").first(where: { $0.contains("/Volumes/") }) {
                    let parts = line.split(whereSeparator: \.isWhitespace)
                    if let volPath = parts.last(where: { $0.hasPrefix("/Volumes/") }) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: String(volPath)))
                        // 给用户一个引导通知，告诉他下一步该干啥
                        UpdateChecker.shared.postInstallHint(volumePath: String(volPath))
                        return
                    }
                }
                if p.terminationStatus != 0 {
                    UpdateChecker.shared.lastError = "DMG 挂载失败（hdiutil 返回 \(p.terminationStatus)）"
                }
            }
        }
        try? proc.run()
    }

    /// 弹一个 NSAlert 引导用户拖到 Applications
    private func postInstallHint(volumePath: String) {
        let alert = NSAlert()
        alert.messageText = "新版已挂载，请拖入应用程序"
        alert.informativeText = """
        Finder 已经打开新版 DMG。请把里面的「Hermes 桌宠」拖到旁边的「应用程序」文件夹替换旧版即可。

        替换完成后退出当前版本（菜单栏右键 → 退出），重新打开新版本生效。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: - 版本比较

    /// 语义版本比较：`1.3.0` > `1.2.5`，`1.3.1` > `1.3.0`
    /// 简单 dot 分割数字比较，遇到非数字段按字典序兜底
    static func compare(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".")
        let bParts = b.split(separator: ".")
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let ai = i < aParts.count ? Int(aParts[i]) ?? -1 : 0
            let bi = i < bParts.count ? Int(bParts[i]) ?? -1 : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}

// MARK: - URLSession.download with progress (custom helper)

private extension URLSession {
    /// 自定义 download API 附带进度回调。Foundation 的原生 download(from:) 没有 progress hook。
    /// 用 dataTask + completion 简单封装；不做断点续传（更新场景文件小，没必要）
    func download(from url: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let task = self.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: NSError(domain: "UpdateChecker", code: -1))
                    return
                }
                continuation.resume(returning: (tempURL, response))
            }
            // 用 KVO 监听 fractionCompleted 转 callback
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            }
            // 给 task 一个 keepalive 引用，否则 observation 在 closure 退出时释放
            _ = observation
            task.resume()
        }
    }
}
