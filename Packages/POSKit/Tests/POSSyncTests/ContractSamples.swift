import Foundation
import Testing
@testable import POSCore
@testable import POSInvoice
@testable import POSSync

/// 文件與後台用的範例 JSON（docs/samples/）。POSKIT_WRITE_SAMPLES=1 swift test --filter ContractSamples 重新產生；
/// 平常跑測試只檢查「產生得出來、解得回去」
struct ContractSamples {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func sampleTicket() -> Ticket {
        var t = Ticket(id: "6f1c2a9e-0b7d-4c1e-9a55-2f3b8d1e7c40", number: "A023", deviceId: "dev-a", orderType: .dineIn, tableIds: ["tbl-a1"],
                       guests: 2, serviceChargeBps: 1000, openedAt: at, openedBy: "staff-leslie", businessDate: "2026-09-21")
        t.lines = [
            TicketLine(id: "ln-1", itemId: "itm-milktea", name: "珍珠奶茶", categoryId: "cat-drinks", categoryName: "飲料", unitPrice: Money(dollars: 60),
                       modifiers: [AppliedModifier(groupId: "grp-sugar", groupName: "甜度", optionId: "opt-half", name: "半糖"),
                                   AppliedModifier(groupId: "grp-ice", groupName: "冰塊", optionId: "opt-less", name: "少冰")],
                       quantity: 2, station: "吧台", addedAt: at, addedBy: "staff-leslie", sentAt: at, kitchen: .sent),
            TicketLine(id: "ln-2", itemId: "itm-chicken", name: "鹽酥雞", categoryId: "cat-fried", categoryName: "炸物", unitPrice: Money(dollars: 80),
                       quantity: 1, station: "廚房", addedAt: at, addedBy: "staff-leslie", sentAt: at, kitchen: .served),
        ]
        t.invoiceBuyer = .business(taxId: "22099131", title: "台灣積體電路製造股份有限公司")
        return t
    }

    static func samples() throws -> [String: String] {
        let enc = EventCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        func j<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }

        var t = sampleTicket()
        let settings = InvoiceSettings(enabled: true, sellerTaxId: "04595257", sellerName: "晨麥手作有限公司", sellerAddress: "台南市中西區民族路二段1號",
                                       qrKey: "0123456789ABCDEF0123456789ABCDEF",
                                       rolls: [InvoiceRoll(id: "roll-1", period: "11510", track: "AB", start: 12345650, end: 12345699)])
        let alloc = InvoiceAllocator(rolls: settings.rolls, used: [])
        var bootSettings = settings
        bootSettings.rolls = [InvoiceRoll(id: "roll-1", period: "11510", track: "AB", start: 12345650, end: 12345699, usedThrough: 12345650)]
        let invoice = try InvoiceBuilder.issue(ticket: t, settings: settings, allocator: alloc, deviceId: "dev-a", at: at, randomCode: "4821")
        t.invoice = invoice.stamp
        t.payments = [Payment.cash(id: "pay-1", tendered: Money(dollars: 300), due: t.totals.amountDue, at: at, by: "staff-leslie", shiftId: "shift-1")]
        let sale = SaleRecord(ticket: t, closedOn: "dev-a", shiftId: "shift-1", closedAt: at, closedBy: "staff-leslie", staffName: "Leslie", floor: FloorPlan())

        let e1 = try POSEvent(id: "evt-0001", deviceId: "dev-a", seq: 41, lamport: 1207, at: at, staffId: "staff-leslie",
                              body: .linesAdded(LinesAdded(ticketId: t.id, lines: t.lines)), prevHash: String(repeating: "a", count: 64))
        let e2 = try POSEvent(id: "evt-0002", deviceId: "dev-a", seq: 42, lamport: 1208, at: at, staffId: "staff-leslie",
                              body: .invoiceIssued(InvoiceIssued(ticketId: t.id, invoice: invoice)), prevHash: e1.hash)
        let e3 = try POSEvent(id: "evt-0003", deviceId: "dev-a", seq: 43, lamport: 1209, at: at, staffId: "staff-leslie",
                              body: .ticketClosed(TicketClosed(ticketId: t.id, sale: sale)), prevHash: e2.hash)

        let bootstrap = Bootstrap(
            version: "v-3f9a1c", serverTime: at,
            device: DeviceProfile(id: "dev-a", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(name: "晨麥手作", legalName: "晨麥手作有限公司", taxId: "04595257", address: "台南市中西區民族路二段1號", phone: "06-2220000",
                                serviceChargeBps: 1000, tableTimeLimitMinutes: 90),
            features: { var f = FeatureFlags.all; f.queue = true; return f }(),
            catalog: Catalog(
                categories: [MenuCategory(id: "cat-drinks", name: "飲料", swatch: .lavender, sortOrder: 1, station: "吧台")],
                items: [MenuItem(id: "itm-milktea", categoryId: "cat-drinks", name: "珍珠奶茶", shortName: "珍奶", price: Money(dollars: 60),
                                 plu: "101", modifierGroupIds: ["grp-sugar"], unit: "杯")],
                modifierGroups: [ModifierGroup(id: "grp-sugar", name: "甜度", minSelect: 1, maxSelect: 1, options: [
                    ModifierOption(id: "opt-full", name: "正常", isDefault: true), ModifierOption(id: "opt-half", name: "半糖"),
                ])]
            ),
            floor: FloorPlan(areas: [FloorArea(id: "area-1f", name: "1F", tables: [DiningTable(id: "tbl-a1", areaId: "area-1f", name: "A1", seats: 4, x: 10, y: 10)])]),
            staff: [StaffMember(id: "staff-leslie", name: "Leslie", role: .cashier, pinHash: Staff.hash(pin: "1234", salt: "8c1f0e5a"), pinSalt: "8c1f0e5a", swatch: .lavender)],
            invoice: bootSettings,
            mesh: MeshConfig(key: String(repeating: "ab", count: 32), enabled: true),
            queue: QueueConfig(mode: .native, customerUrl: "https://shop.example.tw/q?no={number}&waiting={waiting}",
                               ticket: QueueTicketLayout(backgroundUrl: "https://cms.example.tw/uploads/queue-ticket-bg.jpg"))
        )

        // 服飾、美業、健身
        let industryCatalog = Catalog(
            categories: [MenuCategory(id: "cat-tops", name: "上衣", swatch: .sand), MenuCategory(id: "cat-hair", name: "剪燙染", swatch: .rose),
                         MenuCategory(id: "cat-cards", name: "課程卡・儲值", swatch: .mint)],
            items: [
                MenuItem(id: "itm-tee", categoryId: "cat-tops", name: "重磅素T", price: Money(dollars: 690), unit: "件", productId: "prod-tee",
                         optionNames: ["顏色", "尺寸"], variants: [
                            ItemVariant(id: "sku-tee-blk-m", options: ["黑", "M"], sku: "TEE-BLK-M", barcode: "4710000000123", stock: 4, productVariantId: "pv-tee-blk-m"),
                            ItemVariant(id: "sku-tee-wht-l", options: ["白", "L"], sku: "TEE-WHT-L", barcode: "4710000000130", price: Money(dollars: 720), stock: 0),
                         ], commissionBps: 300),
                MenuItem(id: "itm-cut", categoryId: "cat-hair", name: "剪髮", price: Money(dollars: 600), kind: .service, durationMinutes: 60, commissionBps: 3000),
                MenuItem(id: "itm-cut10", categoryId: "cat-cards", name: "剪髮 10 次卡", price: Money(dollars: 5_000), kind: .pass,
                         pass: PassSpec(kind: .visits, visits: 10, validDays: 365, itemIds: ["itm-cut"])),
                MenuItem(id: "itm-month", categoryId: "cat-cards", name: "月卡", price: Money(dollars: 1_500), kind: .pass,
                         pass: PassSpec(kind: .period, validDays: 30, checkIn: true)),
                MenuItem(id: "itm-sv10k", categoryId: "cat-cards", name: "儲值 10,000 送 1,000", price: Money(dollars: 10_000), kind: .storedValue,
                         credit: Money(dollars: 11_000)),
            ]
        )
        let member = MemberRef(id: "mem-1", phone: "0912345678", name: "王小美", tierName: "金卡")
        var salon = Ticket(id: "tkt-salon-1", number: "B007", deviceId: "dev-b", orderType: .takeout, member: member, openedAt: at, openedBy: "staff-cameron",
                           businessDate: "2026-09-21", serviceMode: .salon, appointmentId: "rsv-appt-1")
        salon.lines = [
            TicketLine(id: "ln-cut", itemId: "itm-cut", name: "剪髮", categoryId: "cat-hair", categoryName: "剪燙染", unitPrice: Money(dollars: 600), addedAt: at,
                       addedBy: "staff-cameron", kind: .service, staffId: "staff-mori", assistantId: "staff-jacob", durationMinutes: 60,
                       redeem: PassRedemption(passId: "ln-old-card", name: "剪髮 10 次卡", value: Money(dollars: 500)), commissionBps: 3000),
            TicketLine(id: "ln-dye", itemId: "itm-dye", name: "染髮", categoryId: "cat-hair", categoryName: "剪燙染", unitPrice: Money(dollars: 2_500), addedAt: at,
                       addedBy: "staff-cameron", kind: .service, staffId: "staff-mori", durationMinutes: 120, commissionBps: 3000),
            TicketLine(id: "ln-card", itemId: "itm-cut10", name: "剪髮 10 次卡", categoryId: "cat-cards", categoryName: "課程卡・儲值", unitPrice: Money(dollars: 5_000),
                       addedAt: at, addedBy: "staff-cameron", kind: .pass, pass: PassSpec(kind: .visits, visits: 10, validDays: 365, itemIds: ["itm-cut"])),
        ]
        salon.payments = [
            Payment(id: "pay-sv", tender: .prepaid, amount: Money(dollars: 2_500), reference: "0912-***-678", at: at, by: "staff-cameron", shiftId: "shift-b"),
            Payment(id: "pay-card", tender: .card, amount: Money(dollars: 5_000), cardLast4: "4021", at: at, by: "staff-cameron", shiftId: "shift-b"),
        ]
        let salonSale = SaleRecord(ticket: salon, closedOn: "dev-b", shiftId: "shift-b", closedAt: at, closedBy: "staff-cameron", staffName: "Cameron", floor: FloorPlan())
        let s1 = try POSEvent(id: "evt-1001", deviceId: "dev-b", seq: 1, lamport: 1300, at: at, staffId: "staff-cameron",
                              body: .ticketClosed(TicketClosed(ticketId: salon.id, sale: salonSale)), prevHash: POSEvent.genesis)
        let s2 = try POSEvent(id: "evt-1002", deviceId: "dev-b", seq: 2, lamport: 1301, at: at, staffId: "staff-cameron",
                              body: .checkedIn(CheckedIn(checkIn: CheckIn(id: "chk-1", member: member, passId: "ln-month", passName: "月卡", uses: 0,
                                                                          sessionId: "cls-yoga-0921", at: at, by: "staff-cameron"))), prevHash: s1.hash)
        let s3 = try POSEvent(id: "evt-1003", deviceId: "dev-b", seq: 3, lamport: 1302, at: at, staffId: "staff-cameron",
                              body: .saleExchanged(SaleExchanged(ticketId: "tkt-apparel-1", swaps: [VariantSwap(lineId: "ln-tee", quantity: 1, fromSkuId: "sku-tee-blk-m",
                                                                                                                   toSkuId: "sku-tee-blk-l", toVariantName: "黑・L", toProductVariantId: "pv-tee-blk-l")],
                                                                 reason: "太小")), prevHash: s2.hash)
        let account = AccountRules.moves(sale: salonSale)
        let issued = account.compactMap(\.pass)
        let memberSample = Member(id: "mem-1", phone: "0912345678", name: "王小美", tierName: "金卡", lifetimeSpend: Money(dollars: 48_200), visits: 23,
                                  lastVisitAt: at, note: "6N+7.1 1:1，頭皮敏感", wallet: Money(dollars: 8_500),
                                  passes: issued + [MemberPass(id: "ln-month", name: "月卡", spec: PassSpec(kind: .period, validDays: 30, checkIn: true), remaining: nil,
                                                               startsAt: at, expiresAt: TaipeiTime.endOfDay(at, plusDays: 30), ticketId: "tkt-gym-1", unitValue: Money(dollars: 1_500))],
                                  accountEventIds: ["evt-1001"],
                                  recentVisits: [MemberVisit(ticketId: salon.id, number: "B007", at: at, total: salonSale.total, items: ["剪髮", "染髮", "剪髮 10 次卡"],
                                                             staffNames: ["Mori"], note: nil)],
                                  birthday: "10-12")
        // 叫號：現在叫到 23，24–26 在等（25 標了星號），19 過號
        let calledAt = at.addingTimeInterval(-90)
        let queueState = QueueState(mode: .native, current: 23, waiting: [24, 25, 26], missed: [19], marked: [25], nextNo: 27,
                                    calledAt: calledAt, updatedAt: calledAt,
                                    takenAt: ["24": at.addingTimeInterval(-11 * 60), "25": at.addingTimeInterval(-7 * 60), "26": at.addingTimeInterval(-2 * 60)],
                                    servedToday: 22,
                                    // 24 是外帶結帳時自動取的（掛著那張單）；25 是排隊等內用的 4 位
                                    entries: ["24": QueueEntry(ticketId: "tkt-a012", label: "A012・3 項"), "25": QueueEntry(guests: 4)])
        let history = DayHistory(businessDate: "2026-09-21", sales: [salonSale], refunds: [], voidedTickets: [], invoiceNumbers: [], voidedInvoiceNumbers: [], checkIns: 1)
        let appointment = Reservation(id: "rsv-appt-1", kind: .appointment, name: "王小美", phone: "0912345678", partySize: 1, startsAt: at, durationMinutes: 180,
                                      createdAt: at, staffId: "staff-mori",
                                      services: [BookedService(itemId: "itm-cut", name: "剪髮", durationMinutes: 60), BookedService(itemId: "itm-dye", name: "染髮", durationMinutes: 120)],
                                      memberId: "mem-1")

        return [
            "event-lines-added.json": try j(e1),
            "event-invoice-issued.json": try j(e2),
            "event-ticket-closed.json": try j(e3),
            "bootstrap.json": try j(bootstrap),
            "events-push-result.json": try j(EventsPushResult(accepted: ["evt-0001", "evt-0002"], duplicates: [], rejected: [EventRejection(id: "evt-0003", reason: "chain_gap", expectSeq: 42)], serverSeq: 98113)),
            "pair-response.json": try j(PairResponse(deviceId: "dev-a", token: "sxpos_dev-a.9Jq…", deviceCode: "A", role: .register, storeName: "晨麥手作")),
            "reservation.json": try j(Reservation(id: "rsv-1", kind: .reservation, name: "王小明", phone: "0912345678", partySize: 4, startsAt: at, tableIds: ["tbl-a1"], note: "靠窗", createdAt: at)),
            "appointment.json": try j(appointment),
            "class-list.json": try j(ClassList(classes: [ClassSession(id: "cls-yoga-0921", name: "流動瑜珈", staffId: "staff-jacob", startsAt: at, durationMinutes: 60,
                                                                      capacity: 15, booked: 9, room: "B 教室", itemId: "itm-yoga", dropInPrice: Money(dollars: 450))])),
            "catalog-industries.json": try j(industryCatalog),
            "event-salon-ticket-closed.json": try j(s1),
            "event-member-checked-in.json": try j(s2),
            "event-sale-exchanged.json": try j(s3),
            "member.json": try j(MemberLookup(member: memberSample)),
            "history.json": try j(history),
            "queue-state.json": try j(queueState),
            "invoice-qr.txt": {
                let p = InvoiceProof(invoice: invoice, storeName: "晨麥手作", qrKey: settings.qrKey)
                return "barcode: \(p.barcode)\nleft:  \(p.qrLeft ?? "")\nright: \(p.qrRight ?? "")\n"
            }(),
        ]
    }

    @Test func samplesRoundTrip() throws {
        let s = try Self.samples()
        let dec = EventCoding.decoder()
        for name in ["event-lines-added.json", "event-invoice-issued.json", "event-ticket-closed.json", "event-salon-ticket-closed.json",
                     "event-member-checked-in.json", "event-sale-exchanged.json"] {
            let e = try dec.decode(POSEvent.self, from: Data(s[name]!.utf8))
            #expect(e.isHashValid, "\(name)")
        }
        _ = try dec.decode(Bootstrap.self, from: Data(s["bootstrap.json"]!.utf8))
        _ = try dec.decode(MemberLookup.self, from: Data(s["member.json"]!.utf8))
        _ = try dec.decode(DayHistory.self, from: Data(s["history.json"]!.utf8))
        _ = try dec.decode(Catalog.self, from: Data(s["catalog-industries.json"]!.utf8))
        _ = try dec.decode(ClassList.self, from: Data(s["class-list.json"]!.utf8))
        let boot = try dec.decode(Bootstrap.self, from: Data(s["bootstrap.json"]!.utf8))
        #expect(boot.features.queue)
        #expect(boot.queue?.ticket.number.y == 140)
        let queue = try dec.decode(QueueState.self, from: Data(s["queue-state.json"]!.utf8))
        #expect(queue.current == 23 && queue.waiting == [24, 25, 26] && queue.takenAt.count == 3 && queue.servedToday == 22)
        if ProcessInfo.processInfo.environment["POSKIT_WRITE_SAMPLES"] == "1" {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../docs/samples").standardized
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in s { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        }
    }
}
