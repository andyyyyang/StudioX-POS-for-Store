import Foundation
import POSCore

/// 電子發票證明聯的內容（5.7 公分寬的那一張）。App 照這個畫成點陣圖印出來、也在畫面上預覽。
///
///   ┌──────────────────────┐
///   │        店名 / Logo         │
///   │      電子發票證明聯         │  （補印時：電子發票證明聯補印）
///   │     115年09-10月          │
///   │     AB-12345678          │
///   │ 2026-10-03 14:05:22  格式 25 │  （打統編才有「格式 25」）
///   │ 隨機碼 1234     總計 1,280  │
///   │ 賣方 12345678  買方 22099131 │  （打統編才有買方）
///   │ ║║│║║│││║║│║║││║│║║│ │  Code 39
///   │  ▣▣▣▣      ▣▣▣▣       │  左 QR、右 QR
///   └──────────────────────┘
public struct InvoiceProof: Sendable, Hashable {
    public var storeName: String
    public var heading: String
    public var periodLabel: String
    public var numberLabel: String
    public var dateTime: String
    /// 打統編的發票：格式 25
    public var formatCode: String?
    public var randomCode: String
    public var total: String
    public var seller: String
    public var buyer: String?
    public var barcode: String
    public var qrLeft: String?
    public var qrRight: String?

    public init(invoice inv: EInvoice, storeName: String, qrKey: String?, reprint: Bool = false) {
        self.storeName = storeName
        heading = reprint ? "電子發票證明聯補印" : "電子發票證明聯"
        let period = InvoicePeriod(code: inv.period) ?? InvoicePeriod(date: inv.issuedAt)
        periodLabel = period.label
        numberLabel = inv.stamp.display
        dateTime = TaipeiTime.dayString(inv.issuedAt) + " " + TaipeiTime.timeString(inv.issuedAt)
        formatCode = inv.isB2B ? "格式 25" : nil
        randomCode = "隨機碼 \(inv.randomCode)"
        total = "總計 \(inv.totalAmount.plain)"
        seller = "賣方 \(inv.sellerTaxId)"
        buyer = inv.buyer.buyerTaxId.map { "買方 \($0)" }
        barcode = InvoiceCodes.barcode(inv)
        if let key = qrKey, let pair = InvoiceCodes.qrPair(inv, keyHex: key) {
            qrLeft = pair.left
            qrRight = pair.right
        }
    }
}
