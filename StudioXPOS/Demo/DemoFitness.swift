import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 示範：健身會館「Pulse 健身」（虛構）。會籍（月卡、季卡、年卡：期間內不限次數、含團課）、團課 10 堂、私人教練 10 堂；
/// 今天的課表（飛輪 07:00、瑜珈 12:30、HIIT 19:00、伸展 20:15）與報名名單、私人教練的預約、入場報到；
/// 會員裡有會籍過期的、只剩 2 堂的、當月壽星。櫃台也賣飲料補給（櫃台點餐模式）。
extension DemoStore {
    static func fitnessBootstrap(now: Date) -> Bootstrap {
        let address = "高雄市左營區博愛二路 366 號 3 樓"
        return Bootstrap(
            version: "demo-fitness", serverTime: now,
            device: DeviceProfile(id: "demo-register", name: "櫃台 1", code: "A", role: .register, stations: []),
            store: StoreProfile(
                name: "Pulse 健身", legalName: "脈動運動健康有限公司", taxId: "64020122", address: address, phone: "07-550-0000",
                receiptFooter: "入場請出示會員條碼・毛巾用完請放回收籃", serviceChargeBps: 0, serviceChargeOn: [], tipsEnabled: false,
                defaultOrderType: .takeout, tableTimeLimitMinutes: 0, businessDayCutoffHour: 4, discountLimitBps: 1000,
                discountPresetsBps: [500, 1000, 1500, 2000], serviceModes: [.fitness, .counter], defaultServiceMode: .fitness,
                prepaidInvoicing: .atTopUp, exchangeDays: 7, bookingSlotMinutes: 30
            ),
            features: FeatureFlags(seating: false, kitchen: false, reservations: false, invoice: true, members: true, waitlistSMS: false,
                                   appointments: true, accounts: true, commission: true),
            catalog: fitnessCatalog,
            floor: .empty,
            staff: fitnessStaff,
            invoice: demoInvoice(taxId: "64020122", name: "脈動運動健康有限公司", address: address, now: now, tracks: ("YG", "YH", "YJ")),
            mesh: MeshConfig(key: String(repeating: "8b", count: 32), enabled: false)
        )
    }

    // MARK: 會籍、課程卡、團課、私人教練、補給

    static let fitnessCatalog: Catalog = {
        let categories = [
            MenuCategory(id: "c-member", name: "會籍", swatch: .lavender, sortOrder: 1),
            MenuCategory(id: "c-pack", name: "課程卡", swatch: .sky, sortOrder: 2),
            MenuCategory(id: "c-class", name: "團課", swatch: .mint, sortOrder: 3),
            MenuCategory(id: "c-pt", name: "私人教練", swatch: .peach, sortOrder: 4),
            MenuCategory(id: "c-shop", name: "補給", swatch: .butter, sortOrder: 5),
        ]
        /// 會籍：期間內不限次數入場、團課也可以上
        func membership(_ id: String, _ name: String, _ price: Int, days: Int, plu: String) -> MenuItem {
            MenuItem(id: id, categoryId: "c-member", name: name, price: Money(dollars: price), plu: plu, unit: "張", sortOrder: Int(plu) ?? 0,
                     kind: .pass, pass: PassSpec(kind: .period, validDays: days, categoryIds: ["c-class"], checkIn: true))
        }
        func service(_ id: String, _ cat: String, _ name: String, _ price: Int, minutes: Int, plu: String, commission: Int? = nil) -> MenuItem {
            MenuItem(id: id, categoryId: cat, name: name, price: Money(dollars: price), plu: plu, unit: "堂", sortOrder: Int(plu) ?? 0,
                     kind: .service, durationMinutes: minutes, commissionBps: commission)
        }
        func goods(_ id: String, _ name: String, _ price: Int, plu: String, unit: String, stock: Int? = nil, barcode: String? = nil) -> MenuItem {
            MenuItem(id: id, categoryId: "c-shop", name: name, price: Money(dollars: price), barcode: barcode.map { DemoStore.ean13($0) }, plu: plu,
                     unit: unit, sortOrder: Int(plu) ?? 0, stock: stock)
        }
        let items: [MenuItem] = [
            membership("pass-month", "月卡", 1_500, days: 30, plu: "101"),
            membership("pass-quarter", "季卡", 4_000, days: 90, plu: "102"),
            membership("pass-year", "年卡", 13_800, days: 365, plu: "103"),
            MenuItem(id: "entry-day", categoryId: "c-member", name: "單次入場", price: Money(dollars: 250), plu: "104", unit: "次", sortOrder: 104,
                     kind: .service),
            MenuItem(id: "pass-class10", categoryId: "c-pack", name: "團課 10 堂", price: Money(dollars: 2_800), plu: "201", unit: "張", sortOrder: 201,
                     kind: .pass, pass: PassSpec(kind: .visits, visits: 10, validDays: 120, categoryIds: ["c-class"], checkIn: true)),
            MenuItem(id: "pass-pt10", categoryId: "c-pack", name: "私人教練 10 堂", price: Money(dollars: 12_000), plu: "202", unit: "張", sortOrder: 202,
                     kind: .pass, pass: PassSpec(kind: .visits, visits: 10, validDays: 180, itemIds: ["svc-pt60"]), commissionBps: 800),
            service("class-spin", "c-class", "飛輪（單堂）", 350, minutes: 45, plu: "301"),
            service("class-yoga", "c-class", "瑜珈（單堂）", 350, minutes: 60, plu: "302"),
            service("class-hiit", "c-class", "HIIT（單堂）", 350, minutes: 45, plu: "303"),
            service("class-stretch", "c-class", "伸展（單堂）", 300, minutes: 40, plu: "304"),
            service("svc-pt60", "c-pt", "私人教練 60 分", 1_500, minutes: 60, plu: "401", commission: 4000),
            service("svc-inbody", "c-pt", "InBody 檢測", 300, minutes: 15, plu: "402"),
            goods("goods-shake", "乳清蛋白飲", 120, plu: "501", unit: "杯"),
            goods("goods-sports", "運動飲料", 35, plu: "502", unit: "瓶", stock: 48, barcode: "471099200502"),
            goods("goods-water", "礦泉水", 20, plu: "503", unit: "瓶", stock: 96, barcode: "471099200503"),
            goods("goods-bar", "蛋白棒", 80, plu: "504", unit: "條", stock: 3, barcode: "471099200504"),
            goods("goods-towel", "毛巾租借", 30, plu: "505", unit: "條"),
            goods("goods-lock", "置物櫃鎖", 150, plu: "506", unit: "個", stock: 11, barcode: "471099200506"),
        ]
        return Catalog(categories: categories, items: items)
    }()

    // MARK: 人員

    static let fitnessStaff: [StaffMember] = [
        person("s-leslie", "Leslie K.", .manager, "1234", .lavender, title: "店長", commissionBps: 300),
        person("s-cameron", "Cameron W.", .cashier, "2580", .mint, title: "櫃台", commissionBps: 300),
        person("s-jacob", "Jacob J.", .supervisor, "1111", .rose, title: "教練", bookable: true, commissionBps: 500),
        person("s-owner", "王小美", .owner, "0000", .peach, title: "負責人"),
        person("s-kevin", "Kevin 吳", .cashier, "5678", .sky, title: "教練", bookable: true, commissionBps: 500),
        person("s-ivy", "Ivy 黃", .cashier, "2468", .sage, title: "教練", bookable: true, commissionBps: 500),
    ]

    // MARK: 課表

    /// 今天的團體課（營業日的固定鐘點）
    static func fitnessClasses(now: Date) -> [ClassSession] {
        func at(_ h: Int, _ m: Int) -> Date { clock(h, m, on: now, cutoffHour: 4) }
        let dropIn = Money(dollars: 350)
        return [
            ClassSession(id: "demo-cls-spin", name: "晨間飛輪", staffId: "s-kevin", startsAt: at(7, 0), durationMinutes: 45, capacity: 20, booked: 18,
                         room: "飛輪教室", itemId: "class-spin", dropInPrice: dropIn, note: "請自備水壺與毛巾"),
            ClassSession(id: "demo-cls-yoga", name: "流動瑜珈", staffId: "s-ivy", startsAt: at(12, 30), durationMinutes: 60, capacity: 15, booked: 15,
                         room: "A 教室", itemId: "class-yoga", dropInPrice: dropIn, note: "瑜珈墊現場有"),
            ClassSession(id: "demo-cls-hiit", name: "HIIT 燃脂", staffId: "s-jacob", startsAt: at(19, 0), durationMinutes: 45, capacity: 25, booked: 21,
                         room: "A 教室", itemId: "class-hiit", dropInPrice: dropIn),
            ClassSession(id: "demo-cls-stretch", name: "伸展放鬆", staffId: "s-ivy", startsAt: at(20, 15), durationMinutes: 40, capacity: 15, booked: 6,
                         room: "B 教室", itemId: "class-stretch", dropInPrice: Money(dollars: 300)),
        ]
    }

    /// 課程名單裡的人（查得到的會員，各有一張入場用的卡）
    static let fitnessRosterPrefixes = ["0919", "0929", "0939", "0909"]

    static func rosterMember(_ k: Int, now: Date) -> Member {
        let ref = DemoHistory.customer(k, tag: "fr", prefixes: fitnessRosterPrefixes)
        let cat = fitnessCatalog
        let kinds = ["pass-class10", "pass-quarter", "pass-year", "pass-month", "pass-month"]
        let itemId = kinds[k % kinds.count]
        let bought: Double = switch itemId {
        case "pass-month": Double(2 + k % 26)
        case "pass-quarter": Double(8 + k * 7 % 75)
        case "pass-year": Double(20 + k * 37 % 300)
        default: Double(5 + k * 11 % 60)
        }
        let pass = heldPass("demo-fp-fr\(k)", cat.item(itemId), boughtDaysAgo: bought, remaining: 3 + k % 7, now: now)
        return Member(id: ref.id ?? "demo-fr-\(k)", phone: ref.phone, name: ref.name, tierName: ref.tierName,
                      lifetimeSpend: Money(dollars: 3_000 + k * 1_731 % 24_000), visits: 6 + k * 13 % 120, lastVisitAt: daysAgo(Double(1 + k % 6), now),
                      note: nil, wallet: .zero, passes: pass.map { [$0] } ?? [], accountEventIds: [], recentVisits: [])
    }

    /// 每一堂的名單：（課, 報名的會員）。指定的會員排前面，其他照順序編
    static func fitnessRosters(now: Date, classes: [ClassSession]) -> [(ClassSession, [Member])] {
        let named = fitnessNamedMembers(now: now)
        func person(_ id: String) -> Member? { named.first { $0.id == id } }
        let wanted: [String: [String]] = [
            "demo-cls-spin": ["demo-fm1"],
            "demo-cls-yoga": ["demo-fm2"],
            "demo-cls-hiit": ["demo-fm3", "demo-fm5"],
        ]
        var k = 0
        var out: [(ClassSession, [Member])] = []
        for c in classes {
            var people = (wanted[c.id] ?? []).compactMap(person)
            while people.count < c.booked {
                people.append(rosterMember(k, now: now))
                k += 1
            }
            out.append((c, people))
        }
        return out
    }

    // MARK: 會員（後台的）

    static func fitnessNamedMembers(now: Date) -> [Member] {
        let cat = fitnessCatalog
        return [
            Member(id: "demo-fm1", phone: "0910333666", name: "陳冠廷", tierName: "金卡會員", lifetimeSpend: Money(dollars: 46_800), visits: 212,
                   lastVisitAt: daysAgo(2, now), note: "目標增肌。每週二、四找 Jacob 練；練完喝乳清（不加糖）。",
                   wallet: .zero,
                   passes: [
                       heldPass("demo-fp-fm1-year", cat.item("pass-year"), boughtDaysAgo: 165, now: now),
                       heldPass("demo-fp-fm1-pt10", cat.item("pass-pt10"), boughtDaysAgo: 40, remaining: 6, now: now),
                   ].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [
                       visit("fm1-a", "A018", daysAgo: 2, now: now, total: 0, items: ["私人教練 60 分（私人教練 10 堂）"], staff: ["Jacob J."]),
                       visit("fm1-b", "A007", daysAgo: 9, now: now, total: 240, items: ["乳清蛋白飲 ×2"], staff: ["Cameron W."]),
                       visit("fm1-c", "A011", daysAgo: 40, now: now, total: 12_000, items: ["私人教練 10 堂"], staff: ["Jacob J."]),
                       visit("fm1-d", "A003", daysAgo: 165, now: now, total: 13_800, items: ["年卡"], staff: ["Leslie K."]),
                   ],
                   birthday: birthdayThisMonth(22, now: now)),
            Member(id: "demo-fm2", phone: "0920444777", name: "林依婷", tierName: "一般會員", lifetimeSpend: Money(dollars: 21_500), visits: 64,
                   lastVisitAt: daysAgo(3, now), note: "產後恢復中，核心訓練循序漸進；不做仰臥起坐。",
                   wallet: .zero,
                   passes: [
                       heldPass("demo-fp-fm2-month", cat.item("pass-month"), boughtDaysAgo: 21, now: now),
                       heldPass("demo-fp-fm2-pt10", cat.item("pass-pt10"), boughtDaysAgo: 70, remaining: 4, now: now),
                       heldPass("demo-fp-fm2-month-old", cat.item("pass-month"), boughtDaysAgo: 51, now: now),
                   ].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [
                       visit("fm2-a", "A021", daysAgo: 3, now: now, total: 0, items: ["私人教練 60 分（私人教練 10 堂）"], staff: ["Kevin 吳"]),
                       visit("fm2-b", "A005", daysAgo: 21, now: now, total: 1_500, items: ["月卡（續約）"], staff: ["Cameron W."]),
                   ],
                   birthday: "05-14"),
            Member(id: "demo-fm3", phone: "0931555888", name: "吳承恩", tierName: "一般會員", lifetimeSpend: Money(dollars: 5_600), visits: 18,
                   lastVisitAt: daysAgo(5, now), note: nil, wallet: .zero,
                   passes: [heldPass("demo-fp-fm3-class10", cat.item("pass-class10"), boughtDaysAgo: 90, remaining: 2, now: now)].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [visit("fm3-a", "A013", daysAgo: 90, now: now, total: 2_800, items: ["團課 10 堂"], staff: ["Cameron W."])]),
            Member(id: "demo-fm4", phone: "0952666999", name: "黃郁婷", tierName: "一般會員", lifetimeSpend: Money(dollars: 9_000), visits: 37,
                   lastVisitAt: daysAgo(13, now), note: "上次說想改買季卡；早上 7 點的飛輪常客。", wallet: .zero,
                   passes: [heldPass("demo-fp-fm4-month", cat.item("pass-month"), boughtDaysAgo: 42, now: now, status: .expired)].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [visit("fm4-a", "A002", daysAgo: 42, now: now, total: 1_500, items: ["月卡"], staff: ["Leslie K."])]),
            Member(id: "demo-fm5", phone: "0963777000", name: "許家豪", tierName: "金卡會員", lifetimeSpend: Money(dollars: 28_400), visits: 140,
                   lastVisitAt: daysAgo(1, now), note: "左膝舊傷，避免跳躍動作；HIIT 請教練給替代動作。", wallet: .zero,
                   passes: [heldPass("demo-fp-fm5-quarter", cat.item("pass-quarter"), boughtDaysAgo: 30, now: now)].compactMap { $0 },
                   accountEventIds: [],
                   recentVisits: [visit("fm5-a", "A009", daysAgo: 30, now: now, total: 4_000, items: ["季卡（續約）"], staff: ["Leslie K."])]),
            Member(id: "demo-fm6", phone: "0975888111", name: "蔡佩珊", tierName: "新會員", lifetimeSpend: .zero, visits: 0, lastVisitAt: nil,
                   note: "朋友帶來體驗，今天辦月卡。", wallet: .zero, passes: [], accountEventIds: [], recentVisits: []),
        ]
    }

    /// 查得到的會員：上面幾位＋課程名單裡的人
    static func fitnessMembers(now: Date) -> [Member] {
        var out = fitnessNamedMembers(now: now)
        for (_, people) in fitnessRosters(now: now, classes: fitnessClasses(now: now)) {
            for p in people where !out.contains(where: { $0.id == p.id }) { out.append(p) }
        }
        return out
    }

    // MARK: 今天的報名與預約

    /// 團課的報名（上完的已報到、少數沒來；正在上的大多到了）＋私人教練的預約
    static func fitnessReservations(now: Date, classes: [ClassSession]) -> [Reservation] {
        var out: [Reservation] = []
        for (c, people) in fitnessRosters(now: now, classes: classes) {
            for (i, p) in people.enumerated() {
                out.append(Reservation(id: "demo-cb-\(c.id)-\(i)", kind: .classBooking, name: p.name ?? "", phone: p.phone, partySize: 1,
                                       startsAt: c.startsAt, durationMinutes: c.durationMinutes,
                                       status: classStatus(c, person: p, index: i, now: now), source: i % 3 == 0 ? "pos" : "web",
                                       createdAt: c.startsAt.addingTimeInterval(-Double(1 + i % 4) * 86_400), staffId: c.staffId,
                                       memberId: p.id, sessionId: c.id))
            }
        }
        let t0 = slot(now, minutes: 30)
        let pt = fitnessCatalog.item("svc-pt60")
        let inBody = fitnessCatalog.item("svc-inbody")
        func appt(_ id: String, _ name: String, _ phone: String, coach: String, at minutes: Int, items: [MenuItem?], status: ReservationStatus = .booked,
                  member: String? = nil, ticket: String? = nil, note: String = "") -> Reservation {
            let services = items.compactMap { $0 }.map {
                BookedService(itemId: $0.id, name: $0.name, durationMinutes: $0.durationMinutes ?? 60, staffId: coach, price: $0.price)
            }
            return Reservation(id: id, kind: .appointment, name: name, phone: phone, partySize: 1, startsAt: t0.addingTimeInterval(Double(minutes * 60)),
                               durationMinutes: max(services.reduce(0) { $0 + $1.durationMinutes }, 30), status: status, note: note, source: "pos",
                               createdAt: now.addingTimeInterval(-2 * 86_400), staffId: coach, services: services, memberId: member, ticketId: ticket)
        }
        out += [
            appt("demo-pt-1", "林依婷", "0920444777", coach: "s-kevin", at: -90, items: [pt], status: .seated, member: "demo-fm2",
                 ticket: "demo-fit-sale-pt", note: "核心＋臀腿"),
            appt("demo-pt-2", "陳冠廷", "0910333666", coach: "s-jacob", at: 30, items: [pt], member: "demo-fm1", note: "練腿日"),
            appt("demo-pt-4", "趙子豪", "0912000111", coach: "s-kevin", at: 60, items: [inBody, pt], note: "體驗課，想了解季卡"),
            appt("demo-pt-3", "許家豪", "0963777000", coach: "s-jacob", at: 120, items: [pt], member: "demo-fm5", note: "膝蓋：避免跳躍"),
            appt("demo-pt-5", "黃郁婷", "0952666999", coach: "s-ivy", at: 180, items: [pt], member: "demo-fm4", note: "會籍過期，先續約"),
        ]
        return out.sorted { $0.startsAt < $1.startsAt }
    }

    /// 課程報名的狀態：上完的報到了（少數沒來）；正在上的大多到了；之後的還是已報名。吳承恩（只剩 2 堂）沒來，留著給示範
    static func classStatus(_ c: ClassSession, person p: Member, index i: Int, now: Date) -> ReservationStatus {
        let skipper = p.id == "demo-fm3"
        if c.endsAt <= now { return skipper || i % 9 == 4 ? .noShow : .seated }
        if c.startsAt <= now { return skipper || i % 6 == 5 ? .booked : .seated }
        return .booked
    }

    // MARK: 今天

    /// 開班、五個人上班；報到（開放時段、上完的課）、飲料補給、辦月卡、私人教練扣堂、單堂課
    func seedFitness(into ledger: Ledger) throws {
        let now = createdAt
        let s = DemoSeeder(ledger: ledger, bootstrap: bootstrap, now: now)
        let desk = "s-cameron"
        try s.openShift(by: "s-leslie", clockIn: ["s-leslie", desk, "s-jacob", "s-kevin", "s-ivy"], cash: Money(dollars: 2_000),
                        at: now.addingTimeInterval(-8 * 3600))
        let members = Self.fitnessMembers(now: now)
        func member(_ id: String) -> Member? { members.first { $0.id == id } }
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func entry(_ m: Member?, _ passId: String, minutesAgo: Double) throws {
            guard let m, let p = m.passes?.first(where: { $0.id == passId }) else { return }
            try s.checkIn("demo-fit-ci-\(m.id)-open", member: m.ref, passId: p.id, passName: p.name, perVisit: p.spec.kind == .visits,
                          by: desk, at: ago(minutesAgo))
        }

        // 開放時段的入場
        try entry(member("demo-fm5"), "demo-fp-fm5-quarter", minutesAgo: 340)
        try entry(member("demo-fm1"), "demo-fp-fm1-year", minutesAgo: 150)

        // 上完、正在上的課：名單上到了的人報到（用入場的卡；團課 10 堂扣一堂）
        for (c, people) in Self.fitnessRosters(now: now, classes: Self.fitnessClasses(now: now)) where c.startsAt <= now {
            for (i, p) in people.enumerated() where Self.classStatus(c, person: p, index: i, now: now) == .seated {
                let pass = p.serverAccount.passes(covering: c.itemId, categoryId: "c-class", at: c.startsAt).first
                try s.checkIn("demo-fit-ci-\(c.id)-\(i)", member: p.ref, passId: pass?.id, passName: pass?.name,
                              perVisit: pass?.spec.kind == .visits, sessionId: c.id, reservationId: "demo-cb-\(c.id)-\(i)",
                              note: pass == nil ? "單堂" : "", by: desk, at: c.startsAt.addingTimeInterval(-Double(3 + i % 12) * 60))
            }
        }

        // 單子照開單的時間記（單號才會照順序）
        var plan: [(at: Date, run: () throws -> Void)] = []
        var n = 0
        func sale(_ at: Date, member m: Member? = nil, customerName: String? = nil, lines: [TicketLine], pay: [DemoPay]) {
            plan.append((at, {
                n += 1
                let ticketId = "demo-fit-sale-\(n)"
                try s.open(ticketId, at: at, by: desk, mode: .fitness, member: m?.ref, customerName: customerName, lines: lines)
                try s.close(ticketId, at: at.addingTimeInterval(90), by: desk, pay: pay)
            }))
        }

        // 單次入場＋礦泉水
        let early = ago(400)
        sale(early, customerName: "單次入場", lines: [
            s.line("entry-day", by: desk, at: early),
            s.line("goods-water", by: desk, at: early),
        ], pay: [DemoPay(.cash)])

        // 許家豪練完：兩杯乳清
        let shake = ago(300)
        sale(shake, member: member("demo-fm5"), lines: [s.line("goods-shake", 2, by: desk, at: shake)], pay: [DemoPay(.card)])

        // 蔡佩珊：體驗完辦月卡，馬上報到
        if let m = member("demo-fm6") {
            let joined = ago(255)
            let monthLine = s.line("pass-month", seller: desk, by: desk, at: joined)
            sale(joined, member: m, lines: [monthLine], pay: [DemoPay(.linePay)])
            plan.append((joined.addingTimeInterval(1), {
                try s.checkIn("demo-fit-ci-fm6", member: m.ref, passId: monthLine.id, passName: monthLine.name, perVisit: false, by: desk,
                              at: joined.addingTimeInterval(180))
            }))
        }

        // 林依婷：來的時候先報到，私人教練扣一堂（Kevin）＋蛋白棒
        let appts = Self.fitnessReservations(now: now, classes: Self.fitnessClasses(now: now))
        if let r = appts.first(where: { $0.id == "demo-pt-1" }), let m = member("demo-fm2"),
           let card = m.passes?.first(where: { $0.id == "demo-fp-fm2-pt10" }) {
            plan.append((r.startsAt, {
                try s.checkIn("demo-fit-ci-fm2-open", member: m.ref, passId: "demo-fp-fm2-month", passName: "月卡", perVisit: false, by: desk,
                              at: r.startsAt.addingTimeInterval(-10 * 60))
                try s.open("demo-fit-sale-pt", at: r.startsAt, by: desk, mode: .fitness, member: m.ref, appointmentId: r.id, lines: [
                    s.line("svc-pt60", staffId: "s-kevin", redeem: PassRedemption(passId: card.id, name: card.name, value: card.unitValue),
                           by: desk, at: r.startsAt),
                    s.line("goods-bar", by: desk, at: r.endsAt),
                ])
                try s.close("demo-fit-sale-pt", at: r.endsAt, by: desk, pay: [DemoPay(.cash)])
            }))
        }

        // 吳承恩：運動飲料＋毛巾
        let towel = ago(150)
        sale(towel, member: member("demo-fm3"), lines: [
            s.line("goods-sports", by: desk, at: towel),
            s.line("goods-towel", by: desk, at: towel),
        ], pay: [DemoPay(.cash)])

        // 沒有卡的人上早上的飛輪（單堂）
        if let spin = Self.fitnessClasses(now: now).first(where: { $0.id == "demo-cls-spin" }), spin.startsAt < now {
            let at = spin.startsAt.addingTimeInterval(-12 * 60)
            sale(at, customerName: "單堂・飛輪", lines: [s.line("class-spin", staffId: "s-kevin", by: desk, at: at)], pay: [DemoPay(.jkoPay)])
        }

        // 名單上的一位加買團課 10 堂；陳冠廷練完買補給
        let pack = ago(70)
        sale(pack, member: Self.rosterMember(7, now: now), lines: [s.line("pass-class10", seller: desk, by: desk, at: pack)], pay: [DemoPay(.card)])
        let snack = ago(35)
        sale(snack, member: member("demo-fm1"), lines: [
            s.line("goods-bar", 2, by: desk, at: snack),
            s.line("goods-shake", by: desk, at: snack),
        ], pay: [DemoPay(.card)])

        for step in plan.sorted(by: { $0.at < $1.at }) { try step.run() }
    }
}
