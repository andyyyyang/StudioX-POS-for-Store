import Foundation
import Testing
@testable import POSCore

/// 服飾、美業、健身：模式、規格、會員帳戶（儲值金、課程卡、會籍）、報到、換貨、業績
struct IndustryTests {
    static let member = MemberRef(id: "m1", phone: "0912345678", name: "王小美")

    func openSalon(_ d: inout Device, ticket: String = "s1", member: MemberRef? = IndustryTests.member) -> POSEvent {
        d.emit(.ticketOpened(TicketOpened(ticketId: ticket, number: "A00\(ticket.suffix(1))", orderType: .takeout, businessDate: "2026-09-21",
                                          serviceMode: .salon, member: member)))
    }

    static let cut = PassSpec(kind: .visits, visits: 10, validDays: 180, itemIds: ["cut"])
    static let monthly = PassSpec(kind: .period, validDays: 30, checkIn: true)
    static let tenClasses = PassSpec(kind: .visits, visits: 10, validDays: 90, categoryIds: ["classes"], checkIn: true)

    func close(_ d: inout Device, _ events: inout [POSEvent], _ ticket: String, payments: [Payment]) throws -> SaleRecord {
        for p in payments { events.append(d.emit(.paymentAdded(PaymentAdded(ticketId: ticket, payment: p)))) }
        let s = StoreState.replay(events)
        let t = try #require(s.tickets[ticket])
        let sale = SaleRecord(ticket: t, closedOn: d.id, shiftId: "sh1", closedAt: d.clock, closedBy: "s1", staffName: "Cameron", floor: Fixture.floor)
        events.append(d.emit(.ticketClosed(TicketClosed(ticketId: ticket, sale: sale))))
        return sale
    }

    func pay(_ id: String, _ tender: Tender, _ dollars: Int, at: Date, change: Int = 0) -> Payment {
        Payment(id: id, tender: tender, amount: Money(dollars: dollars), change: Money(dollars: change), at: at, by: "s1", shiftId: "sh1")
    }

    // MARK: 模式

    @Test func modesDecideTheFlow() {
        #expect(ServiceMode.salon.payFirst == false)
        #expect(ServiceMode.salon.home == .appointments)
        #expect(ServiceMode.salon.staffPerLine)
        #expect(ServiceMode.fitness.home == .checkIn)
        #expect(ServiceMode.fitness.usesCheckIn && ServiceMode.fitness.usesClasses)
        #expect(ServiceMode.apparel.usesExchanges && ServiceMode.apparel.staffPerTicket)
        #expect(!ServiceMode.apparel.usesKitchen && !ServiceMode.apparel.showsOrderType)
        #expect(ServiceMode.tableService.home == .floor)
        #expect(ServiceMode.counter.home == .order)
        // 不收內用服務費
        #expect(ServiceMode.salon.defaultOrderType == .takeout)
    }

    @Test func titleUsesCustomerForNonFoodModes() {
        var t = Ticket(id: "t", number: "A007", deviceId: "d", orderType: .takeout, openedAt: Fixture.now, openedBy: "s", businessDate: "2026-09-21", serviceMode: .salon)
        #expect(t.title(floor: Fixture.floor) == "A007")
        t.member = Self.member
        #expect(t.title(floor: Fixture.floor) == "王小美")
        t.serviceMode = .counter
        #expect(t.title(floor: Fixture.floor) == "外帶 A007")
    }

    // MARK: 規格

    @Test func variantsMatchTagBarcodes() throws {
        let jeans = MenuItem(id: "jeans", categoryId: "bottoms", name: "直筒牛仔褲", price: Money(dollars: 1280), optionNames: ["顏色", "尺寸"], variants: [
            ItemVariant(id: "v1", options: ["深藍", "S"], sku: "JN-01-S", barcode: "4710000000011", stock: 2),
            ItemVariant(id: "v2", options: ["深藍", "M"], sku: "JN-01-M", barcode: "4710000000012", stock: 0),
            ItemVariant(id: "v3", options: ["黑", "M"], barcode: "4710000000022", price: Money(dollars: 1380), stock: 5),
        ])
        let catalog = Catalog(categories: [MenuCategory(id: "bottoms", name: "褲子")], items: [jeans])
        let m = try #require(catalog.match(code: "4710000000022"))
        #expect(m.item.id == "jeans")
        #expect(m.variant?.id == "v3")
        #expect(m.item.price(of: m.variant) == Money(dollars: 1380))
        #expect(catalog.match(code: "JN-01-S")?.variant?.id == "v1")
        #expect(catalog.lookup(code: "4710000000012")?.id == "jeans")
        #expect(jeans.optionValues(0) == ["深藍", "黑"])
        #expect(jeans.optionValues(1) == ["S", "M"])
        #expect(jeans.variant(matching: ["黑", "M"])?.id == "v3")
        #expect(jeans.variant(matching: ["黑", "S"]) == nil)
        #expect(jeans.totalStock == 7)
        #expect(catalog.search("jn-01-m").map(\.id) == ["jeans"])

        let line = TicketLine(id: "l", itemId: "jeans", name: "直筒牛仔褲", unitPrice: Money(dollars: 1380), addedAt: Fixture.now, addedBy: "s", skuId: "v3", variantName: "黑・M")
        #expect(line.displayName == "直筒牛仔褲 黑・M")
        var other = line
        other.id = "l2"
        #expect(line.canMerge(with: other))
        other.skuId = "v1"
        #expect(!line.canMerge(with: other))
    }

    // MARK: 會員帳戶

    @Test func storedValuePassesAndRedemption() throws {
        var d = Device("A")
        var events = [openSalon(&d)]
        // 儲 10,000 送 1,000、買一張 10 次剪髮卡（3,000）
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "s1", lines: [
            TicketLine(id: "top", itemId: "sv10k", name: "儲值 10,000 送 1,000", unitPrice: Money(dollars: 10_000), addedAt: d.clock, addedBy: "s1",
                       kind: .storedValue, credit: Money(dollars: 11_000)),
            TicketLine(id: "card", itemId: "cut10", name: "剪髮 10 次卡", unitPrice: Money(dollars: 3_000), addedAt: d.clock, addedBy: "s1",
                       kind: .pass, pass: Self.cut, commissionBps: 500),
        ]))))
        let s1 = try close(&d, &events, "s1", payments: [pay("p1", .card, 13_000, at: d.clock)])
        #expect(s1.total == Money(dollars: 13_000))

        var state = StoreState.replay(events)
        var acct = state.account(memberId: "m1", server: .empty, included: [])
        #expect(acct.wallet == Money(dollars: 11_000))
        let card = try #require(acct.passes.first)
        #expect(card.id == "card")
        #expect(card.remaining == 10)
        #expect(card.unitValue == Money(dollars: 300))
        #expect(card.isUsable(at: d.clock))
        #expect(card.statusText(at: d.clock).hasPrefix("剩 10 次"))

        // 下一次來：剪髮用卡抵、染髮 2,500 用儲值金付
        events.append(openSalon(&d, ticket: "s2"))
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "s2", lines: [
            TicketLine(id: "c1", itemId: "cut", name: "剪髮", categoryId: "hair", unitPrice: Money(dollars: 600), addedAt: d.clock, addedBy: "s1",
                       kind: .service, staffId: "stylist", assistantId: "asst", durationMinutes: 60,
                       redeem: PassRedemption(passId: card.id, name: card.name, value: card.unitValue), commissionBps: 3000),
            TicketLine(id: "c2", itemId: "dye", name: "染髮", categoryId: "hair", unitPrice: Money(dollars: 2_500), addedAt: d.clock, addedBy: "s1",
                       kind: .service, staffId: "stylist", durationMinutes: 120, commissionBps: 3000),
        ]))))
        state = StoreState.replay(events)
        let open2 = try #require(state.tickets["s2"])
        #expect(open2.totals.total == Money(dollars: 2_500))
        #expect(open2.lines[0].gross == .zero)
        let s2 = try close(&d, &events, "s2", payments: [pay("p2", .prepaid, 2_500, at: d.clock)])

        state = StoreState.replay(events)
        acct = state.account(memberId: "m1", server: .empty, included: [])
        #expect(acct.wallet == Money(dollars: 8_500))
        #expect(acct.passes.first?.remaining == 9)
        #expect(acct.passes(covering: "cut", categoryId: "hair", at: d.clock).count == 1)
        #expect(acct.passes(covering: "dye", categoryId: "hair", at: d.clock).isEmpty)

        // 後台說它已經算進第一張單：iPad 只補第二張的
        let firstCloseId = try #require(events.first { if case .ticketClosed(let c) = $0.body { c.ticketId == "s1" } else { false } }?.id)
        let server = MemberAccount(wallet: Money(dollars: 11_000), passes: [card])
        let merged = state.account(memberId: "m1", server: server, included: [firstCloseId])
        #expect(merged.wallet == Money(dollars: 8_500))
        #expect(merged.passes.first?.remaining == 9)

        // 業績：設計師的服務實收 2,500＋卡抵的價值 300，抽成 30%；助理記一次
        let summary = SalesSummary(sales: [s1, s2], refunds: [], voidedTickets: [], invoices: [], voidedInvoices: [])
        let stylist = try #require(summary.byStaff.first { $0.staffId == "stylist" })
        #expect(stylist.services == Money(dollars: 2_500))
        #expect(stylist.redeemed == Money(dollars: 300))
        #expect(stylist.performance == Money(dollars: 2_800))
        #expect(stylist.commission == Money(dollars: 840))
        #expect(summary.byStaff.first { $0.staffId == "asst" }?.assists == 1)
        // 賣卡的人（開單的 s1）抽 5%
        #expect(summary.byStaff.first { $0.staffId == "s1" }?.commission == Money(dollars: 150))
        #expect(summary.prepaidSold == Money(dollars: 10_000))
        #expect(summary.passesSold == Money(dollars: 3_000))
        #expect(summary.prepaidUsed == Money(dollars: 2_500))
        #expect(summary.redeemedValue == Money(dollars: 300))
        #expect(summary.received == Money(dollars: 13_000))
        #expect(summary.revenue == Money(dollars: 5_500))
        #expect(summary.byMode["salon"] == Money(dollars: 15_500))
    }

    @Test func refundsReverseAccountMoves() throws {
        var d = Device("A")
        var events = [openSalon(&d)]
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "s1", lines: [
            TicketLine(id: "card", itemId: "cut10", name: "剪髮 10 次卡", unitPrice: Money(dollars: 3_000), quantity: 2, addedAt: d.clock, addedBy: "s1",
                       kind: .pass, pass: Self.cut),
            TicketLine(id: "top", itemId: "sv", name: "儲值 1,000", unitPrice: Money(dollars: 1_000), addedAt: d.clock, addedBy: "s1", kind: .storedValue),
        ]))))
        let sale = try close(&d, &events, "s1", payments: [pay("p1", .cash, 7_000, at: d.clock)])
        var state = StoreState.replay(events)
        #expect(state.account(memberId: "m1", server: .empty, included: []).passes.map(\.id) == ["card#1", "card#2"])
        #expect(state.account(memberId: "m1", server: .empty, included: []).wallet == Money(dollars: 1_000))

        // 退一張卡＋儲值
        let refund = Refund(id: "r1", amount: Money(dollars: 4_000), tender: .cash,
                            lines: [RefundLine(lineId: "card", quantity: 1, amount: Money(dollars: 3_000)), RefundLine(lineId: "top", quantity: 1, amount: Money(dollars: 1_000))],
                            reason: "不想要了", invoiceAction: .none, at: d.clock, by: "s1", shiftId: "sh1")
        events.append(d.emit(.saleRefunded(SaleRefunded(ticketId: "s1", refund: refund))))
        state = StoreState.replay(events)
        let acct = state.account(memberId: "m1", server: .empty, included: [])
        #expect(acct.wallet == .zero)
        #expect(acct.passes.first { $0.id == "card#2" }?.status == .cancelled)
        #expect(acct.passes.first { $0.id == "card#1" }?.status == .active)
        #expect(sale.refundAmount(lineId: "card", quantity: 1) == Money(dollars: 3_000))
        #expect(sale.refundedQuantities([refund]) == ["card": 1, "top": 1])
    }

    @Test func gymCheckInAndMembershipRenewal() throws {
        var d = Device("A")
        var events: [POSEvent] = []
        events.append(d.emit(.ticketOpened(TicketOpened(ticketId: "g1", number: "A001", orderType: .takeout, businessDate: "2026-09-21", serviceMode: .fitness, member: Self.member))))
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "g1", lines: [
            TicketLine(id: "month", itemId: "m30", name: "月卡", unitPrice: Money(dollars: 1_500), addedAt: d.clock, addedBy: "s1", kind: .pass, pass: Self.monthly),
            TicketLine(id: "ten", itemId: "c10", name: "團課 10 堂", unitPrice: Money(dollars: 2_000), addedAt: d.clock, addedBy: "s1", kind: .pass, pass: Self.tenClasses),
        ]))))
        _ = try close(&d, &events, "g1", payments: [pay("p1", .card, 3_500, at: d.clock)])
        var state = StoreState.replay(events)
        var acct = state.account(memberId: "m1", server: .empty, included: [])
        // 入場：期間會籍優先（不扣次數）
        let entry = try #require(acct.checkInPasses(at: d.clock).first)
        #expect(entry.name == "月卡")
        #expect(entry.spec.kind == .period)
        // 30 天：9/21 買 → 10/21 00:00（台北）到期
        #expect(TaipeiTime.dayString(try #require(entry.expiresAt)) == "2026-10-21")

        events.append(d.emit(.checkedIn(CheckedIn(checkIn: CheckIn(id: "ci1", member: Self.member, passId: entry.id, passName: entry.name, uses: 0, at: .distantPast, by: "")))))
        // 上團課：扣團課卡一次
        events.append(d.emit(.checkedIn(CheckedIn(checkIn: CheckIn(id: "ci2", member: Self.member, passId: "ten", passName: "團課 10 堂", uses: 1, sessionId: "yoga-0921", at: .distantPast, by: "")))))
        state = StoreState.replay(events)
        acct = state.account(memberId: "m1", server: .empty, included: [])
        #expect(acct.passes.first { $0.id == "ten" }?.remaining == 9)
        #expect(state.checkIns(businessDate: "2026-09-21").count == 2)
        #expect(state.checkIns["ci1"]?.by == "s1")
        #expect(state.lastCheckIn(memberId: "m1")?.id == "ci2")

        // 刷錯了：取消報到還回次數
        events.append(d.emit(.checkInVoided(CheckInVoided(checkInId: "ci2", reason: "刷錯人"))))
        state = StoreState.replay(events)
        #expect(state.account(memberId: "m1", server: .empty, included: []).passes.first { $0.id == "ten" }?.remaining == 10)
        #expect(state.checkIns(businessDate: "2026-09-21").count == 1)
        #expect(state.dailySummary(businessDate: "2026-09-21").checkIns == 1)

        // 續約：接在舊的到期日後面
        let start = acct.renewalStart(name: "月卡", spec: Self.monthly, at: d.clock)
        #expect(start == entry.expiresAt)
        #expect(acct.renewalStart(name: "團課 10 堂", spec: Self.tenClasses, at: d.clock) == nil)
    }

    // MARK: 換貨

    @Test func exchangeCreditAndCashBack() throws {
        var d = Device("A")
        var events = [d.emit(.shiftOpened(ShiftOpened(shiftId: "sh1", openingCash: Money(dollars: 1_000), businessDate: "2026-09-21")))]
        // 原單：外套 2,000（現金）
        events.append(d.emit(.ticketOpened(TicketOpened(ticketId: "o1", number: "A001", orderType: .takeout, businessDate: "2026-09-21", serviceMode: .apparel))))
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "o1", lines: [
            TicketLine(id: "coat", itemId: "coat", name: "外套", unitPrice: Money(dollars: 2_000), addedAt: d.clock, addedBy: "s1", skuId: "c-m", variantName: "黑・M"),
        ]))))
        let original = try close(&d, &events, "o1", payments: [Payment.cash(id: "p1", tendered: Money(dollars: 2_000), due: Money(dollars: 2_000), at: d.clock, by: "s1", shiftId: "sh1")])

        // 換一件 1,500 的：抵 2,000、退差額 500 現金
        let credit = ExchangeCredit(ticketId: "o1", number: "A001", lines: [RefundLine(lineId: "coat", quantity: 1, amount: original.refundAmount(lineId: "coat", quantity: 1))],
                                    amount: Money(dollars: 2_000))
        events.append(d.emit(.ticketOpened(TicketOpened(ticketId: "x1", number: "A002", orderType: .takeout, businessDate: "2026-09-21", serviceMode: .apparel,
                                                        salespersonId: "clerk", exchange: credit))))
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "x1", lines: [
            TicketLine(id: "vest", itemId: "vest", name: "背心", unitPrice: Money(dollars: 1_500), addedAt: d.clock, addedBy: "s1"),
        ]))))
        let refund = Refund(id: "r1", amount: Money(dollars: 2_000), tender: .exchange, lines: credit.lines, reason: "換貨", invoiceAction: .none,
                            at: d.clock, by: "s1", shiftId: "sh1")
        events.append(d.emit(.saleRefunded(SaleRefunded(ticketId: "o1", refund: refund))))
        let sale = try close(&d, &events, "x1", payments: [pay("p2", .exchange, 1_500, at: d.clock, change: 500)])
        let state = StoreState.replay(events)
        #expect(sale.exchange?.ticketId == "o1")
        #expect(sale.lines.first?.staffId == "clerk")
        // 錢櫃：1,000 零用金＋2,000 現金−500 退差額
        #expect(state.expectedCash(shiftId: "sh1") == Money(dollars: 2_500))
        let report = ShiftReport(shift: try #require(state.shifts["sh1"]), state: state, now: d.clock)
        #expect(report.cashBack == Money(dollars: 500))
        #expect(report.expectedCash == Money(dollars: 2_500))
        let summary = state.dailySummary(businessDate: "2026-09-21")
        // 實收：現金 2,000 − 換貨退差額 500
        #expect(summary.received == Money(dollars: 1_500))
        #expect(summary.exchangeCredit == Money(dollars: 1_500))
    }

    @Test func sameItemSizeSwapOnlyMovesStock() throws {
        var d = Device("A")
        var events = [d.emit(.ticketOpened(TicketOpened(ticketId: "o1", number: "A001", orderType: .takeout, businessDate: "2026-09-21", serviceMode: .apparel)))]
        events.append(d.emit(.linesAdded(LinesAdded(ticketId: "o1", lines: [
            TicketLine(id: "tee", itemId: "tee", name: "素T", unitPrice: Money(dollars: 590), addedAt: d.clock, addedBy: "s1", skuId: "t-s", variantName: "白・S"),
        ]))))
        // 還沒結帳前換規格
        events.append(d.emit(.lineUpdated(LineUpdated(ticketId: "o1", lineId: "tee", skuId: "t-m", variantName: "白・M"))))
        _ = try close(&d, &events, "o1", payments: [pay("p1", .card, 590, at: d.clock)])
        // 結帳後換尺寸：不動錢、不動發票
        let swap = VariantSwap(lineId: "tee", quantity: 1, fromSkuId: "t-m", toSkuId: "t-l", toVariantName: "白・L")
        events.append(d.emit(.saleExchanged(SaleExchanged(ticketId: "o1", swaps: [swap], reason: "太小"))))
        let state = StoreState.replay(events)
        #expect(state.sales["o1"]?.lines.first?.variantName == "白・M")
        #expect(state.tickets["o1"]?.swaps == [swap])
        #expect(state.dailySummary(businessDate: "2026-09-21").total == Money(dollars: 590))
    }

    // MARK: 相容

    /// 舊版後台、舊版 App 的 JSON 沒有新欄位：照樣讀得進來
    @Test func oldJSONStillDecodes() throws {
        let d = EventCoding.decoder()
        let item = try d.decode(MenuItem.self, from: Data(#"{"id":"i","categoryId":"c","name":"珍奶","price":6000,"openPrice":false,"modifierGroupIds":[],"taxKind":1,"isAvailable":true,"unit":"杯","sortOrder":0}"#.utf8))
        #expect(item.itemKind == .goods)
        #expect(!item.hasVariants)
        let flags = try d.decode(FeatureFlags.self, from: Data(#"{"seating":true}"#.utf8))
        #expect(!flags.accounts && !flags.appointments)
        let store = try d.decode(StoreProfile.self, from: Data(#"{"name":"晨麥","serviceModes":["salon","fitness","martian"]}"#.utf8))
        #expect(store.serviceModes == [.salon, .fitness])
        #expect(store.defaultServiceMode == .salon)
        #expect(store.prepaidInvoicing == .atTopUp)
        #expect(store.exchangeDays == 7)
        let line = try d.decode(TicketLine.self, from: Data(#"{"id":"l","name":"珍奶","unitPrice":6000,"modifiers":[],"quantity":1,"note":"","course":0,"taxKind":1,"addedAt":"2026-09-21T14:13:20.000Z","addedBy":"s","kitchen":"new"}"#.utf8))
        #expect(line.itemKind == .goods && line.redeem == nil)
        // 新欄位沒有值時不出現在 JSON 裡（舊事件的雜湊不受影響）
        let json = String(decoding: try EventCoding.encoder().encode(line), as: UTF8.self)
        #expect(!json.contains("skuId") && !json.contains("redeem") && !json.contains("kitchenAt"))
    }
}
