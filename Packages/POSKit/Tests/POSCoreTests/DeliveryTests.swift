import Foundation
import Testing
@testable import POSCore

/// 外送平台的單（docs/DELIVERY.md）：後台寫的事件重播出外送單、平台代收、接單之後狀態更新、報表分通路
struct DeliveryTests {
    static let placed = Fixture.now

    func order(_ platform: DeliveryPlatform = .ubereats, code: String = "3F2A1", subtotal: Int = 420) -> DeliveryOrder {
        DeliveryOrder(platform: platform, orderId: "ord-\(code)", code: code, placedAt: Self.placed, acceptBy: Self.placed.addingTimeInterval(690),
                      customerName: "王小姐", customerNote: "不要香菜", subtotal: Money(dollars: subtotal),
                      commission: Money(dollars: subtotal).applying(bps: 3_250), payout: nil, estimated: true)
    }

    /// 後台（外送平台裝置）寫的：開單＋品項＋平台代收
    func arrive(_ d: inout Device, ticket: String = "dl1", delivery: DeliveryOrder) -> [POSEvent] {
        let lines = [Fixture.line("l1", "珍珠奶茶", 60, qty: 2), Fixture.line("l2", "鹽酥雞", 80, category: "fried"), Fixture.line("l3", "雞排", 220, category: "fried")]
        return [
            d.emit(.ticketOpened(TicketOpened(ticketId: ticket, number: "UE-\(delivery.code)", orderType: .delivery, businessDate: "2026-09-21",
                                              customerName: delivery.customerName, delivery: delivery)), staff: nil),
            d.emit(.linesAdded(LinesAdded(ticketId: ticket, lines: lines)), staff: nil),
            d.emit(.paymentAdded(PaymentAdded(ticketId: ticket, payment: Payment(id: "p-\(ticket)", tender: .platform, amount: Money(dollars: 420),
                                                                                  reference: "Uber Eats #\(delivery.code)", at: Self.placed, by: "delivery")))),
        ]
    }

    @Test func arrivesPaidAndPending() throws {
        var server = Device("delivery")
        let events = arrive(&server, delivery: order())
        let s = StoreState.replay(events)
        let t = try #require(s.tickets["dl1"])
        #expect(t.delivery?.status == .pending)
        #expect(t.title(floor: Fixture.floor) == "Uber Eats #3F2A1")
        // 平台已經收了錢：不用再收
        #expect(t.totals.isPaidInFull)
        #expect(t.delivery?.secondsToAccept(at: Self.placed.addingTimeInterval(90)) == 600)
    }

    @Test func updatesFlowFromServerAndSurviveClose() throws {
        var server = Device("delivery")
        var ipad = Device("ipad")
        var events = arrive(&server, delivery: order())
        let readyAt = Self.placed.addingTimeInterval(18 * 60)
        events.append(server.emit(.deliveryUpdated(DeliveryUpdated(ticketId: "dl1", status: .accepted, readyAt: readyAt, prepMinutes: 18, acceptedBy: "ipad")), staff: nil))
        ipad.observe(events)
        // 接的那台結帳（先付的），廚房照樣做
        let s1 = StoreState.replay(events)
        let t = try #require(s1.tickets["dl1"])
        #expect(t.delivery?.acceptedBy == "ipad")
        #expect(t.delivery?.minutesToReady(at: Self.placed) == 18)
        let sale = SaleRecord(ticket: t, closedOn: "ipad", shiftId: "sh1", closedAt: ipad.clock, closedBy: "s1", staffName: "Cameron", floor: Fixture.floor)
        events.append(ipad.emit(.ticketClosed(TicketClosed(ticketId: "dl1", sale: sale))))
        // 結帳之後：平台說做好了、外送員到了、拿走了；撥款明細也補上
        server.observe(events)
        events.append(server.emit(.deliveryUpdated(DeliveryUpdated(ticketId: "dl1", status: .ready, courier: Courier(name: "陳先生", status: .arriving))), staff: nil))
        events.append(server.emit(.deliveryUpdated(DeliveryUpdated(ticketId: "dl1", status: .pickedUp, commission: Money(dollars: 140),
                                                                    payout: Money(dollars: 280), estimated: false)), staff: nil))
        let s2 = StoreState.replay(events)
        #expect(s2.tickets["dl1"]?.status == .closed)
        #expect(s2.tickets["dl1"]?.delivery?.status == .pickedUp)
        #expect(s2.tickets["dl1"]?.delivery?.courier?.name == "陳先生")
        // 報表上的那一筆跟著更新（抽成從估的變成平台給的）
        #expect(s2.sales["dl1"]?.delivery?.commission == Money(dollars: 140))
        #expect(s2.sales["dl1"]?.delivery?.estimated == false)
    }

    @Test func eventRoundTripsThroughWireFormat() throws {
        let u = DeliveryUpdated(ticketId: "dl1", status: .ready, readyAt: Self.placed, courier: Courier(name: "陳", status: .arrived, eta: Self.placed))
        let body = EventBody.deliveryUpdated(u)
        #expect(body.type == "delivery.updated")
        #expect(body.ticketId == "dl1")
        let decoded = try EventBody.decode(type: body.type, data: try body.encodedData())
        #expect(decoded == body)
        // 舊的 ticket.opened（沒有 delivery）照樣讀得進來
        let plain = EventBody.ticketOpened(TicketOpened(ticketId: "t", number: "A001", orderType: .takeout, businessDate: "2026-09-21"))
        let back = try EventBody.decode(type: "ticket.opened", data: try plain.encodedData())
        if case .ticketOpened(let o) = back { #expect(o.delivery == nil) } else { Issue.record("不是 ticket.opened") }
    }

    @Test func summarySplitsChannels() throws {
        var server = Device("delivery")
        var events = arrive(&server, delivery: order())
        let t = try #require(StoreState.replay(events).tickets["dl1"])
        let deliverySale = SaleRecord(ticket: t, closedOn: "ipad", shiftId: nil, closedAt: server.clock, closedBy: "s1", staffName: "C", floor: Fixture.floor)
        events.append(server.emit(.ticketClosed(TicketClosed(ticketId: "dl1", sale: deliverySale))))

        var store = Ticket(id: "s1", number: "A001", deviceId: "ipad", orderType: .takeout, lines: [Fixture.line("x", "拿鐵", 120)],
                           openedAt: Fixture.now, openedBy: "s1", businessDate: "2026-09-21")
        store.payments = [Payment(id: "c", tender: .cash, amount: Money(dollars: 120), at: Fixture.now, by: "s1")]
        let storeSale = SaleRecord(ticket: store, closedOn: "ipad", shiftId: nil, closedAt: Fixture.now, closedBy: "s1", staffName: "C", floor: Fixture.floor)

        let summary = SalesSummary(sales: [deliverySale, storeSale], refunds: [], voidedTickets: [], invoices: [], voidedInvoices: [])
        #expect(summary.byChannel.map(\.channel) == ["store", "ubereats"])
        let ue = try #require(summary.byChannel.first { $0.channel == "ubereats" })
        #expect(ue.tickets == 1)
        #expect(ue.total == Money(dollars: 420))
        #expect(ue.commission == Money(dollars: 420).applying(bps: 3_250))
        #expect(ue.net == ue.total - ue.commission)
        #expect(ue.estimated == 1)
        // 平台代收的不是現金（不進錢櫃），但是真的收到的錢
        #expect(!Tender.platform.isCash && !Tender.platform.isInternal)
    }

    @Test func prepAdvisorFollowsKitchenLoad() {
        let a = PrepTimeAdvisor(baseMinutes: 15)
        #expect(a.suggest(pendingItems: 0, orderItems: 2) == 15)
        #expect(a.suggest(pendingItems: 12, orderItems: 3) == 20)
        // 忙碌加的時間、上限
        #expect(PrepTimeAdvisor(baseMinutes: 15, busyExtraMinutes: 10).suggest(pendingItems: 0, orderItems: 0) == 25)
        #expect(a.suggest(pendingItems: 500, orderItems: 0) == 45)
    }

    @Test func invoiceInfoFromPlatform() {
        #expect(DeliveryInvoiceInfo(carrier: "/ABC1234").buyer == .consumer(carrier: .mobileBarcode("/ABC1234")))
        #expect(DeliveryInvoiceInfo(carrier: "/ABC1234", taxId: "22099131").buyer == .business(taxId: "22099131", title: nil))
        #expect(DeliveryInvoiceInfo().buyer == nil)
    }
}
