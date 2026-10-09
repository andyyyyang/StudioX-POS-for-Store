import Foundation
import POSCore
import POSSync

/// 示範店的一筆掃碼付
nonisolated struct DemoWalletIntent: Sendable {
    var intentId: String
    var amount: Money
    var method: String
    var startedAt: Date
    var status: WalletPayStatus
    var code: String?
    var transactionId: String
    var refunded = Money.zero
}

/// 示範的「後台」收掃碼付（不連網路）：掃到付款碼先回「處理中」（客人在手機上確認），兩秒後查就成功；
/// 和真的後台一樣用付款 id 冪等（重送同一筆拿到同一個結果）、只查不會扣款、退款用退款 id 冪等。
/// 截圖（-walletScan）一直停在「等客人在手機上確認」
extension DemoAPI {
    func walletScan(_ r: WalletScanRequest) async throws -> WalletPayResult {
        if let existing = walletIntents[r.paymentId] { return walletResult(existing) }
        guard let code = r.code else {
            // 只查：這筆沒送到過＝沒有扣款
            return WalletPayResult(status: .failed, intentId: nil, amount: r.amount, code: "not_started", message: "還沒有送到錢包，沒有扣款")
        }
        try? await Task.sleep(for: .milliseconds(600))
        let n = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        let w = DemoWalletIntent(intentId: "pi_demo\(n)", amount: r.amount, method: r.method, startedAt: Date(), status: .processing, code: code,
                                 transactionId: "2026" + (0..<12).map { _ in String(Int.random(in: 0...9)) }.joined())
        walletIntents[r.paymentId] = w
        return walletResult(w)
    }

    func walletIntent(id: String) async throws -> WalletPayResult {
        guard let key = walletKey(id), var w = walletIntents[key] else {
            throw APIError.http(status: 404, code: "not_found", message: "找不到這筆付款")
        }
        // 客人兩秒後在手機上按了確認（截圖：一直等）
        if w.status == .processing, !walletHold, Date().timeIntervalSince(w.startedAt) >= 2 {
            w.status = .succeeded
            walletIntents[key] = w
        }
        return walletResult(w)
    }

    func cancelWalletIntent(id: String) async throws -> WalletPayResult {
        guard let key = walletKey(id), var w = walletIntents[key] else {
            throw APIError.http(status: 404, code: "not_found", message: "找不到這筆付款")
        }
        guard w.status == .processing else {
            var r = walletResult(w)
            r.cancelable = false
            return r
        }
        w.status = .failed
        walletIntents[key] = w
        var r = walletResult(w)
        r.code = "canceled"
        r.message = "這筆已取消，沒有扣款"
        r.cancelable = true
        return r
    }

    func walletRefund(_ r: WalletRefundRequest) async throws -> WalletRefundResult {
        if let done = walletRefunds[r.refundId] { return done }
        guard let key = walletKey(r.intentId), var w = walletIntents[key] else {
            throw APIError.http(status: 404, code: "not_found", message: "找不到這筆付款")
        }
        guard w.status == .succeeded else { throw APIError.http(status: 409, code: "not_refundable", message: "這筆付款沒有成功，不用退款") }
        let left = w.amount - w.refunded
        let amount = r.amount ?? left
        guard amount.cents > 0, amount <= left else { throw APIError.http(status: 400, code: "invalid_request", message: "最多只能再退 \(left.formatted)") }
        try? await Task.sleep(for: .milliseconds(500))
        w.refunded = w.refunded + amount
        walletIntents[key] = w
        let result = WalletRefundResult(refundId: "re_demo\(walletRefunds.count + 1)", status: .succeeded, amount: amount)
        walletRefunds[r.refundId] = result
        return result
    }

    private func walletKey(_ intentId: String) -> String? {
        walletIntents.first { $0.value.intentId == intentId }?.key
    }

    private func walletResult(_ w: DemoWalletIntent) -> WalletPayResult {
        switch w.status {
        case .succeeded:
            return WalletPayResult(status: .succeeded, intentId: w.intentId, amount: w.amount, method: w.method, pspTransactionId: w.transactionId,
                                   wallet: w.method)
        case .failed:
            return WalletPayResult(status: .failed, intentId: w.intentId, amount: w.amount, method: w.method, code: "canceled", message: "這筆已取消，沒有扣款")
        case .processing:
            return WalletPayResult(status: .processing, intentId: w.intentId, amount: w.amount, method: w.method, message: "等客人在手機上確認",
                                   pollAfterMs: 1000, pollUntil: w.startedAt.addingTimeInterval(21 * 60))
        }
    }
}
