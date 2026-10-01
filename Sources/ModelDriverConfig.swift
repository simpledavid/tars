import Foundation

/// AI 助手的统一“模型驱动”配置。
///
/// opencode 是本地 agent runtime；这个文件只描述
/// “用哪个服务商、哪个模型、哪个 API Key 驱动它们”。
struct ModelDriverConfig: Codable, Equatable {
    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String
    var updatedAt: String

    static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".hermespet", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("model-driver.json")
    }

    static func currentFromDefaults(date: Date = Date()) -> ModelDriverConfig {
        let ud = UserDefaults.standard
        let baseURL = ud.string(forKey: "directAPIBaseURL") ?? ""
        let storedProviderID = ud.string(forKey: "directAPIProviderID") ?? ""
        let providerID: String
        if storedProviderID.isEmpty {
            let detected = ProviderPreset.detect(baseURL: baseURL)
            providerID = detected.id == "custom" && baseURL.isEmpty ? "deepseek" : detected.id
        } else {
            providerID = storedProviderID
        }

        let model = ud.string(forKey: "directAPIModel") ?? ""
        return ModelDriverConfig(
            providerID: providerID,
            baseURL: baseURL,
            model: model,
            apiKey: effectiveAPIKey(providerID: providerID),
            updatedAt: ISO8601DateFormatter().string(from: date)
        )
    }

    /// 写入 ~/.hermespet/agents/model-driver.json。
    ///
    /// 短期把 apiKey 明文写本地文件，文件权限收紧到 0600、目录 0700。
    /// 后续如需更强保护，可把 apiKey 放 Keychain，这里改成 apiKeyRef。
    @discardableResult
    static func syncFromDefaults() -> URL? {
        let url = configURL
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

            let config = currentFromDefaults()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            NSLog("[ModelDriverConfig] sync failed: %@", "\(error)")
            return nil
        }
    }

    static func load() -> ModelDriverConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(ModelDriverConfig.self, from: data)
    }

    private static func effectiveAPIKey(providerID: String) -> String {
        if !providerID.isEmpty {
            let scoped = "directAPIKey.\(providerID)"
            if UserDefaults.standard.object(forKey: scoped) != nil {
                return UserDefaults.standard.string(forKey: scoped) ?? ""
            }
        }
        return UserDefaults.standard.string(forKey: "directAPIKey") ?? ""
    }
}
