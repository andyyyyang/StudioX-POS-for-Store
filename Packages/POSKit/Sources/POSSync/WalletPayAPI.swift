import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import POSCore

// 門市掃碼付（docs/API.md「掃碼付」）：iPad 掃客人手機上的付款碼（LINE Pay、街口、全支付、悠遊付），交給後台、經 StudioX Pay 直接跟錢包收款。
// iPad 手上沒有金流的金鑰：後台（網站）用自己的憑證轉給 console。
//
// 不重複扣款（後台和 App 一起守）：
//   - paymentId（POS 的付款 id，也是記帳時 Payment.id）是後台的冪等鍵：斷線、逾時重送同一個請求，後台回第一次的結果
//   - 不知道結果（沒網路、逾時、5xx、看不懂回應）不能當失敗：照同一筆再問（intentId 查，或「只查」＝不帶付款碼）
//   - 「只查」不會扣款：還沒送到錢包的那筆後台直接取消，之後遲到的請求也扣不了

/// 開機資料的 walletScan：後台開了掃碼付的錢包（features.walletScan 開著才有）
public struct WalletScanConfig: Codable, Sendable, Hashable {
    /// StudioX Pay 的付款方式代號（line_pay、jko_pay、px_pay、easy_wallet、twqr），照後台的順序；這版不認得的不用
    public var methods: [String]
    /// 處理中每幾毫秒問一次
    public var pollMs: Int
    /// 最多等幾分鐘（錢包 20 分鐘還不知道就當失敗）
    public var windowMinutes: Int

    public init(methods: [String], pollMs: Int = 3000, windowMinutes: Int = 20) {
        self.methods = methods; self.pollMs = pollMs; self.windowMinutes = windowMinutes
    }

    enum CodingKeys: String, CodingKey { case methods, pollMs, windowMinutes }

    // 讀的時候寬鬆：少了欄位用預設，不要讓整份開機資料讀不進來
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        methods = (try? c.decodeIfPresent([String].self, forKey: .methods)) ?? []
        pollMs = min(max((try? c.decodeIfPresent(Int.self, forKey: .pollMs)) ?? 3000, 1000), 30_000)
        windowMinutes = min(max((try? c.decodeIfPresent(Int.self, forKey: .windowMinutes)) ?? 20, 1), 60)
    }

    /// 這版收得了的付款方式（照後台的順序；台灣Pay 這版還沒有付款方式，不列）
    public var tenders: [Tender] {
        var out: [Tender] = []
        for m in methods { if let t = WalletMethod.tender(for: m), !out.contains(t) { out.append(t) } }
        return out
    }
}

/// 付款方式 ↔ StudioX Pay 的付款方式代號
public enum WalletMethod {
    public static func code(for tender: Tender) -> String? {
        switch tender {
        case .linePay: "line_pay"
        case .jkoPay: "jko_pay"
        case .pxPay: "px_pay"
        case .easyWallet: "easy_wallet"
        default: nil
        }
    }

    public static func tender(for code: String) -> Tender? {
        switch code {
        case "line_pay": .linePay
        case "jko_pay": .jkoPay
        case "px_pay": .pxPay
        case "easy_wallet": .easyWallet
        default: nil
        }
    }

    /// 掃到的付款碼：去掉條碼機多打的空白、換行；只能是 6–64 個英數字（後台與 StudioX Pay 一樣的規則）
    public static func normalize(_ raw: String) -> String? {
        let code = raw.filter { !$0.isWhitespace }
        guard (6...64).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }
}

/// POST /pay/scan
public struct WalletScanRequest: Codable, Sendable, Hashable {
    /// POS 的付款 id（記帳時的 Payment.id）：後台的冪等鍵
    public var paymentId: String
    public var ticketId: String
    public var amount: Money
    /// line_pay、jko_pay…（WalletMethod.code）
    public var method: String
    /// 客人的付款碼；nil＝只查這個付款 id 怎麼了（不會扣款）
    public var code: String?
    /// 誰收的（個人的裝置後台一律記綁著的那位）
    public var staffId: String?

    public init(paymentId: String, ticketId: String, amount: Money, method: String, code: String?, staffId: String? = nil) {
        self.paymentId = paymentId; self.ticketId = ticketId; self.amount = amount; self.method = method; self.code = code; self.staffId = staffId
    }

    /// 同一筆改成「只查」（App 重開、斷線之後：不再送付款碼）
    public var lookup: WalletScanRequest {
        var r = self
        r.code = nil
        return r
    }
}

public enum WalletPayStatus: String, Codable, Sendable, Hashable {
    case succeeded, processing, failed

    // 新版後台多了這版不認得的狀態：當作處理中（繼續查），不能當成失敗讓店員再收一次
    public init(from decoder: Decoder) throws {
        self = WalletPayStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .processing
    }
}

/// 掃碼付的結果（POST /pay/scan、GET /pay/intents/{id}、POST …/cancel 都是這個）
public struct WalletPayResult: Codable, Sendable, Hashable {
    public var status: WalletPayStatus
    /// StudioX Pay 的付款 id（pi_…）：處理中用它查、退款用它退
    public var intentId: String?
    public var amount: Money
    public var method: String?
    /// 錢包的交易序號（記在付款的 reference）
    public var pspTransactionId: String?
    public var wallet: String?
    public var paidAt: String?
    /// 失敗的原因代碼：not_started、canceled、expired、conflicted（錢包扣的金額不對：不能再收一次）、錢包的錯誤…
    public var code: String?
    /// 給店員看的一句話
    public var message: String?
    public var pollAfterMs: Int?
    /// 處理中最多查到什麼時候
    public var pollUntil: Date?
    /// 取消的回應：false＝錢包正在處理，取消不了（繼續等結果）
    public var cancelable: Bool?

    public init(status: WalletPayStatus, intentId: String?, amount: Money, method: String? = nil, pspTransactionId: String? = nil, wallet: String? = nil,
                paidAt: String? = nil, code: String? = nil, message: String? = nil, pollAfterMs: Int? = nil, pollUntil: Date? = nil, cancelable: Bool? = nil) {
        self.status = status; self.intentId = intentId; self.amount = amount; self.method = method; self.pspTransactionId = pspTransactionId
        self.wallet = wallet; self.paidAt = paidAt; self.code = code; self.message = message; self.pollAfterMs = pollAfterMs
        self.pollUntil = pollUntil; self.cancelable = cancelable
    }

    enum CodingKeys: String, CodingKey {
        case status, intentId, amount, method, pspTransactionId, wallet, paidAt, code, message, pollAfterMs, pollUntil, cancelable
    }

    // 讀的時候寬鬆：看不懂的時間、多出來的欄位都不能讓一筆已經扣款的結果讀不進來
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(WalletPayStatus.self, forKey: .status)
        intentId = try? c.decodeIfPresent(String.self, forKey: .intentId)
        amount = (try? c.decodeIfPresent(Money.self, forKey: .amount)) ?? .zero
        method = try? c.decodeIfPresent(String.self, forKey: .method)
        pspTransactionId = try? c.decodeIfPresent(String.self, forKey: .pspTransactionId)
        wallet = try? c.decodeIfPresent(String.self, forKey: .wallet)
        paidAt = try? c.decodeIfPresent(String.self, forKey: .paidAt)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        pollAfterMs = try? c.decodeIfPresent(Int.self, forKey: .pollAfterMs)
        pollUntil = try? c.decodeIfPresent(Date.self, forKey: .pollUntil)
        cancelable = try? c.decodeIfPresent(Bool.self, forKey: .cancelable)
    }

    /// 錢包扣的金額和這筆不一樣：錢可能已經動了，不能再掃一次
    public var isConflicted: Bool { status == .failed && code == "conflicted" }
}

/// POST /pay/refunds
public struct WalletRefundRequest: Codable, Sendable, Hashable {
    public var intentId: String
    /// nil＝剩下的全部
    public var amount: Money?
    /// POS 的退款 id（記帳時的 Refund.id）：後台的冪等鍵，重送不會退兩次
    public var refundId: String
    public var reason: String?
    /// 超過店家設定的金額：店長的 PIN（後台驗）
    public var managerPin: String?
    public var staffId: String?

    public init(intentId: String, amount: Money?, refundId: String, reason: String?, managerPin: String? = nil, staffId: String? = nil) {
        self.intentId = intentId; self.amount = amount; self.refundId = refundId; self.reason = reason; self.managerPin = managerPin; self.staffId = staffId
    }
}

public enum WalletRefundStatus: String, Codable, Sendable, Hashable {
    case pending, succeeded, failed
    /// 要到錢包業者的後台退（StudioX Pay 記下了）
    case requiresManualAction = "requires_manual_action"

    // 不認得的當處理中（錢可能會退）
    public init(from decoder: Decoder) throws {
        self = WalletRefundStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
    }
}

public struct WalletRefundResult: Codable, Sendable, Hashable {
    /// StudioX Pay 的退款 id（re_…）
    public var refundId: String
    public var status: WalletRefundStatus
    public var amount: Money
    public var message: String?

    public init(refundId: String, status: WalletRefundStatus, amount: Money, message: String? = nil) {
        self.refundId = refundId; self.status = status; self.amount = amount; self.message = message
    }
}

extension APIError {
    public static let walletPayUnsupported = "後台還不支援掃碼付，請更新後台"
    public static let managerApprovalRequiredCode = "manager_approval_required"

    /// 不知道後台做了沒有（沒網路、逾時、後台出錯、看不懂回應）：同一筆再問，不能當成失敗
    public var isUncertain: Bool {
        switch self {
        case .offline, .decoding: true
        case .http(let s, _, _): s >= 500 || s == 429
        default: false
        }
    }

    /// 退款超過店家設定的金額，要店長核准
    public var needsManagerApproval: Bool {
        if case .http(403, Self.managerApprovalRequiredCode, _) = self { return true }
        return false
    }
}

extension POSAPI {
    // 舊的假後台（測試）沒有掃碼付：當作後台還不支援
    public func walletScan(_ request: WalletScanRequest) async throws -> WalletPayResult {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.walletPayUnsupported)
    }

    public func walletIntent(id: String) async throws -> WalletPayResult {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.walletPayUnsupported)
    }

    public func cancelWalletIntent(id: String) async throws -> WalletPayResult {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.walletPayUnsupported)
    }

    public func walletRefund(_ request: WalletRefundRequest) async throws -> WalletRefundResult {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.walletPayUnsupported)
    }
}

extension POSClient {
    /// 後台要等錢包（最慢 40 秒）再加上 console：給 90 秒
    public func walletScan(_ request: WalletScanRequest) async throws -> WalletPayResult {
        try await call("pay/scan", method: "POST", body: request, timeout: 90)
    }

    public func walletIntent(id: String) async throws -> WalletPayResult {
        try await call("pay/intents/\(id)", method: "GET", body: Optional<Empty>.none, timeout: 40)
    }

    public func cancelWalletIntent(id: String) async throws -> WalletPayResult {
        try await call("pay/intents/\(id)/cancel", method: "POST", body: Empty(), timeout: 40)
    }

    public func walletRefund(_ request: WalletRefundRequest) async throws -> WalletRefundResult {
        try await call("pay/refunds", method: "POST", body: request, timeout: 60)
    }
}
