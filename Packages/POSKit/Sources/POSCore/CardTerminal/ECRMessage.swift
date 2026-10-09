import Foundation

// 銀行刷卡機（EDC）的收銀機連線（ECR 連線）：聯卡中心（NCCC）「8N1 標準」電文，固定 400 個 ASCII 字元。
//
// 欄位位置照聯卡中心端末程式（虹堡 V3）拆收銀機電文用的欄位表、組回覆的程式：收銀機送的、刷卡機回的是同一個版面，
// 收銀機只填這次要用的欄位，其他留空白。這裡只有組、拆（純函式）；封包在 ECRFraming，送收在 App（UDP）。
// 哪些是程式裡看得到的、哪些是推的：docs/PAYMENTS-INSTORE.md。

/// 交易別（Trans Type，2 碼）
public enum ECRTransType: String, Sendable, Hashable, Codable, CaseIterable {
    /// 一般交易（消費）
    case sale = "01"
    case refund = "02"
    /// 補登
    case offline = "03"
    case installment = "04"
    /// 紅利扣抵
    case redeem = "05"
    case installmentRefund = "06"
    case redeemRefund = "07"
    /// 取消（同一批還沒結帳的交易，用調閱編號）
    case void = "30"
    /// 刷卡機結帳（日結，換下一批）
    case settlement = "50"
    /// 查上一筆
    case lastTransaction = "62"
    case eTicketTopUp = "65"
    case eTicketBalance = "66"
    case eTicketVoidTopUp = "67"
    /// 電子錢包交易查詢
    case walletQuery = "68"
    /// 連線測試
    case echo = "98"

    public var label: String {
        switch self {
        case .sale: "一般交易"
        case .refund: "退貨"
        case .offline: "補登"
        case .installment: "分期"
        case .redeem: "紅利扣抵"
        case .installmentRefund: "分期退貨"
        case .redeemRefund: "紅利退貨"
        case .void: "取消"
        case .settlement: "結帳"
        case .lastTransaction: "查上一筆"
        case .eTicketTopUp: "電子票證加值"
        case .eTicketBalance: "電子票證餘額"
        case .eTicketVoidTopUp: "加值取消"
        case .walletQuery: "電子錢包查詢"
        case .echo: "連線測試"
        }
    }

    /// 要帶主機代號、付款工具的交易（端末程式回 Host ID 的那幾種；結帳、查上一筆、連線測試不帶）
    var carriesHost: Bool {
        switch self {
        case .sale, .refund, .offline, .installment, .redeem, .installmentRefund, .redeemRefund, .void,
             .eTicketTopUp, .eTicketVoidTopUp, .walletQuery: true
        case .settlement, .lastTransaction, .eTicketBalance, .echo: false
        }
    }

    /// 要帶金額的交易
    var needsAmount: Bool {
        switch self {
        case .sale, .refund, .offline, .installment, .redeem, .installmentRefund, .redeemRefund, .eTicketTopUp: true
        default: false
        }
    }
}

/// 這一筆收什麼（CUP／Smart Pay／ESVC／Wallet Indicator，1 碼）：收銀機指定，刷卡機照回
public enum ECRPaymentKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// 信用卡（U Card、Visa、Master、JCB、AMEX）
    case card = "N"
    case unionPay = "C"
    case smartPay = "S"
    /// 電子票證：悠遊卡、一卡通、愛金卡、有錢卡
    case eTicket = "E"
    /// 電子錢包：刷卡機掃客人的 LINE Pay、悠遊付、icash Pay、全盈+PAY、全支付、Pi 錢包付款碼
    case wallet = "W"
    /// 信託
    case trust = "T"

    /// 預設的主機
    public var host: ECRHost {
        switch self {
        case .card, .unionPay, .smartPay: .nccc
        case .eTicket: .eTicket
        case .wallet: .wallet
        case .trust: .trust
        }
    }
}

/// 主機代號（Host ID，2 碼）
public enum ECRHost: String, Sendable, Hashable, Codable, CaseIterable {
    case diners = "00"
    /// 聯卡中心：U Card、Visa、Master、JCB、銀聯、Smart Pay
    case nccc = "03"
    /// 外幣（DCC）
    case dcc = "04"
    /// 優惠兌換
    case loyalty = "05"
    /// 電子票證
    case eTicket = "06"
    /// 電子錢包
    case wallet = "08"
    case trust = "09"
}

/// 卡別（Card Type，2 碼）。電子錢包交易這一欄放錢包業者代碼（21–26）
public enum ECRCardBrand: String, Sendable, Hashable, Codable, CaseIterable {
    case uCard = "01", visa = "02", mastercard = "03", jcb = "04", amex = "05", unionPay = "06", diners = "07", smartPay = "08"
    case easyCard = "11", iPass = "12", iCash = "13"
    case linePay = "21", easyWallet = "22", icashPay = "23", plusPay = "24", pxPay = "25", piWallet = "26"

    public var label: String {
        switch self {
        case .uCard: "U Card"
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .jcb: "JCB"
        case .amex: "AMEX"
        case .unionPay: "銀聯"
        case .diners: "Diners"
        case .smartPay: "Smart Pay"
        case .easyCard: "悠遊卡"
        case .iPass: "一卡通"
        case .iCash: "愛金卡"
        case .linePay: "LINE Pay"
        case .easyWallet: "悠遊付"
        case .icashPay: "icash Pay"
        case .plusPay: "全盈+PAY"
        case .pxPay: "全支付"
        case .piWallet: "Pi 錢包"
        }
    }

    public var isETicket: Bool { self == .easyCard || self == .iPass || self == .iCash }
    public var isWallet: Bool { Int(rawValue).map { (21...26).contains($0) } ?? false }
}

/// 一個欄位：從 0 起算的位置、長度
public struct ECRField: Sendable, Hashable, CustomStringConvertible {
    public let name: String
    public let offset: Int
    public let length: Int

    public init(_ name: String, _ offset: Int, _ length: Int) {
        self.name = name; self.offset = offset; self.length = length
    }

    public var range: Range<Int> { offset..<(offset + length) }
    public var end: Int { offset + length }
    public var description: String { "\(name)（第 \(offset + 1) 碼起 \(length) 碼）" }
}

/// 聯卡中心 8N1 標準（400）的版面。位置從 0 起算（端末程式的欄位表從 1 起算）
public enum NCCC8N1 {
    public static let length = 400
    /// 端末程式寫的 ECR 版本日期（收銀機送的時候照帶）
    public static let currentVersion = "260116"

    public static let ecrIndicator = ECRField("ECR Indicator", 0, 1)
    public static let versionDate = ECRField("ECR Version Date", 1, 6)
    public static let transTypeIndicator = ECRField("Trans Type Indicator", 7, 1)
    public static let transType = ECRField("Trans Type", 8, 2)
    public static let paymentKind = ECRField("CUP/SmartPay/ESVC/Wallet Indicator", 10, 1)
    public static let hostId = ECRField("Host ID", 11, 2)
    public static let receiptNo = ECRField("Receipt No", 13, 6)
    public static let cardNo = ECRField("Card No", 19, 19)
    /// 結帳時是總筆數
    public static let cardExpiry = ECRField("Card Expire Date", 38, 4)
    /// 後 2 碼是小數；結帳時是總金額
    public static let amount = ECRField("Trans Amount", 42, 12)
    public static let transDate = ECRField("Trans Date", 54, 6)
    public static let transTime = ECRField("Trans Time", 60, 6)
    public static let approvalNo = ECRField("Approval No", 66, 9)
    public static let waveIndicator = ECRField("Wave Card Indicator", 75, 1)
    public static let responseCode = ECRField("ECR Response Code", 76, 4)
    public static let merchantId = ECRField("Merchant ID", 80, 15)
    public static let terminalId = ECRField("Terminal ID", 95, 8)
    public static let expAmount = ECRField("Exp Amount", 103, 12)
    public static let storeId = ECRField("Store Id", 115, 18)
    public static let installmentRedeemIndicator = ECRField("Installment/Redeem Indicator", 133, 1)
    public static let redeemPaidAmount = ECRField("RDM Paid Amt", 134, 12)
    public static let redeemPoints = ECRField("RDM Point", 146, 8)
    public static let pointsBalance = ECRField("Points of Balance", 154, 8)
    public static let redeemAmount = ECRField("Redeem Amt", 162, 12)
    public static let installmentPeriod = ECRField("Installment Period", 174, 2)
    /// 分期：首期金額；電子票證：交易前餘額
    public static let downPayment = ECRField("Down Payment / ESVC Balance Before", 176, 12)
    /// 分期：每期金額；電子票證：交易後餘額
    public static let installmentPayment = ECRField("Installment Payment / ESVC Balance After", 188, 12)
    /// 分期：手續費；電子票證：自動加值金額
    public static let formalityFee = ECRField("Formality Fee / ESVC Autoload", 200, 12)
    public static let cardType = ECRField("Card Type", 212, 2)
    public static let batchNo = ECRField("Batch No", 214, 6)

    // 220 起：一般交易
    public static let startTransType = ECRField("Start Trans Type", 220, 2)
    public static let mpFlag = ECRField("MP Flag", 222, 1)
    public static let spIssuerId = ECRField("SP Issuer ID", 223, 8)
    public static let originDate = ECRField("Origin Date", 231, 8)
    public static let originRRN = ECRField("Origin RRN", 239, 12)
    public static let payItem = ECRField("Pay Item", 251, 5)
    public static let cardNoHash = ECRField("Card No Hash", 256, 50)
    public static let mpResponseCode = ECRField("MP Response Code", 306, 6)
    public static let asmAwardFlag = ECRField("ASM Award Flag", 312, 1)
    public static let mcpIndicator = ECRField("MCP Indicator", 313, 1)
    public static let bankCode = ECRField("Bank Code", 314, 3)
    public static let reserved = ECRField("Reserved", 317, 5)
    public static let happyGo = ECRField("HG Data", 322, 78)

    // 220 起：電子錢包（付款工具 = W）
    public static let walletOrderId = ECRField("EW Order Id", 220, 30)
    public static let walletReserved = ECRField("EW Reserved", 250, 6)
    public static let walletCarrier = ECRField("EW E-invoice Carrier", 256, 50)
    public static let walletRefundTradeNo = ECRField("EW Refund Trade No", 306, 30)
    public static let walletTransactionId = ECRField("EW Transaction Id", 336, 64)

    /// 前面共用的欄位（0–219）
    public static let common: [ECRField] = [
        ecrIndicator, versionDate, transTypeIndicator, transType, paymentKind, hostId, receiptNo, cardNo, cardExpiry, amount,
        transDate, transTime, approvalNo, waveIndicator, responseCode, merchantId, terminalId, expAmount, storeId,
        installmentRedeemIndicator, redeemPaidAmount, redeemPoints, pointsBalance, redeemAmount, installmentPeriod,
        downPayment, installmentPayment, formalityFee, cardType, batchNo,
    ]
    /// 一般交易的整個版面（剛好 400）
    public static let standardLayout: [ECRField] = common + [
        startTransType, mpFlag, spIssuerId, originDate, originRRN, payItem, cardNoHash, mpResponseCode, asmAwardFlag, mcpIndicator,
        bankCode, reserved, happyGo,
    ]
    /// 電子錢包的整個版面（剛好 400）
    public static let walletLayout: [ECRField] = common + [walletOrderId, walletReserved, walletCarrier, walletRefundTradeNo, walletTransactionId]
}

/// 金額欄位：12 碼、右靠左補 0、後 2 碼是小數（NT$1,280 → 000000128000）
public enum ECRAmount {
    /// 12 碼放得下的最大值（NT$9,999,999,999）
    public static let maxCents = 999_999_999_999

    /// 新台幣沒有角分：不是整數元的不送（寧可擋下來，也不要讓客人刷到不對的金額）
    public static func encode(_ m: Money) throws -> String {
        guard m.cents > 0 else { throw ECRError.invalidAmount("金額要大於 0") }
        guard m.cents % 100 == 0 else { throw ECRError.invalidAmount("新台幣沒有角分（\(m.cents) 分）") }
        guard m.cents <= maxCents else { throw ECRError.invalidAmount("超過刷卡機的上限 NT$9,999,999,999") }
        let digits = String(m.cents)
        return String(repeating: "0", count: 12 - digits.count) + digits
    }

    /// 空白、不是數字的回 nil（電子票證的餘額可能是負的：前面一個「-」）
    public static func decode(_ raw: String) -> Money? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        var negative = false
        if s.first == "-" {
            negative = true
            s = s.dropFirst()
        }
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(s) else { return nil }
        return Money(cents: negative ? -n : n)
    }
}

/// 一則 400 碼的電文（收銀機送的、刷卡機回的都是）
public struct ECRMessage: Sendable, Hashable {
    public private(set) var bytes: [UInt8]

    /// 全部空白
    public init() {
        bytes = [UInt8](repeating: 0x20, count: NCCC8N1.length)
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == NCCC8N1.length else { throw ECRError.badLength(expected: NCCC8N1.length, got: bytes.count) }
        // 端末把沒填的 0x00 當空白（參考程式送出前把 0x00 換成 0x20）
        self.bytes = bytes.map { $0 == 0 ? 0x20 : $0 }
    }

    public init(_ text: String) throws {
        try self.init(bytes: Array(text.utf8))
    }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// 欄位原樣（含空白）
    public subscript(field: ECRField) -> String {
        String(decoding: bytes[field.range], as: UTF8.self)
    }

    /// 欄位去掉前後空白
    public func value(_ field: ECRField) -> String {
        self[field].trimmingCharacters(in: .whitespaces)
    }

    /// 文字欄位：左靠右補空白（商店代號、端末代號、授權碼、訂單編號）
    public mutating func set(_ field: ECRField, text value: String) throws {
        let b = Array(value.utf8)
        guard b.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { throw ECRError.invalidField("\(field.name) 只能放英數字") }
        guard b.count <= field.length else { throw ECRError.invalidField("\(field.name) 最多 \(field.length) 碼") }
        bytes.replaceSubrange(field.range, with: b + [UInt8](repeating: 0x20, count: field.length - b.count))
    }

    /// 數字欄位：右靠左補 0（金額、調閱編號、期數）
    public mutating func set(_ field: ECRField, digits value: String) throws {
        let b = Array(value.utf8)
        guard !b.isEmpty, b.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw ECRError.invalidField("\(field.name) 只能是數字") }
        guard b.count <= field.length else { throw ECRError.invalidField("\(field.name) 最多 \(field.length) 位") }
        bytes.replaceSubrange(field.range, with: [UInt8](repeating: 0x30, count: field.length - b.count) + b)
    }
}

// MARK: - 收銀機送的

/// 收銀機要刷卡機做的事。只填這次要用的欄位，其他空白
public struct ECRRequest: Sendable, Hashable {
    public var transType: ECRTransType
    public var kind: ECRPaymentKind
    public var amount: Money?
    /// 取消：原交易的調閱編號
    public var receiptNo: String?
    /// 退貨：原交易的授權碼
    public var approvalNo: String?
    /// 分期期數
    public var installmentPeriod: Int?
    /// 電子錢包：特店訂單編號
    public var walletOrderId: String?
    /// nil＝照付款工具（信用卡 03、電子票證 06、電子錢包 08）
    public var host: ECRHost?
    /// I：一般；E：要卡號雜湊（電子發票載具）；Q：條碼（1000 長度，不支援）
    public var ecrIndicator: String
    public var versionDate: String

    public init(_ transType: ECRTransType, kind: ECRPaymentKind = .card, amount: Money? = nil, receiptNo: String? = nil,
                approvalNo: String? = nil, installmentPeriod: Int? = nil, walletOrderId: String? = nil, host: ECRHost? = nil,
                ecrIndicator: String = "I", versionDate: String = NCCC8N1.currentVersion) {
        self.transType = transType; self.kind = kind; self.amount = amount; self.receiptNo = receiptNo; self.approvalNo = approvalNo
        self.installmentPeriod = installmentPeriod; self.walletOrderId = walletOrderId; self.host = host
        self.ecrIndicator = ecrIndicator; self.versionDate = versionDate
    }

    public static func sale(_ amount: Money, kind: ECRPaymentKind = .card) -> ECRRequest {
        ECRRequest(.sale, kind: kind, amount: amount)
    }

    public static func installment(_ amount: Money, periods: Int) -> ECRRequest {
        ECRRequest(.installment, kind: .card, amount: amount, installmentPeriod: periods)
    }

    public static func refund(_ amount: Money, kind: ECRPaymentKind = .card, approvalNo: String? = nil, walletOrderId: String? = nil) -> ECRRequest {
        ECRRequest(.refund, kind: kind, amount: amount, approvalNo: approvalNo, walletOrderId: walletOrderId)
    }

    /// 取消：原交易的調閱編號（金額也帶：端末會核對原金額）
    public static func void(receiptNo: String, amount: Money? = nil, kind: ECRPaymentKind = .card) -> ECRRequest {
        ECRRequest(.void, kind: kind, amount: amount, receiptNo: receiptNo)
    }

    public static func walletQuery(orderId: String? = nil) -> ECRRequest {
        ECRRequest(.walletQuery, kind: .wallet, walletOrderId: orderId)
    }

    public static var settlement: ECRRequest { ECRRequest(.settlement) }
    public static var lastTransaction: ECRRequest { ECRRequest(.lastTransaction) }
    public static var echo: ECRRequest { ECRRequest(.echo) }

    /// 組成 400 碼。欄位不對（金額有角分、調閱編號不是數字、分期期數）直接丟錯，不送出去
    public func pack() throws -> ECRMessage {
        var m = ECRMessage()
        try m.set(NCCC8N1.ecrIndicator, text: ecrIndicator)
        try m.set(NCCC8N1.versionDate, digits: versionDate)
        try m.set(NCCC8N1.transType, digits: transType.rawValue)
        if transType.carriesHost || transType == .eTicketBalance {
            try m.set(NCCC8N1.paymentKind, text: kind.rawValue)
        }
        if transType.carriesHost {
            try m.set(NCCC8N1.hostId, digits: (host ?? kind.host).rawValue)
        }
        if transType.needsAmount {
            guard let amount else { throw ECRError.invalidAmount("\(transType.label)要有金額") }
            try m.set(NCCC8N1.amount, digits: ECRAmount.encode(amount))
        } else if let amount {
            try m.set(NCCC8N1.amount, digits: ECRAmount.encode(amount))
        }
        if transType == .void || transType == .eTicketVoidTopUp, receiptNo?.isEmpty ?? true {
            throw ECRError.invalidField("取消要有原交易的調閱編號")
        }
        if let r = receiptNo, !r.isEmpty {
            try m.set(NCCC8N1.receiptNo, digits: r)
        }
        if let a = approvalNo, !a.isEmpty {
            try m.set(NCCC8N1.approvalNo, text: a)
        }
        if transType == .installment {
            guard let p = installmentPeriod, (2...99).contains(p) else { throw ECRError.invalidField("分期期數要 2 到 99 期") }
            try m.set(NCCC8N1.installmentPeriod, digits: String(p))
        }
        if kind == .wallet, let id = walletOrderId, !id.isEmpty {
            try m.set(NCCC8N1.walletOrderId, text: id)
        }
        return m
    }
}

// MARK: - 刷卡機回的

/// 刷卡機回的 400 碼：欄位照版面拆開（不改內容）
public struct ECRResponse: Sendable, Hashable {
    public let message: ECRMessage

    public init(_ message: ECRMessage) {
        self.message = message
    }

    public init(bytes: [UInt8]) throws {
        self.init(try ECRMessage(bytes: bytes))
    }

    public init(_ text: String) throws {
        self.init(try ECRMessage(text))
    }

    public var ecrIndicator: String { message.value(NCCC8N1.ecrIndicator) }
    public var versionDate: String { message.value(NCCC8N1.versionDate) }
    public var transTypeIndicator: String { message.value(NCCC8N1.transTypeIndicator) }
    public var transTypeCode: String { message.value(NCCC8N1.transType) }
    public var transType: ECRTransType? { ECRTransType(rawValue: transTypeCode) }
    public var kindCode: String { message.value(NCCC8N1.paymentKind) }
    public var kind: ECRPaymentKind? { ECRPaymentKind(rawValue: kindCode) }
    public var hostId: String { message.value(NCCC8N1.hostId) }
    public var receiptNo: String { message.value(NCCC8N1.receiptNo) }
    /// 遮起來的卡號（431195******1234）；電子票證、電子錢包各家遮法不同
    public var cardNo: String { message.value(NCCC8N1.cardNo) }
    public var cardExpiry: String { message.value(NCCC8N1.cardExpiry) }
    public var amount: Money? { ECRAmount.decode(message[NCCC8N1.amount]) }
    /// YYMMDD
    public var transDate: String { message.value(NCCC8N1.transDate) }
    /// hhmmss
    public var transTime: String { message.value(NCCC8N1.transTime) }
    public var approvalNo: String { message.value(NCCC8N1.approvalNo) }
    /// 感應的卡別（V、M、J、C、A、D…；電子票證 Z、P、G）
    public var waveIndicator: String { message.value(NCCC8N1.waveIndicator) }
    /// 0000＝成功
    public var responseCode: String { message.value(NCCC8N1.responseCode) }
    public var merchantId: String { message.value(NCCC8N1.merchantId) }
    public var terminalId: String { message.value(NCCC8N1.terminalId) }
    public var expAmount: Money? { ECRAmount.decode(message[NCCC8N1.expAmount]) }
    public var storeId: String { message.value(NCCC8N1.storeId) }
    public var installmentRedeemIndicator: String { message.value(NCCC8N1.installmentRedeemIndicator) }
    public var redeemPaidAmount: Money? { ECRAmount.decode(message[NCCC8N1.redeemPaidAmount]) }
    public var redeemPoints: Int? { Int(message.value(NCCC8N1.redeemPoints)) }
    public var pointsBalance: Int? { Int(message.value(NCCC8N1.pointsBalance)) }
    public var redeemAmount: Money? { ECRAmount.decode(message[NCCC8N1.redeemAmount]) }
    public var installmentPeriod: Int? { Int(message.value(NCCC8N1.installmentPeriod)) }
    public var downPayment: Money? { ECRAmount.decode(message[NCCC8N1.downPayment]) }
    public var installmentPayment: Money? { ECRAmount.decode(message[NCCC8N1.installmentPayment]) }
    public var formalityFee: Money? { ECRAmount.decode(message[NCCC8N1.formalityFee]) }
    /// 電子票證：交易前、後的餘額，自動加值了多少（和分期同一個位置）
    public var balanceBefore: Money? { kind == .eTicket ? downPayment : nil }
    public var balanceAfter: Money? { kind == .eTicket ? installmentPayment : nil }
    public var autoloadAmount: Money? { kind == .eTicket ? formalityFee : nil }
    public var cardTypeCode: String { message.value(NCCC8N1.cardType) }
    public var brand: ECRCardBrand? { ECRCardBrand(rawValue: cardTypeCode) }
    public var batchNo: String { message.value(NCCC8N1.batchNo) }
    /// 結帳：總筆數（放在有效期那一欄）
    public var settlementCount: Int? { transType == .settlement ? Int(cardExpiry) : nil }
    /// 結帳：總金額（放在金額那一欄）
    public var settlementTotal: Money? { transType == .settlement ? amount : nil }

    // 220 起：一般交易
    public var originRRN: String { kind == .wallet ? "" : message.value(NCCC8N1.originRRN) }
    public var cardNoHash: String { kind == .wallet ? "" : message.value(NCCC8N1.cardNoHash) }

    /// 電子錢包交易才有
    public var wallet: ECRWalletBlock? {
        guard kind == .wallet else { return nil }
        return ECRWalletBlock(orderId: message.value(NCCC8N1.walletOrderId), carrier: message.value(NCCC8N1.walletCarrier),
                              refundTradeNo: message.value(NCCC8N1.walletRefundTradeNo),
                              transactionId: message.value(NCCC8N1.walletTransactionId))
    }
}

/// 電子錢包那一塊（220 起）
public struct ECRWalletBlock: Sendable, Hashable {
    /// 特店訂單編號
    public var orderId: String
    /// 電子發票載具
    public var carrier: String
    /// 退貨訂單編號
    public var refundTradeNo: String
    /// 錢包業者的交易序號
    public var transactionId: String
}
