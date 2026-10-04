import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import Security

/// 這台 iPad 的身分與快取：
///   - token 在 Keychain（這台裝置、解鎖後才讀得到、不跟著 iCloud 備份走）
///   - 配對資訊、最近一次的 bootstrap 存在 Application Support（斷網開機也有菜單、人員、桌位）
///   - 事件日誌在 Application Support/journal/<deviceId>/（EventJournal）
enum DeviceStore {
    struct Pairing: Codable, Hashable {
        var cmsURL: URL
        var deviceId: String
        var deviceCode: String
        var role: DeviceRole
        var storeName: String
        var pairedAt: Date
        /// 用 StudioX 帳號登入的個人裝置：綁著的門市人員（開機資料還沒抓到也知道是誰；POSModel+Personal）
        var personal: Bool? = nil
        var staffId: String? = nil
        var staffName: String? = nil
    }

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("StudioXPOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func journalDirectory(deviceId: String) -> URL {
        root.appendingPathComponent("journal", isDirectory: true).appendingPathComponent(deviceId, isDirectory: true)
    }

    private static var pairingURL: URL { root.appendingPathComponent("pairing.json") }
    private static var bootstrapURL: URL { root.appendingPathComponent("bootstrap.json") }

    // MARK: 配對

    static func loadPairing() -> Pairing? {
        guard let data = try? Data(contentsOf: pairingURL) else { return nil }
        return try? EventCoding.decoder().decode(Pairing.self, from: data)
    }

    static func save(_ p: Pairing, token: String) throws {
        try EventCoding.encoder().encode(p).write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Keychain.set(token, for: "device-token")
    }

    static var token: String? { Keychain.get("device-token") }

    /// 後台移除了這台、或店長選「解除配對」：連日誌一起清掉
    static func forget(deviceId: String?) {
        try? FileManager.default.removeItem(at: pairingURL)
        try? FileManager.default.removeItem(at: bootstrapURL)
        if let deviceId { try? FileManager.default.removeItem(at: journalDirectory(deviceId: deviceId)) }
        Keychain.delete("device-token")
    }

    // MARK: bootstrap 快取

    static func loadBootstrap() -> Bootstrap? {
        guard let data = try? Data(contentsOf: bootstrapURL) else { return nil }
        return try? EventCoding.decoder().decode(Bootstrap.self, from: data)
    }

    static func save(_ b: Bootstrap) {
        guard let data = try? EventCoding.encoder().encode(b) else { return }
        try? data.write(to: bootstrapURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Keychain 的最小包裝（一般密碼項目、只在這台裝置）
enum Keychain {
    private static let service = "tw.studiox.pos"

    static func set(_ value: String, for key: String) throws {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
