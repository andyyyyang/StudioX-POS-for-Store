import Foundation
import POSCore

/// 電子發票證明聯上的一維條碼與兩個 QR Code（財政部「電子發票證明聯一維及二維條碼規格說明」）
public enum InvoiceCodes {
    /// 一維條碼（Code 39）：期別 5 碼＋字軌號碼 10 碼＋隨機碼 4 碼，共 19 碼
    public static func barcode(_ inv: EInvoice) -> String {
        inv.period + inv.number + inv.randomCode
    }

    /// 財政部 QR Code 產生工具固定用的 IV
    static let iv: [UInt8] = Array(Data(base64Encoded: "Dt8lyToo17X/XkXaQvihuA==") ?? Data(count: 16))

    /// 加密驗證資訊：AES-128-CBC(發票號碼 10 碼＋隨機碼 4 碼)，Base64 後 24 碼
    public static func verification(number: String, randomCode: String, keyHex: String) -> String? {
        guard let key = Crypto.bytes(hex: keyHex), let aes = Crypto.AES128(key: key) else { return nil }
        let ct = aes.encryptCBC(Array((number + randomCode).utf8), iv: iv)
        return Data(ct).base64EncodedString()
    }

    /// 金額 → 8 碼十六進位（大寫不分；財政部範例是小寫）
    static func hex8(_ m: Money) -> String {
        String(format: "%08x", max(m.dollars, 0))
    }

    /// 兩個 QR Code 的內容。
    ///
    /// 左邊：發票號碼(10) 開立日期(7，民國年) 隨機碼(4) 銷售額(8，16 進位) 總計額(8，16 進位) 買方統編(8) 賣方統編(8) 加密驗證資訊(24)
    ///      :營業人自行使用區(10):二維條碼記載完整品目筆數:該張發票交易品目總筆數:中文編碼參數(1＝UTF-8):品名:數量:單價:…
    /// 右邊：** 開頭，接著放不下的品項。
    /// 每個 QR Code 不超過 maxBytes 位元組（證明聯 5.7 公分寬，太長的 QR Code 印出來掃不到）；放不下的品項不放（筆數照實寫）
    public static func qrPair(_ inv: EInvoice, keyHex: String, maxBytes: Int = 200) -> (left: String, right: String)? {
        guard let verification = verification(number: inv.number, randomCode: inv.randomCode, keyHex: keyHex) else { return nil }
        let buyer = inv.buyer.buyerTaxId ?? "00000000"
        let header = inv.number + ROCDate.compact(inv.issuedAt) + inv.randomCode + hex8(inv.salesAmount + inv.zeroTaxSalesAmount + inv.freeTaxSalesAmount)
            + hex8(inv.totalAmount) + buyer + inv.sellerTaxId + verification

        // 品名裡的「:」會被當成分隔，換成全形
        let fields = inv.items.map { item in
            let name = item.description.replacingOccurrences(of: ":", with: "：")
            return "\(name):\(item.quantity):\(item.unitPrice.dollars)"
        }

        func bytes(_ s: String) -> Int { s.utf8.count }
        var leftItems: [String] = [], rightItems: [String] = []
        // 先算左邊的固定部分（筆數最多兩位數，先用兩位估）
        let leftFixedBudget = maxBytes - bytes(header) - bytes(":**********:99:99:1:")
        var used = 0
        var index = 0
        while index < fields.count {
            let cost = bytes(fields[index]) + (leftItems.isEmpty ? 0 : 1)
            guard used + cost <= leftFixedBudget else { break }
            leftItems.append(fields[index])
            used += cost
            index += 1
        }
        var rightUsed = 2
        while index < fields.count {
            let cost = bytes(fields[index]) + (rightItems.isEmpty ? 0 : 1)
            guard rightUsed + cost <= maxBytes else { break }
            rightItems.append(fields[index])
            rightUsed += cost
            index += 1
        }
        let encoded = leftItems.count + rightItems.count
        let left = header + ":**********:\(encoded):\(inv.items.count):1:" + leftItems.joined(separator: ":")
        let right = "**" + rightItems.joined(separator: ":")
        return (left, right)
    }
}

/// Code 39（一維條碼）：每個字 9 條（5 黑 4 白），其中 3 條是寬的。印點陣圖的時候用
public enum Code39 {
    /// 每個字的寬窄：n＝窄、w＝寬，黑白交錯、從黑開始
    static let patterns: [Character: String] = [
        "0": "nnnwwnwnn", "1": "wnnwnnnnw", "2": "nnwwnnnnw", "3": "wnwwnnnnn", "4": "nnnwwnnnw",
        "5": "wnnwwnnnn", "6": "nnwwwnnnn", "7": "nnnwnnwnw", "8": "wnnwnnwnn", "9": "nnwwnnwnn",
        "A": "wnnnnwnnw", "B": "nnwnnwnnw", "C": "wnwnnwnnn", "D": "nnnnwwnnw", "E": "wnnnwwnnn",
        "F": "nnwnwwnnn", "G": "nnnnnwwnw", "H": "wnnnnwwnn", "I": "nnwnnwwnn", "J": "nnnnwwwnn",
        "K": "wnnnnnnww", "L": "nnwnnnnww", "M": "wnwnnnnwn", "N": "nnnnwnnww", "O": "wnnnwnnwn",
        "P": "nnwnwnnwn", "Q": "nnnnnnwww", "R": "wnnnnnwwn", "S": "nnwnnnwwn", "T": "nnnnwnwwn",
        "U": "wwnnnnnnw", "V": "nwwnnnnnw", "W": "wwwnnnnnn", "X": "nwnnwnnnw", "Y": "wwnnwnnnn",
        "Z": "nwwnwnnnn", "-": "nwnnnnwnw", ".": "wwnnnnwnn", " ": "nwwnnnwnn", "*": "nwnnwnwnn",
        "$": "nwnwnwnnn", "/": "nwnwnnnwn", "+": "nwnnnwnwn", "%": "nnnwnwnwn",
    ]

    public static func canEncode(_ s: String) -> Bool { s.uppercased().allSatisfy { patterns[$0] != nil && $0 != "*" } }

    /// 每一條的寬度（以「窄」為 1 單位、寬為 ratio），黑白交錯從黑開始；前後加 *，字之間一個窄白
    public static func modules(_ text: String, ratio: Int = 3) -> [Int] {
        var out: [Int] = []
        let chars = ["*"] + Array(text.uppercased()) + ["*"]
        for (i, ch) in chars.enumerated() {
            guard let p = patterns[ch] else { continue }
            out += p.map { $0 == "w" ? ratio : 1 }
            if i < chars.count - 1 { out.append(1) }
        }
        return out
    }

    /// 黑白點的一列（true＝黑）；narrow：窄條幾個點
    public static func row(_ text: String, narrow: Int = 2, ratio: Int = 3) -> [Bool] {
        var bits: [Bool] = []
        for (i, w) in modules(text, ratio: ratio).enumerated() {
            bits += [Bool](repeating: i % 2 == 0, count: w * narrow)
        }
        return bits
    }
}
