import AuthenticationServices
import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import Security
import SwiftUI

/// StudioX 帳號（console）的登入：用 StudioX 帳號配對這台時才用到（只拿來配對、換店，不拿來同步）。
///
///   - 系統的登入視窗打開 console 的登入頁（Apple、Email、邀請都一樣），和 Safari 共用登入狀態：已經在 Safari 登入過就不用再打密碼
///   - 回到 studiox-pos://oauth 帶授權碼，再用 PKCE 換 token（ConsoleOAuth，POSKit）
///   - token 存在 Keychain（這台裝置、第一次解鎖後才讀得到、不跟著備份走）；不印、不記 log
///
/// 和 StudioX Console App 的 Auth.swift 同一套做法（client_id 換成 studiox-pos、scope 是 pos:staff）。
nonisolated enum ConsoleAccount {
    private static let service = "tw.studiox.pos"
    private static let account = "console-tokens"

    // MARK: 登入

    /// 打開登入視窗、換到 token、存進 Keychain。使用者自己關掉視窗：ConsoleAuthError.cancelled
    @MainActor
    static func signIn(using auth: WebAuthenticationSession, consoleURL: URL) async throws -> ConsoleTokens {
        let request = ConsoleOAuth.Request()
        let callback: URL
        do {
            callback = try await auth.authenticate(
                using: request.authorizeURL(consoleURL: consoleURL),
                callback: .customScheme(ConsoleOAuth.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw ConsoleAuthError.cancelled
        } catch {
            throw ConsoleAuthError.denied("登入視窗打不開，請再試一次")
        }
        let code = try ConsoleOAuth.code(from: callback, state: request.state)
        let tokens = try await ConsoleOAuth.exchange(code: code, verifier: request.verifier, consoleURL: consoleURL)
        save(tokens)
        return tokens
    }

    /// 這次登入用的 session：快過期就換、401 換一次再試；換到的新 token 存回 Keychain
    static func session(tokens: ConsoleTokens?, consoleURL: URL) -> ConsoleSession {
        ConsoleSession(tokens: tokens, consoleURL: consoleURL) { next in ConsoleAccount.save(next) }
    }

    /// 登出：清掉 Keychain，在背景撤銷 token（網路不通也照樣清掉）
    static func forget(consoleURL: URL) {
        guard let tokens = load() else { return }
        save(nil)
        Task.detached { await ConsoleOAuth.revoke(tokens, consoleURL: consoleURL) }
    }

    // MARK: Keychain

    static func load() -> ConsoleTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ConsoleTokens.self, from: data)
    }

    /// nil＝清掉
    static func save(_ tokens: ConsoleTokens?) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        var item = match
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }
}
