import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 會員頁查會員的結果
enum MemberSearchOutcome {
    /// 後台查到了（已經記進 members）
    case found(Member)
    /// 後台查不到（離線、出錯）：先用這台記得的，附上原因
    case cached(Member, String)
    /// 後台說沒有這支電話（可以當場加入）
    case notFound(phone: String)
    case failed(String)
}

/// 會員頁左邊名單上的一位（今天預約的、今天來過的、這台最近查過的）
struct MemberSighting: Identifiable, Hashable {
    enum Source: Hashable {
        /// 今天有預約、報名（還沒來或剛到）
        case booking
        /// 今天來過（結帳、單子開著、報到）
        case visit
        /// 這台最近查過
        case recent
    }

    /// 會員 id（只有電話的用電話）
    var id: String
    var ref: MemberRef
    var source: Source
    /// 最近一次的時間（預約是預約的時間；最近查過的是上次來店）
    var at: Date?
    /// 「結帳 A012・NT$1,280」「預約 14:00・染髮・Jacob J.」
    var detail: String
    /// 人還在店裡（單子開著、已到店、服務中）
    var inStore: Bool
}

/// 左邊名單的三組
struct MemberBoard {
    var bookings: [MemberSighting] = []
    var visits: [MemberSighting] = []
    var recent: [MemberSighting] = []

    var isEmpty: Bool { bookings.isEmpty && visits.isEmpty && recent.isEmpty }
}

/// 會員的一次消費（後台的「最近幾次」＋這台記得的結帳，同一張單只列一次）
struct MemberHistoryEntry: Identifiable, Hashable {
    var id: String { ticketId }
    var ticketId: String
    var number: String
    var at: Date
    var total: Money
    /// 「染髮 6N+7.1・中長髮」「洗剪（剪髮 10 次卡）」
    var items: [String]
    /// 服務人員（設計師、教練、店員）
    var staffNames: [String]
    var note: String?
    /// 用次數卡抵了幾項
    var redeemed: Int
    /// 用儲值金付了多少
    var prepaid: Money
    /// 退了多少
    var refunded: Money
    /// 這台記的（還沒同步到後台的「最近幾次」）
    var onThisDevice: Bool
}

/// 會員頁：查會員（後台是真的資料，打開就重新查一次）、改名字與備註、儲值與賣課程卡、開單；示範的店
extension POSModel {
    /// 會員頁右側鍵盤的題目（用來認出鍵盤現在是不是在等會員頁的電話）
    static let memberSearchSpec = KeypadSpec(kind: .phone, title: "查會員", subtitle: "打手機號碼，或掃會員條碼", confirmLabel: "查詢")

    // MARK: - 查

    /// 用電話向後台查（後台是真的資料：查到就記住，畫面跟著更新）；離線時用這台記得的
    func searchMember(phone: String) async -> MemberSearchOutcome {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return .failed("請輸入手機號碼") }
        guard let api else {
            if let m = rememberedMember(phone: digits) { return .cached(m, "這台還沒連上後台") }
            return .failed("這台還沒連上後台")
        }
        do {
            if let m = try await api.member(phone: digits) {
                remember(m)
                return .found(m)
            }
            return .notFound(phone: digits)
        } catch let e as APIError {
            if let m = rememberedMember(phone: digits) { return .cached(m, e.userMessage) }
            return .failed(e.userMessage)
        } catch {
            if let m = rememberedMember(phone: digits) { return .cached(m, "查不到最新的資料") }
            return .failed("查不到，請再試一次")
        }
    }

    /// 這台查過的會員裡有沒有這支電話
    func rememberedMember(phone: String) -> Member? {
        members.values.first { $0.phone == phone }
    }

    /// 名單上的人（有 id 用 id，沒有用電話）
    func rememberedMember(_ ref: MemberRef) -> Member? {
        if let id = ref.id, let m = members[id] { return m }
        return ref.phone.isEmpty ? nil : rememberedMember(phone: ref.phone)
    }

    /// 當場加入會員（名字可以之後再補）
    func enrollMember(phone: String, name: String?) async -> MemberSearchOutcome {
        guard let api else { return .failed("這台還沒連上後台") }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let m = try await api.createMember(MemberCreate(phone: phone, name: trimmed.isEmpty ? nil : trimmed))
            remember(m)
            show("新會員 \(m.name ?? m.ref.maskedPhone) 加入了")
            return .found(m)
        } catch let e as APIError {
            return .failed(e.userMessage)
        } catch {
            return .failed("加不了會員，請再試一次")
        }
    }

    // MARK: - 改

    /// 改名字（存到後台才算數）。回傳要顯示的問題（nil＝存好了）
    func saveMemberName(_ name: String, for m: Member) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (m.name ?? "") else { return nil }
        return await updateMember(m, MemberUpdate(name: trimmed))
    }

    /// 改備註（偏好、過敏、染髮配方）。回傳要顯示的問題（nil＝存好了）
    func saveMemberNote(_ note: String, for m: Member) async -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (m.note ?? "") else { return nil }
        return await updateMember(m, MemberUpdate(note: trimmed))
    }

    /// 改生日（MM-DD）。回傳要顯示的問題（nil＝存好了）
    func saveMemberBirthday(_ birthday: String, for m: Member) async -> String? {
        guard birthday != (m.birthday ?? "") else { return nil }
        return await updateMember(m, MemberUpdate(birthday: birthday))
    }

    /// 生日用右側鍵盤打（月日 4 碼：1018），存到後台。回傳要顯示的問題（nil＝存好了或取消）
    func askBirthday(for m: Member) async -> String? {
        let current = POSModel.birthdayText(m.birthday).map { text -> String in
            let parts = text.split(separator: "/").compactMap { Int($0) }
            return parts.count == 2 ? String(format: "%02d%02d", parts[0], parts[1]) : ""
        } ?? ""
        let spec = KeypadSpec(kind: .code(minLength: 4, maxLength: 4), title: "生日", subtitle: "\(m.name ?? m.ref.maskedPhone)・打月日 4 碼，例如 1018",
                              initial: current, confirmLabel: "存到後台")
        guard let entry = await keypad.ask(spec, validate: { e in Self.birthday(fromDigits: e.digits) == nil ? "月份 01–12、日期要對（例如 1018）" : nil }),
              let birthday = Self.birthday(fromDigits: entry.digits) else { return nil }
        let problem = await saveMemberBirthday(birthday, for: m)
        if problem == nil, let text = POSModel.birthdayText(birthday) { show("生日改好了：\(text)") }
        return problem
    }

    /// 「1018」→「10-18」（日期不對是 nil）
    static func birthday(fromDigits digits: String) -> String? {
        guard digits.count == 4, let month = Int(digits.prefix(2)), let day = Int(digits.suffix(2)) else { return nil }
        let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day) else { return nil }
        return String(format: "%02d-%02d", month, day)
    }

    private func updateMember(_ m: Member, _ update: MemberUpdate) async -> String? {
        guard let api else { return "這台還沒連上後台" }
        do {
            let fresh = try await api.updateMember(id: m.id, update)
            // 後台回整份（有帳戶）就用後台的；只回改過的欄位就補到手上這份
            var merged = members[m.id] ?? m
            if fresh.wallet != nil || fresh.passes != nil {
                merged = fresh
            } else {
                merged.name = fresh.name
                merged.note = fresh.note
                merged.birthday = fresh.birthday
            }
            remember(merged)
            return nil
        } catch let e as APIError {
            switch e {
            case .http(let status, _, _) where status == 404 || status == 405 || status == 501:
                return "這家店的後台還不能改會員資料（要更新後台），這次沒有存"
            case .offline:
                return "沒有網路，沒有存到後台；連上後再按一次儲存"
            default:
                return e.userMessage
            }
        } catch {
            return "沒有存到後台，請再試一次"
        }
    }

    // MARK: - 賣儲值、課程卡

    /// 會員頁可以賣的（儲值或課程卡、會籍）：固定金額的照價錢排，自訂金額排最後
    func memberProducts(_ kind: ItemKind) -> [MenuItem] {
        catalog.items
            .filter { $0.itemKind == kind && isAvailable($0) }
            .sorted { a, b in
                if a.openPrice != b.openPrice { return !a.openPrice }
                return (a.sortOrder, a.price) < (b.sortOrder, b.price)
            }
    }

    /// 儲值：開一張這位會員的單、加儲值、直接結帳（自訂金額先在右側鍵盤打）
    func sellTopUp(_ item: MenuItem, to m: Member) async {
        await sellToMember(item, m)
    }

    /// 買課程卡、續約：會籍還沒到期的接在後面（加進單子時就算好開始日）
    func sellPass(_ item: MenuItem, to m: Member) async {
        await sellToMember(item, m)
    }

    /// 儲值（會員頁的「儲值」）：右側鍵盤打金額，快速鍵是店裡的儲值方案。
    /// 打的剛好是某個方案的金額就賣那個方案（送的照方案）；其他金額用自訂儲值（沒有自訂儲值的店只能選方案）。
    /// 回傳有沒有進到結帳（沒有＝取消了）
    @discardableResult
    func askTopUp(for m: Member) async -> Bool {
        let plans = memberProducts(.storedValue)
        let fixed = plans.filter { !$0.openPrice }
        let custom = plans.first { $0.openPrice }
        guard !plans.isEmpty else {
            show("這家店還沒有儲值的品項（後台的菜單加一個「儲值」）", tone: .warning)
            return false
        }
        let quick = fixed.prefix(6).map { KeypadSpec.QuickKey(Self.planLabel($0), digits: String($0.price.dollars)) }
        var hints = fixed.map(Self.planLabel)
        if custom != nil { hints.append("其他金額照打的儲值") }
        let spec = KeypadSpec(kind: .money, title: "儲值・\(m.name ?? m.ref.maskedPhone)", subtitle: hints.joined(separator: "・"),
                              initial: fixed.first.map { String($0.price.dollars) } ?? "", quickKeys: quick, confirmLabel: "儲值", minValue: 1)
        guard let entry = await keypad.ask(spec, validate: { e in
            let v = e.value ?? 0
            if fixed.contains(where: { $0.price.dollars == v }) || (custom != nil && v > 0) { return nil }
            return "請選一個儲值方案"
        }), let amount = entry.money else { return false }
        if let plan = fixed.first(where: { $0.price == amount }) {
            return await sellToMember(plan, m)
        }
        guard let custom else { return false }
        return await sellToMember(custom, m, price: amount)
    }

    /// 「$10,000 送 1,000」（沒有送的就只有金額）
    static func planLabel(_ item: MenuItem) -> String {
        guard let credit = item.credit, credit > item.price else { return item.price.short }
        return "\(item.price.short) 送 \((credit - item.price).plain)"
    }

    /// 這張卡在菜單上是哪一個品項（續約、再買一張用；菜單上已經沒有就是 nil）
    func passItem(for pass: MemberPass) -> MenuItem? {
        catalog.items.first { $0.itemKind == .pass && $0.name == pass.name && isAvailable($0) }
    }

    @discardableResult
    private func sellToMember(_ item: MenuItem, _ m: Member, price preset: Money? = nil) async -> Bool {
        guard currentStaff != nil else { return false }
        guard isAvailable(item) else {
            show("\(item.name) 現在不能賣", tone: .warning)
            return false
        }
        var price: Money? = preset
        if item.openPrice && price == nil {
            let spec: KeypadSpec = item.itemKind == .storedValue ? .topUp() : .openPrice(name: item.name)
            guard let p = await keypad.askMoney(spec), p.cents > 0 else { return false }
            price = p
        }
        // 單子一開始就要有會員（續約的開始日、結帳時記到帳戶都靠它）
        if members[m.id] == nil { remember(m) }
        guard let t = openTicket(type: mode.defaultOrderType, member: m.ref) else { return false }
        add(item, quantity: 1, modifiers: [], note: "", price: price)
        guard let fresh = state.tickets[t.id], !fresh.activeLines.isEmpty else { return false }
        beginCheckout(fresh)
        return true
    }

    /// 這張會籍賣給他的話從哪天開始（還有效的同一種會籍：接在後面；nil＝今天）
    func renewalStart(of item: MenuItem, for m: Member) -> Date? {
        guard let spec = item.pass, let acct = account(for: m.ref) else { return nil }
        return acct.renewalStart(name: item.name, spec: spec, at: Date())
    }

    // MARK: - 開單

    /// 幫會員開單（他已經有開著的單就接著用），跳到點餐
    func openMemberTicket(_ m: Member) {
        if members[m.id] == nil { remember(m) }
        let who = m.name ?? m.ref.maskedPhone
        if let t = openTickets(for: m).last {
            selectedTicketId = t.id
            show("接著 \(t.number)・\(who)", tone: .info)
        } else {
            guard let t = openTicket(type: mode.defaultOrderType, member: m.ref) else { return }
            show("\(who) 開單・\(t.number)")
        }
        go(.order)
    }

    /// 打開這張單（單子開著的會員）
    func openExistingTicket(_ t: Ticket) {
        selectedTicketId = t.id
        go(.order)
    }

    func openTickets(for m: Member) -> [Ticket] {
        state.openTickets.filter { Self.isSame(m, $0.member) }
    }

    /// 這個 ref 是不是這位會員（沒有 id 的用電話對）
    static func isSame(_ m: Member, _ ref: MemberRef?) -> Bool {
        guard let ref else { return false }
        if let id = ref.id { return id == m.id }
        return !ref.phone.isEmpty && ref.phone == m.phone
    }

    // MARK: - 今天

    /// 這位會員今天的預約、課程報名（取消、未到的不算）
    func memberBookings(for m: Member) -> [Reservation] {
        let today = businessDate
        let cutoff = store.businessDayCutoffHour
        return reservations
            .filter { r in
                (r.kind == .appointment || r.kind == .classBooking) && r.status != .cancelled && r.status != .noShow
                    && (r.memberId == m.id || (!r.phone.isEmpty && r.phone == m.phone))
                    && TaipeiTime.businessDate(r.startsAt, cutoffHour: cutoff) == today
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// 預約、報名的一句話：「14:00 染髮・Jacob J.」「19:00 HIIT 燃脂」
    func bookingSummary(_ r: Reservation) -> String {
        let time = TaipeiTime.clock(r.startsAt)
        if r.kind == .classBooking {
            let name = r.sessionId.flatMap { id in classes.first { $0.id == id }?.name } ?? "團體課"
            return "\(time) \(name)"
        }
        let services = (r.services ?? []).map(\.name).joined(separator: "＋")
        let who = r.staffId.map { staffName($0) }.flatMap { $0 == "—" ? nil : $0 }
        return [time + (services.isEmpty ? " 預約" : " \(services)"), who].compactMap { $0 }.joined(separator: "・")
    }

    /// 左邊的名單：今天預約的（還沒來的）、今天來過的（結帳、單子開著、報到）、這台最近查過的
    func memberBoard(now: Date = Date()) -> MemberBoard {
        let today = businessDate
        let cutoff = store.businessDayCutoffHour
        var visits: [String: MemberSighting] = [:]
        func key(_ ref: MemberRef) -> String? {
            if let id = ref.id { return id }
            return ref.phone.isEmpty ? nil : ref.phone
        }
        func note(_ ref: MemberRef, at: Date, detail: String, inStore: Bool) {
            // 查過的會員補上 id：只有電話的預約、有 id 的結帳才會算成同一個人
            let filled = filledRef(ref)
            guard let k = key(filled) else { return }
            if let old = visits[k], let oldAt = old.at, oldAt > at {
                if inStore && !old.inStore { visits[k]?.inStore = true }
                return
            }
            let stillIn = inStore || (visits[k]?.inStore ?? false)
            visits[k] = MemberSighting(id: k, ref: filled, source: .visit, at: at, detail: detail, inStore: stillIn)
        }
        for s in state.closedSales(businessDate: today) {
            guard let ref = s.member else { continue }
            note(ref, at: s.closedAt, detail: "結帳 \(s.number)・\(s.total.formatted)", inStore: false)
        }
        for c in state.checkIns(businessDate: today, cutoffHour: cutoff) {
            note(c.member, at: c.at, detail: "報到・\(c.passName ?? "單次入場")", inStore: false)
        }
        for t in state.openTickets where t.businessDate == today {
            guard let ref = t.member else { continue }
            note(ref, at: t.openedAt, detail: "單子開著 \(t.number)・\(t.totals.total.formatted)", inStore: true)
        }

        // 今天的預約：還沒結帳的（課程報名只列快開始的：一堂課二十幾個人，全列就看不到別人了）
        var bookings: [String: MemberSighting] = [:]
        for r in reservations where (r.kind == .appointment || r.kind == .classBooking) && r.status.isActive {
            guard TaipeiTime.businessDate(r.startsAt, cutoffHour: cutoff) == today else { continue }
            if r.kind == .classBooking && (r.startsAt.timeIntervalSince(now) > 3 * 3600 || r.endsAt < now) { continue }
            let ref = filledRef(MemberRef(id: r.memberId, phone: r.phone, name: r.name.isEmpty ? nil : r.name))
            guard let k = key(ref), visits[k] == nil, bookings[k] == nil else { continue }
            let label = r.status == .arrived ? "已到店・" : (r.kind == .classBooking ? "報名 " : "預約 ")
            bookings[k] = MemberSighting(id: k, ref: ref, source: .booking, at: r.startsAt, detail: label + bookingSummary(r),
                                         inStore: r.status == .arrived)
        }

        // 這台最近查過的（後台給的上次來店）
        let shown = Set(visits.keys).union(bookings.keys)
        let recent = members.values
            .filter { !shown.contains($0.id) && !shown.contains($0.phone) }
            .sorted { ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast) }
            .prefix(40)
            .map { m in
                MemberSighting(id: m.id, ref: m.ref, source: .recent, at: m.lastVisitAt,
                               detail: m.tierName ?? "會員", inStore: false)
            }

        return MemberBoard(
            bookings: bookings.values.sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) },
            visits: visits.values.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) },
            recent: Array(recent)
        )
    }

    /// 名單上的 ref 補上查過的名字、等級
    private func filledRef(_ ref: MemberRef) -> MemberRef {
        guard let m = rememberedMember(ref) else { return ref }
        var out = ref
        if out.id == nil { out.id = m.id }
        if out.name?.isEmpty ?? true { out.name = m.name }
        if out.tierName == nil { out.tierName = m.tierName }
        return out
    }

    // MARK: - 消費紀錄

    /// 後台的最近幾次＋這台的結帳（同一張單只列一次，新的在上面）
    func memberHistory(for m: Member) -> [MemberHistoryEntry] {
        var out: [MemberHistoryEntry] = []
        var seen = Set<String>()
        for s in state.closedSales().reversed() where Self.isSame(m, s.member) {
            guard seen.insert(s.ticketId).inserted else { continue }
            out.append(historyEntry(s))
        }
        for v in m.recentVisits ?? [] {
            guard seen.insert(v.ticketId).inserted else { continue }
            // 後台整理的品名裡，用卡抵的寫成「洗剪（剪髮 10 次卡）」「私人教練 60 分（私人教練 10 堂）」
            let redeemed = v.items.filter { $0.hasSuffix("卡）") || $0.hasSuffix("堂）") }.count
            out.append(MemberHistoryEntry(ticketId: v.ticketId, number: v.number, at: v.at, total: v.total, items: v.items, staffNames: v.staffNames,
                                          note: v.note, redeemed: redeemed, prepaid: .zero, refunded: .zero, onThisDevice: false))
        }
        return out.sorted { $0.at > $1.at }
    }

    private func historyEntry(_ s: SaleRecord) -> MemberHistoryEntry {
        let items = s.lines.map { l -> String in
            var text = l.displayName
            if !l.modifiers.isEmpty { text += "・\(l.modifiers)" }
            if l.quantity > 1 { text += " ×\(l.quantity)" }
            if let r = l.redeem { text += "（\(r.name)）" }
            return text
        }
        // 誰做的：有服務就列做服務的人（設計師、教練），沒有就列業績算給的人（店員）
        let services = s.lines.filter { $0.kind == .service }
        var names: [String] = []
        for l in services.isEmpty ? s.lines : services {
            guard let id = l.staffId, let person = staffMember(id), !names.contains(person.name) else { continue }
            names.append(person.name)
        }
        let prepaid = Money.sum(s.payments.filter { $0.tender == .prepaid }.map(\.amount))
        let refunded = state.tickets[s.ticketId]?.refundedAmount ?? .zero
        return MemberHistoryEntry(ticketId: s.ticketId, number: s.number, at: s.closedAt, total: s.total, items: items, staffNames: names,
                                  note: s.note.isEmpty ? nil : s.note, redeemed: s.lines.filter { $0.redeem != nil }.count,
                                  prepaid: prepaid, refunded: refunded, onThisDevice: true)
    }

    // MARK: - 生日

    /// 「10/18」（後台給 MM-DD）
    static func birthdayText(_ birthday: String?) -> String? {
        guard let b = birthday else { return nil }
        let parts = b.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let (month, day) = parts.count == 3 ? (parts[1], parts[2]) : (parts[0], parts[1])
        return "\(month)/\(day)"
    }

    /// 當月壽星
    static func isBirthdayMonth(_ birthday: String?, now: Date = Date()) -> Bool {
        guard let b = birthday else { return false }
        let parts = b.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let month = parts.count == 3 ? parts[1] : parts[0]
        return month == TaipeiTime.components(now).month
    }

    // MARK: - 示範

    /// 開一家示範的店（配對畫面選的、或啟動參數 `-demo apparel|salon|fitness|cafe`）：
    /// 每家從自己的預設營業模式開始；上一家示範查過的會員、歷史不帶過來
    func startDemo(kind: DemoKind) {
        DemoStore.kind = kind
        // 每家從自己的預設模式開始（截圖用的 -serviceMode 參數除外）
        if LaunchArguments.value("-serviceMode") == nil { settings.serviceMode = "" }
        members = [:]
        historyCache = [:]
        classes = []
        startDemo()
        guard isDemo, let api else { return }
        let day = businessDate
        Task {
            if let list = try? await api.classes(date: day) {
                classes = list.sorted { $0.startsAt < $1.startsAt }
            }
        }
    }
}
