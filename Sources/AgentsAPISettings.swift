import Foundation
import Security

struct AgentsAPISettings: Equatable, Sendable {
    var model: String
    var revision: String

    static func load() -> Self {
        Self(model: UserDefaults.standard.string(forKey: "agentsAPI.model") ?? "gpt-6-astra",
             revision: UserDefaults.standard.string(forKey: "agentsAPI.revision") ?? "initial")
    }

    func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentsAPIError.message("请在 OpenAI Agents API 设置中填写模型")
        }
    }

    static func save(model: String, credentials: AgentsCredentials) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self(model: model, revision: "").validate()
        try credentials.validate()
        try AgentsKeychain.save(credentials.applicationKey, account: "application")
        try AgentsKeychain.save(credentials.environmentKey, account: "environment")
        UserDefaults.standard.set(model, forKey: "agentsAPI.model")
        UserDefaults.standard.set(UUID().uuidString, forKey: "agentsAPI.revision")
    }
}

struct AgentsCredentials: Sendable {
    let applicationKey: String
    let environmentKey: String

    static func load() throws -> Self {
        let value = Self(applicationKey: try AgentsKeychain.read(account: "application") ?? "",
                         environmentKey: try AgentsKeychain.read(account: "environment") ?? "")
        try value.validate()
        return value
    }

    func validate() throws {
        guard !applicationKey.isEmpty, !environmentKey.isEmpty else {
            throw AgentsAPIError.message("请在设置中填写 OpenAI 应用密钥和执行环境密钥")
        }
        guard applicationKey != environmentKey else {
            throw AgentsAPIError.message("请使用两种不同的密钥：应用密钥与专用执行环境密钥")
        }
    }
}

enum AgentsKeychain {
    private static let service = "com.nousresearch.hermespet.agents-api"
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AgentsAPIError.message("无法读取系统钥匙串（\(status)）")
        }
        return value
    }

    static func save(_ value: String, account: String) throws {
        let query = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AgentsAPIError.message("无法保存到系统钥匙串（\(status)）")
        }
    }
}

enum AgentsAPIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
