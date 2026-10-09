import Foundation

/// 刷卡機的答覆
public enum ECRStatus: Sendable, Hashable {
    /// 0000
    case approved
    /// 其他代碼：沒有扣款
    case declined
    /// 查上一筆時回 0010：上一筆是電子錢包，要改用「電子錢包交易查詢」（68）
    case walletLast
}

/// 一則回覆，加上 POS 要用的解讀：核准了沒、卡別、末四碼、授權碼、調閱編號
public struct ECRResult: Sendable, Hashable {
    public let response: ECRResponse
    /// 這則回覆是回哪一種要求（查上一筆的回覆裡，交易別可能是上一筆自己的）
    public let requested: ECRTransType

    public init(_ response: ECRResponse, requested: ECRTransType) {
        self.response = response
        self.requested = requested
    }

    public var responseCode: String { response.responseCode }

    public var status: ECRStatus {
        switch responseCode {
        case "0000": .approved
        case "0010" where requested == .lastTransaction: .walletLast
        default: .declined
        }
    }

    public var isApproved: Bool { status == .approved }
    public var kind: ECRPaymentKind? { response.kind }
    public var brand: ECRCardBrand? { response.brand }
    public var amount: Money? { response.amount }
    public var last4: String? { Self.last4(fromMasked: response.cardNo) }
    public var maskedCardNo: String? { response.cardNo.nonEmpty }
    public var approvalNo: String? { response.approvalNo.nonEmpty }
    public var receiptNo: String? { response.receiptNo.nonEmpty }
    public var terminalId: String? { response.terminalId.nonEmpty }
    public var merchantId: String? { response.merchantId.nonEmpty }
    public var batchNo: String? { response.batchNo.nonEmpty }
    public var walletTransactionId: String? { response.wallet?.transactionId.nonEmpty }

    /// 同一台、同一批、同一個調閱編號（和 CardTerminalRef.key 一樣）
    public var terminalKey: String { CardTerminalRef.key(terminalId: terminalId, batchNo: batchNo, receiptNo: receiptNo) }

    /// 記在付款上的序號：「授權 AB1234・調閱 000123」；電子錢包沒有授權碼，放錢包的交易序號
    public var reference: String {
        var parts: [String] = []
        if let a = approvalNo {
            parts.append("授權 \(a)")
        } else if let w = walletTransactionId {
            parts.append("\(brand?.label ?? "錢包") \(String(w.prefix(40)))")
        }
        if let r = receiptNo { parts.append("調閱 \(r)") }
        return parts.isEmpty ? "刷卡機" : parts.joined(separator: "・")
    }

    /// 給人看的一句
    public var message: String {
        switch status {
        case .approved:
            let card = [brand?.label, last4.map { "****\($0)" }].compactMap { $0 }.joined(separator: " ")
            return card.isEmpty ? "已核准" : "已核准・\(card)"
        case .walletLast:
            return "上一筆是電子錢包"
        case .declined:
            return responseCode.isEmpty ? "刷卡機沒有核准" : "刷卡機沒有核准（代碼 \(responseCode)）"
        }
    }

    /// 存到付款上的一份
    public func terminalRef(format: ECRFormat) -> CardTerminalRef {
        let at = response.transDate + response.transTime
        return CardTerminalRef(format: format.rawValue, kind: response.kindCode.nonEmpty, terminalId: terminalId, merchantId: merchantId,
                               batchNo: batchNo, receiptNo: receiptNo, approvalNo: approvalNo,
                               brand: brand?.label ?? response.cardTypeCode.nonEmpty, hostId: response.hostId.nonEmpty,
                               at: at.nonEmpty, walletOrderId: response.wallet?.orderId.nonEmpty, walletTransactionId: walletTransactionId)
    }

    /// 遮起來的卡號取末四碼（431195******1234、4311-95**-****-1234）；最後四碼不全是數字（票證遮了尾巴）就沒有
    public static func last4(fromMasked raw: String) -> String? {
        let chars = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard chars.count >= 4 else { return nil }
        let tail = chars.suffix(4)
        guard tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tail)
    }
}

extension String {
    /// 空字串＝nil
    var nonEmpty: String? { isEmpty ? nil : self }
}
