import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice
@testable import POSSync

/// 大部分資料在後台：iPad 只留最近兩天、還沒送出的、還開著的、這一期與上一期的發票
struct RetentionTests {
    static let now = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03 台北

    func invoice(_ number: String, ticket: String, at: Date) -> EInvoice {
        EInvoice(number: number, randomCode: "1234", period: InvoicePeriod(date: at).code, issuedAt: at, sellerTaxId: "04595257", sellerName: "晨麥",
                 sellerAddress: "", buyer: .paper, buyerName: nil, items: [], salesAmount: Money(dollars: 100), zeroTaxSalesAmount: .zero,
                 freeTaxSalesAmount: .zero, taxAmount: .zero, totalAmount: Money(dollars: 100), taxType: 1, taxRateBps: 500, printed: true,
                 ticketId: ticket, deviceId: "A", rollId: "r1")
    }

    @Test func keepsOnlyWhatTheIPadNeeds() throws {
        let j = try EventJournal(directory: tempDir(), deviceId: "A")
        let old = Self.now.addingTimeInterval(-5 * 86_400)
        // 5 天前：結了帳的單（已送出）＋它的發票（同一期）
        _ = try j.append(.ticketOpened(TicketOpened(ticketId: "old", number: "A001", orderType: .takeout, businessDate: "2026-09-28")), staffId: "s", at: old)
        _ = try j.append(.invoiceIssued(InvoiceIssued(ticketId: "old", invoice: invoice("AB12345650", ticket: "old", at: old))), staffId: "s", at: old)
        _ = try j.append(.ticketVoided(TicketVoided(ticketId: "old", reason: "測試")), staffId: "s", at: old)
        // 5 天前開的、還沒結的單
        _ = try j.append(.ticketOpened(TicketOpened(ticketId: "open", number: "A002", orderType: .dineIn, tableIds: ["t1"], businessDate: "2026-09-28")), staffId: "s", at: old)
        // 今天
        _ = try j.append(.ticketOpened(TicketOpened(ticketId: "today", number: "A001", orderType: .takeout, businessDate: "2026-10-03")), staffId: "s", at: Self.now)
        try j.markPushed(through: 5)
        // 5 天前、還沒送到後台的（不可能刪）
        _ = try j.append(.itemAvailability(ItemAvailability(itemId: "x", available: false)), staffId: "s", at: old)

        let state = StoreState.replay(j.allEvents)
        let removed = try j.compact(now: Self.now, state: state)
        #expect(removed == 2) // 舊單的開單與作廢
        let left = Set(j.allEvents.map(\.type))
        #expect(left.contains("invoice.issued"))
        #expect(j.allEvents.filter { $0.type == "ticket.opened" }.count == 2)
        #expect(j.allEvents.contains { $0.type == "item.availability" })
        // 號碼還認得：下一張不會重號
        let after = StoreState.replay(j.allEvents)
        let alloc = InvoiceAllocator(rolls: [InvoiceRoll(id: "r1", period: "11510", track: "AB", start: 12345650, end: 12345699)], state: after)
        #expect(alloc.next(period: InvoicePeriod(code: "11510")!)?.number == "AB12345651")
        // 中間少的那段都已經送到後台：鏈照樣算完整
        #expect(j.verifyChain() == nil)
    }

    /// 後台說這一段用到哪：本機的事件刪光了也不會重號
    @Test func serverHighWaterMarkPreventsReuse() {
        let roll = InvoiceRoll(id: "r1", period: "11510", track: "AB", start: 12345650, end: 12345699, usedThrough: 12345660)
        let a = InvoiceAllocator(rolls: [roll], used: [])
        #expect(a.next(period: InvoicePeriod(code: "11510")!)?.number == "AB12345661")
        #expect(a.remaining(period: InvoicePeriod(code: "11510")!) == 39)
        let b = InvoiceAllocator(rolls: [roll], used: ["AB12345670"])
        #expect(b.next(period: InvoicePeriod(code: "11510")!)?.number == "AB12345671")
        // 不在這一段的數字不算
        let c = InvoiceAllocator(rolls: [InvoiceRoll(id: "r2", period: "11510", track: "AB", start: 1, end: 50, usedThrough: 999)], used: [])
        #expect(c.next(period: InvoicePeriod(code: "11510")!)?.number == "AB00000001")
    }

    @Test func dayHistoryUsesTheSameReport() throws {
        let t = Ticket(id: "t", number: "A001", deviceId: "A", orderType: .takeout,
                       lines: [TicketLine(id: "l", itemId: "i", name: "珍奶", unitPrice: Money(dollars: 60), quantity: 2, addedAt: Self.now, addedBy: "s")],
                       payments: [Payment(id: "p", tender: .cash, amount: Money(dollars: 120), at: Self.now, by: "s")],
                       openedAt: Self.now, openedBy: "s", businessDate: "2026-10-03")
        let sale = SaleRecord(ticket: t, closedOn: "A", shiftId: nil, closedAt: Self.now, closedBy: "s", staffName: "Leslie", floor: .empty)
        let refund = Refund(id: "r", amount: Money(dollars: 60), tender: .cash, reason: "退一杯", invoiceAction: .none, at: Self.now, by: "s")
        let h = DayHistory(businessDate: "2026-10-03", sales: [sale], refunds: [TicketRefund(ticketId: "t", refund: refund)],
                           voidedTickets: [VoidedTicketSummary(ticketId: "v", number: "A002", items: 3, amount: Money(dollars: 90), reason: "客人走了")],
                           invoiceNumbers: ["AB12345650", "AB12345651"], voidedInvoiceNumbers: ["AB12345651"], checkIns: 4)
        let s = h.summary
        #expect(s.total == Money(dollars: 120))
        #expect(s.net == Money(dollars: 60))
        #expect(s.voidedTickets == 1 && s.voidedItems == 3 && s.voidedAmount == Money(dollars: 90))
        #expect(s.invoiceRanges == ["AB12345650–AB12345651"])
        #expect(s.invoicesVoided == 1)
        #expect(s.checkIns == 4)
        #expect(h.refunds(of: "t").count == 1)
        // 來回 JSON
        let round = try EventCoding.decoder().decode(DayHistory.self, from: EventCoding.encoder().encode(h))
        #expect(round == h)
    }

    @Test func workstations() throws {
        #expect(DeviceRole.register.hasDrawer && DeviceRole.register.takesPayment)
        #expect(DeviceRole.handheld.takesPayment && !DeviceRole.handheld.hasDrawer)
        #expect(!DeviceRole.reception.takesPayment && DeviceRole.reception.takesOrders)
        #expect(DeviceRole.expo.isKitchen && DeviceRole.kitchen.isKitchen)
        // 新版後台的崗位：當作結帳櫃台
        let d = try JSONDecoder().decode([DeviceRole].self, from: Data(#"["kitchen","drive-thru"]"#.utf8))
        #expect(d == [.kitchen, .register])
    }
}
