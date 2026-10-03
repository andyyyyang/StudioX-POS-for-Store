import Foundation

// 買方要怎麼拿發票：結帳時問的那一題。驗證規則放在 POSCore（右側鍵盤輸入統編時即時打勾），
// 號碼、條碼、上傳在 POSInvoice。

/// 載具。JSON：`{"type":"3J0002","id":"/ABC+123"}`
public enum InvoiceCarrier: Codable, Sendable, Hashable {
    /// 手機條碼（/ 開頭 8 碼）：3J0002
    case mobileBarcode(String)
    /// 自然人憑證條碼（2 碼英文＋14 碼數字）：CQ0001
    case citizenCertificate(String)

    /// 財政部的載具類別號碼
    public var typeCode: String {
        switch self {
        case .mobileBarcode: "3J0002"
        case .citizenCertificate: "CQ0001"
        }
    }

    /// 載具顯碼（CarrierId1）與隱碼（CarrierId2）：這兩種載具兩個都放同一串
    public var id: String {
        switch self {
        case .mobileBarcode(let s), .citizenCertificate(let s): s
        }
    }

    public var label: String {
        switch self {
        case .mobileBarcode: "手機條碼"
        case .citizenCertificate: "自然人憑證"
        }
    }

    public var isValid: Bool {
        switch self {
        case .mobileBarcode(let s): InvoiceValidation.isMobileBarcode(s)
        case .citizenCertificate(let s): InvoiceValidation.isCitizenCertificate(s)
        }
    }

    private enum Keys: String, CodingKey { case type, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(String.self, forKey: .id)
        switch try c.decode(String.self, forKey: .type) {
        case "3J0002": self = .mobileBarcode(id)
        case "CQ0001": self = .citizenCertificate(id)
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "不支援的載具：\(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeCode, forKey: .type)
        try c.encode(id, forKey: .id)
    }
}

/// 買方。JSON：
///   `{"kind":"consumer"}`、`{"kind":"consumer","carrier":{"type":"3J0002","id":"/ABC+123"}}`
///   `{"kind":"business","taxId":"22099131","title":"台積電"}`、`{"kind":"donation","loveCode":"919"}`
public enum InvoiceBuyer: Codable, Sendable, Hashable {
    /// 一般消費者：沒有載具就印證明聯
    case consumer(carrier: InvoiceCarrier?)
    /// 打統編（公司報帳）：一定印證明聯（格式 25）
    case business(taxId: String, title: String?)
    /// 捐贈（愛心碼）
    case donation(loveCode: String)

    public static let paper = InvoiceBuyer.consumer(carrier: nil)

    /// 要不要印證明聯（存載具、捐贈的不印；之後客人要可以補印）
    public var printsProof: Bool {
        switch self {
        case .consumer(let carrier): carrier == nil
        case .business: true
        case .donation: false
        }
    }

    public var buyerTaxId: String? {
        if case .business(let id, _) = self { return id }
        return nil
    }

    public var summary: String {
        switch self {
        case .consumer(nil): "紙本證明聯"
        case .consumer(let c?): "\(c.label) \(c.id)"
        case .business(let id, let title): "統編 \(id)" + (title.map { " \($0)" } ?? "")
        case .donation(let code): "捐贈 \(code)"
        }
    }

    /// 合不合規則（回 nil＝可以）
    public var problem: String? {
        switch self {
        case .consumer(nil): nil
        case .consumer(let c?): c.isValid ? nil : "\(c.label)格式不對"
        case .business(let id, _): InvoiceValidation.isTaxId(id) ? nil : "統一編號檢查碼不對"
        case .donation(let code): InvoiceValidation.isLoveCode(code) ? nil : "愛心碼是 3 到 7 位數字"
        }
    }

    private enum Keys: String, CodingKey { case kind, carrier, taxId, title, loveCode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "consumer": self = .consumer(carrier: try c.decodeIfPresent(InvoiceCarrier.self, forKey: .carrier))
        case "business": self = .business(taxId: try c.decode(String.self, forKey: .taxId), title: try c.decodeIfPresent(String.self, forKey: .title))
        case "donation": self = .donation(loveCode: try c.decode(String.self, forKey: .loveCode))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "不支援的買方：\(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .consumer(let carrier):
            try c.encode("consumer", forKey: .kind)
            try c.encodeIfPresent(carrier, forKey: .carrier)
        case .business(let taxId, let title):
            try c.encode("business", forKey: .kind)
            try c.encode(taxId, forKey: .taxId)
            try c.encodeIfPresent(title, forKey: .title)
        case .donation(let code):
            try c.encode("donation", forKey: .kind)
            try c.encode(code, forKey: .loveCode)
        }
    }
}

public enum InvoiceValidation {
    /// 統一編號（8 碼）：財政部的檢查碼。2023 年起改成「加總能被 5 整除」（舊的被 10 整除也一定被 5 整除）；
    /// 第 7 碼是 7 時，那一位的乘積 28 → 2+8 = 10 可以再算成 1 或 0
    public static func isTaxId(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard s.count == 8, digits.count == 8 else { return false }
        let weights = [1, 2, 1, 2, 1, 2, 4, 1]
        var sum = 0
        for i in 0..<8 {
            let p = digits[i] * weights[i]
            sum += p / 10 + p % 10
        }
        if sum % 5 == 0 { return true }
        return digits[6] == 7 && (sum + 1) % 5 == 0
    }

    /// 手機條碼：/ 開頭，後面 7 碼是數字、大寫英文、. + -
    public static func isMobileBarcode(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 8, chars[0] == "/" else { return false }
        return chars.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase || $0 == "." || $0 == "+" || $0 == "-") }
    }

    /// 自然人憑證條碼：2 碼大寫英文＋14 碼數字
    public static func isCitizenCertificate(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 16 else { return false }
        return chars[0..<2].allSatisfy { $0.isASCII && $0.isUppercase } && chars[2...].allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 愛心碼（捐贈碼）：3–7 位數字
    public static func isLoveCode(_ s: String) -> Bool {
        (3...7).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
