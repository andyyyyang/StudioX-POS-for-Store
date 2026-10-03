import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice

struct InvoiceTests {
    static let oct3 = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03 台北

    func ticket(buyer: InvoiceBuyer = .paper) -> Ticket {
        var t = Ticket(id: "t", number: "A001", deviceId: "d", orderType: .dineIn, serviceChargeBps: 1000, openedAt: Self.oct3, openedBy: "s", businessDate: "2026-10-03")
        t.lines = [
            TicketLine(id: "l1", itemId: "i1", name: "珍珠奶茶", unitPrice: Money(dollars: 60),
                       modifiers: [AppliedModifier(groupId: "g", groupName: "甜度", optionId: "o", name: "半糖")], quantity: 2, addedAt: Self.oct3, addedBy: "s"),
            TicketLine(id: "l2", itemId: "i2", name: "雞排", unitPrice: Money(dollars: 80), addedAt: Self.oct3, addedBy: "s"),
        ]
        t.discount = .amount(Money(dollars: 20), reason: "熟客")
        t.invoiceBuyer = buyer
        return t
    }

    let settings = InvoiceSettings(enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", qrKey: "0123456789ABCDEF0123456789ABCDEF",
                                   rolls: [InvoiceRoll(id: "r1", period: "11510", track: "AB", start: 12345650, end: 12345652),
                                           InvoiceRoll(id: "r2", period: "11510", track: "AB", start: 12345700, end: 12345749)])

    @Test func periods() {
        let p = InvoicePeriod(date: Self.oct3)
        #expect(p.code == "11510")
        #expect(p.label == "115年09-10月")
        #expect(p.next.code == "11512")
        #expect(InvoicePeriod(code: "11512")?.next.code == "11602")
        #expect(InvoicePeriod(code: "11502")?.previous.code == "11412")
        #expect(InvoicePeriod(code: "11509") == nil)
        #expect(InvoicePeriod(rocYear: 115, endMonth: 9).code == "11510")
        #expect(TaipeiTime.dayString(p.endsAt) == "2026-10-31")
        #expect(ROCDate.compact(Self.oct3) == "1151003")
    }

    @Test func allocatorWalksRollsInOrder() {
        var a = InvoiceAllocator(rolls: settings.rolls, used: [])
        let period = InvoicePeriod(code: "11510")!
        #expect(a.remaining(period: period) == 53)
        var got: [String] = []
        for _ in 0..<4 {
            let (n, _) = a.next(period: period)!
            got.append(n)
            a.markUsed(n)
        }
        #expect(got == ["AB12345650", "AB12345651", "AB12345652", "AB12345700"])
        #expect(a.remaining(period: period) == 49)
        #expect(a.next(period: period.next) == nil)
        #expect(a.blankRanges(period: period).map { "\($0.track)\($0.start)-\($0.end)" } == ["AB12345701-12345749"])
    }

    @Test func b2cInvoice() throws {
        let t = ticket()
        let inv = try InvoiceBuilder.issue(ticket: t, settings: settings, allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3, randomCode: "1234")
        // 品項 200 − 折扣 20 = 180，服務費 18 → 198
        #expect(inv.totalAmount == Money(dollars: 198))
        #expect(inv.salesAmount == Money(dollars: 198))
        #expect(inv.taxAmount == .zero)
        #expect(inv.items.map(\.description) == ["珍珠奶茶（半糖）", "雞排", "折扣（熟客）", "服務費"])
        #expect(Money.sum(inv.items.map(\.amount)) == inv.totalAmount)
        #expect(inv.printed)
        #expect(inv.number == "AB12345650")
        #expect(InvoiceCodes.barcode(inv) == "11510AB123456501234")
    }

    @Test func b2bInvoiceSplitsTax() throws {
        let inv = try InvoiceBuilder.issue(ticket: ticket(buyer: .business(taxId: "22099131", title: "台積電")), settings: settings,
                                           allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3, randomCode: "1234")
        #expect(inv.salesAmount == Money(dollars: 189))
        #expect(inv.taxAmount == Money(dollars: 9))
        #expect(inv.isB2B)
        let proof = InvoiceProof(invoice: inv, storeName: "晨麥", qrKey: settings.qrKey)
        #expect(proof.formatCode == "格式 25")
        #expect(proof.buyer == "買方 22099131")
        #expect(proof.numberLabel == "AB-12345650")
        #expect(proof.periodLabel == "115年09-10月")
    }

    @Test func refusesBadBuyerAndEmptyRolls() {
        #expect(throws: InvoiceError.invalidBuyer("統一編號檢查碼不對")) {
            try InvoiceBuilder.issue(ticket: ticket(buyer: .business(taxId: "12345678", title: nil)), settings: settings,
                                     allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3)
        }
        #expect(throws: InvoiceError.noNumbers(period: "11510")) {
            try InvoiceBuilder.issue(ticket: ticket(), settings: settings, allocator: InvoiceAllocator(rolls: [], used: []), deviceId: "d", at: Self.oct3)
        }
        var off = settings
        off.sellerTaxId = "123"
        #expect(throws: InvoiceError.notConfigured("後台的賣方統一編號不對")) {
            try InvoiceBuilder.issue(ticket: ticket(), settings: off, allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3)
        }
    }

    @Test func qrLayout() throws {
        let inv = try InvoiceBuilder.issue(ticket: ticket(), settings: settings, allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3, randomCode: "1234")
        let (left, right) = try #require(InvoiceCodes.qrPair(inv, keyHex: settings.qrKey!))
        // 固定欄位：10+7+4+8+8+8+8+24 = 77 碼
        let header = String(left.prefix(77))
        let expectedPrefix: String = ["AB12345650", "1151003", "1234", "000000c6", "000000c6", "00000000", "04595257"].joined()
        #expect(header.hasPrefix(expectedPrefix))
        #expect(left.dropFirst(77).hasPrefix(":**********:4:4:1:"))
        #expect(right.hasPrefix("**"))
        #expect(left.utf8.count <= 200 && right.utf8.count <= 200)
        // 加密驗證資訊：同一把金鑰、同樣的號碼＋隨機碼，結果固定
        let v = try #require(InvoiceCodes.verification(number: "AB12345650", randomCode: "1234", keyHex: settings.qrKey!))
        #expect(v.count == 24)
        #expect(header.hasSuffix(v))
        #expect(InvoiceCodes.verification(number: "AB12345650", randomCode: "1234", keyHex: "nothex") == nil)
    }

    @Test func longItemListOverflowsToRightThenDrops() throws {
        var t = ticket()
        t.discount = nil
        t.lines = (1...30).map { i in TicketLine(id: "l\(i)", itemId: "i\(i)", name: "招牌滷肉飯大碗加蛋\(i)", unitPrice: Money(dollars: 50), addedAt: Self.oct3, addedBy: "s") }
        let inv = try InvoiceBuilder.issue(ticket: t, settings: settings, allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3, randomCode: "0001")
        let (left, right) = try #require(InvoiceCodes.qrPair(inv, keyHex: settings.qrKey!))
        #expect(left.utf8.count <= 200)
        #expect(right.utf8.count <= 200)
        let parts = left.dropFirst(77).split(separator: ":", omittingEmptySubsequences: false)
        let encoded = Int(parts[2])!, total = Int(parts[3])!
        #expect(total == 31) // 30 品項＋服務費
        #expect(encoded < total)
        #expect(encoded > 0)
    }

    @Test func refundAction() throws {
        let inv = try InvoiceBuilder.issue(ticket: ticket(), settings: settings, allocator: InvoiceAllocator(rolls: settings.rolls, used: []), deviceId: "d", at: Self.oct3)
        #expect(InvoiceBuilder.refundAction(invoice: inv, isFullRefund: true, at: Self.oct3.addingTimeInterval(3600)) == .void)
        #expect(InvoiceBuilder.refundAction(invoice: inv, isFullRefund: false, at: Self.oct3) == .allowance)
        #expect(InvoiceBuilder.refundAction(invoice: inv, isFullRefund: true, at: Self.oct3.addingTimeInterval(40 * 86_400)) == .allowance)
        #expect(InvoiceBuilder.refundAction(invoice: nil, isFullRefund: true, at: Self.oct3) == .none)
        let refund = Refund(id: "r", amount: Money(dollars: 60), tender: .cash, lines: [RefundLine(lineId: "l1", quantity: 1, amount: Money(dollars: 60))],
                            reason: "飲料灑了", invoiceAction: .allowance, at: Self.oct3, by: "s")
        let a = InvoiceBuilder.allowance(for: inv, refund: refund, ticket: ticket(), number: "A1-0001", at: Self.oct3)
        #expect(a.items.first?.description == "珍珠奶茶")
        #expect(a.total == Money(dollars: 60))
    }

    @Test func code39() {
        #expect(Code39.canEncode("11510AB123456501234"))
        #expect(!Code39.canEncode("中文"))
        // 每個字 9 條＋字間 1 條；前後各一個 *
        let m = Code39.modules("AB")
        #expect(m.count == 4 * 9 + 3)
        // 每個字：3 寬 6 窄 → 寬度 3*3+6 = 15
        #expect(Code39.modules("0").prefix(9).reduce(0, +) == 15)
        let row = Code39.row("11510AB123456501234", narrow: 1, ratio: 3)
        #expect(row.first == true && row.last == true)
        #expect(row.count == (21 * 15) + 20)
    }
}
