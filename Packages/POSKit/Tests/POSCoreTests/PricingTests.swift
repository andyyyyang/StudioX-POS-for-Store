import Testing
@testable import POSCore

struct PricingTests {
    /// 文件上的例子：珍奶 60×2、雞排 (80＋加起司 10) 折 10 元、整單 9 折、服務費 10%
    func sampleTicket() -> Ticket {
        var t = Ticket(id: "t", number: "A001", deviceId: "d", orderType: .dineIn, serviceChargeBps: 1000, openedAt: Fixture.now, openedBy: "s1", businessDate: "2026-09-21")
        t.lines = [
            Fixture.line("l1", "珍奶", 60, qty: 2),
            Fixture.line("l2", "雞排", 80, mods: [AppliedModifier(groupId: "g", groupName: "加料", optionId: "o", name: "加起司", priceDelta: Money(dollars: 10))],
                         discount: .amount(Money(dollars: 10)), category: "fried"),
            {
                var v = Fixture.line("l3", "薯條", 50)
                v.voided = VoidInfo(reason: "點錯", by: "s1", at: Fixture.now, wasSent: false)
                return v
            }(),
        ]
        t.discount = .percent(1000, reason: "熟客")
        return t
    }

    @Test func totals() {
        let x = sampleTicket().totals
        #expect(x.itemsGross == Money(dollars: 210))
        #expect(x.lineDiscounts == Money(dollars: 10))
        #expect(x.subtotal == Money(dollars: 200))
        #expect(x.orderDiscount == Money(dollars: 20))
        #expect(x.serviceCharge == Money(dollars: 18))
        #expect(x.total == Money(dollars: 198))
        #expect(x.tax == Money(dollars: 9))
        #expect(x.lines.map(\.orderDiscountShare) == [Money(dollars: 12), Money(dollars: 8)])
        #expect(Money.sum(x.lines.map(\.net)) + x.serviceCharge == x.total)
        #expect(x.balance == Money(dollars: 198))
    }

    @Test func cashPaymentAndChange() {
        var t = sampleTicket()
        let p = Payment.cash(id: "p", tendered: Money(dollars: 500), due: t.totals.amountDue, at: Fixture.now, by: "s1", shiftId: "sh")
        #expect(p.amount == Money(dollars: 198))
        #expect(p.change == Money(dollars: 302))
        t.payments = [p]
        #expect(t.totals.isPaidInFull)
    }

    @Test func allocationAlwaysSumsExactly() {
        for total in [1, 7, 33, 100, 999] {
            let shares = TicketTotals.allocate(Money(dollars: total), over: [Money(dollars: 13), Money(dollars: 29), Money(dollars: 58)])
            #expect(Money.sum(shares) == Money(dollars: total))
        }
        #expect(TicketTotals.split(Money(dollars: 1000), ways: 3) == [Money(dollars: 334), Money(dollars: 333), Money(dollars: 333)])
        #expect(TicketTotals.allocate(Money(dollars: 10), over: [.zero, .zero]) == [.zero, .zero])
    }

    @Test func discountNeverExceedsBase() {
        #expect(Discount.amount(Money(dollars: 500)).amount(on: Money(dollars: 120)) == Money(dollars: 120))
        #expect(Discount.percent(10_000).amount(on: Money(dollars: 120)) == Money(dollars: 120))
        #expect(Discount.percent(10_000).label == "招待")
        #expect(Discount.percent(1000).label == "9 折")
        #expect(Discount.percent(1500).label == "85 折")
        #expect(Discount.amount(Money(dollars: 50)).bps(on: Money(dollars: 200)) == 2500)
    }

    @Test func saleRecordBalances() {
        var t = sampleTicket()
        t.payments = [Payment(id: "p", tender: .card, amount: Money(dollars: 198), reference: "123456", at: Fixture.now, by: "s1")]
        let sale = SaleRecord(ticket: t, closedOn: "d", shiftId: "sh", closedAt: Fixture.now, closedBy: "s1", staffName: "Leslie", floor: Fixture.floor)
        #expect(sale.problems.isEmpty)
        #expect(sale.lines.count == 2)
        #expect(sale.voidedItems == 1)
        #expect(sale.voidedAmount == Money(dollars: 50))
        #expect(sale.lines[0].net == Money(dollars: 108))
    }
}
