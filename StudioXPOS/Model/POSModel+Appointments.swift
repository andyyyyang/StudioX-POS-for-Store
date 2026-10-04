import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 櫃台查會員的結果（報到、預約、課程報名共用）
enum FrontDeskLookup {
    /// 後台查到了（已經記進 members）
    case found(Member)
    /// 離線：用這台查過的資料（帳戶加上這台記的事件，還是對的）
    case cached(Member)
    /// 後台說沒有這個人
    case notFound
    /// 離線、這台也沒查過
    case offline
    case failed(String)
}

/// 入場要用哪一張卡、為什麼不能進
struct CheckInPlan {
    enum Problem: Equatable {
        /// 會籍（或有期限的卡）過期了幾天
        case expired(days: Int, name: String)
        /// 次數用完
        case usedUp(name: String)
        /// 一張卡都沒有
        case noPass
        /// 沒開會員帳戶（後台沒有儲值與課程卡）
        case noAccount
    }

    /// 這次要用的卡（期間會籍優先：不扣次數）
    var pass: MemberPass?
    /// 能用來入場的所有卡（可以換一張用）
    var choices: [MemberPass]
    var problem: Problem?

    var canEnter: Bool { pass != nil }

    /// 用這張卡扣幾次（次數卡 1、期間會籍 0）
    static func uses(of pass: MemberPass?) -> Int {
        guard let pass else { return 0 }
        return pass.spec.kind == .visits ? 1 : 0
    }
}

/// 預約表（美業的設計師、私人教練）、入場報到（健身房）、團體課的動作。
///
/// 預約與課程報名存在後台（網站、LINE 預約的也在那裡）；報到是事件（扣次數、斷網照樣記）。
extension POSModel {
    // MARK: - 讀

    /// 某一天（台北日期 yyyy-MM-dd）的訂位、預約、課程報名：合進 reservations，只換掉那一天的（別天的留著）
    func loadReservations(for date: String) async {
        guard let api else { return }
        do {
            let fetched = try await api.reservations(date: date)
            let ids = Set(fetched.map(\.id))
            let cutoff = store.businessDayCutoffHour
            var list = reservations.filter { r in
                !ids.contains(r.id) && TaipeiTime.businessDate(r.startsAt, cutoffHour: cutoff) != date
            }
            list.append(contentsOf: fetched)
            reservations = list.sorted { $0.startsAt < $1.startsAt }
        } catch {
            // 離線：用手上的
        }
    }

    /// 今天的團體課（課表在後台排）
    func loadClasses(for date: String? = nil) async {
        guard let api else { return }
        do {
            classes = try await api.classes(date: date ?? businessDate).sorted { $0.startsAt < $1.startsAt }
        } catch {
            // 離線：用手上的
        }
    }

    // MARK: - 會員

    /// 用手機號碼或會員卡號查（查到就記住）
    func findMember(code: String) async -> FrontDeskLookup {
        let digits = code.filter(\.isNumber)
        guard let api else {
            if let m = cachedMember(code: digits) { return .cached(m) }
            return .failed("這台還沒連上後台")
        }
        do {
            if let m = try await api.member(phone: digits) {
                remember(m)
                return .found(m)
            }
            return .notFound
        } catch let e as APIError {
            if case .offline = e {
                if let m = cachedMember(code: digits) { return .cached(m) }
                return .offline
            }
            return .failed(e.userMessage)
        } catch {
            return .failed("查不到，請再試一次")
        }
    }

    /// 這台查過的會員裡有沒有這支電話
    func cachedMember(code: String) -> Member? {
        members.values.first { $0.phone == code }
    }

    /// 當場加入會員（電話一定要有；名字可以之後再補）
    func createMember(phone: String, name: String?) async -> Member? {
        guard let api else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = MemberCreate(phone: phone, name: trimmed.isEmpty ? nil : trimmed)
        do {
            let m = try await api.createMember(request)
            remember(m)
            return m
        } catch let e as APIError {
            alert = AlertInfo(title: "加不了會員", message: e.userMessage)
        } catch {
            alert = AlertInfo(title: "加不了會員", message: error.localizedDescription)
        }
        return nil
    }

    /// 預約上的客人（查過的會員用查到的資料；只有電話也帶著，結帳時後台再對）
    func memberRef(for r: Reservation) -> MemberRef? {
        if let id = r.memberId, let m = members[id] { return m.ref }
        if let id = r.memberId { return MemberRef(id: id, phone: r.phone, name: r.name.isEmpty ? nil : r.name) }
        if !r.phone.isEmpty { return MemberRef(phone: r.phone, name: r.name.isEmpty ? nil : r.name) }
        return nil
    }

    // MARK: - 預約

    /// 某一天（台北日期）的預約
    func appointments(onDay day: String) -> [Reservation] {
        reservations.filter { $0.kind == .appointment && TaipeiTime.dayString($0.startsAt) == day }
    }

    /// 這個人這段時間被約走了沒（沒指定人就不算撞）
    func appointmentConflicts(staffId: String?, start: Date, minutes: Int, ignoring id: String?) -> [Reservation] {
        guard let staffId else { return [] }
        return Reservation.conflicts(staffId: staffId, start: start, minutes: minutes, in: reservations, ignoring: id)
    }

    /// 這筆預約開的單（還沒結的）
    func openTicket(for r: Reservation) -> Ticket? {
        if let id = r.ticketId, let t = state.tickets[id], t.isOpen { return t }
        return state.openTickets.first { $0.appointmentId == r.id }
    }

    /// 改預約的狀態；後台存不了（離線）也先改手上的，預約表才看得出來（下次抓到後台的再對齊）
    func markAppointment(_ r: Reservation, status: ReservationStatus, ticketId: String? = nil) async {
        let saved = await saveReservationQuietly(id: r.id, ReservationInput(status: status, ticketId: ticketId))
        if saved == nil, let i = reservations.firstIndex(where: { $0.id == r.id }) {
            reservations[i].status = status
            if let ticketId { reservations[i].ticketId = ticketId }
        }
    }

    /// 改時間、換人（撞不撞由畫面先問過）
    func reschedule(_ r: Reservation, to start: Date, minutes: Int, staffId: String?) async -> Reservation? {
        await saveReservation(id: r.id, ReservationInput(startsAt: start, durationMinutes: minutes, staffId: staffId))
    }

    /// 開始服務：開單（帶客人、預約）、把預約的服務照指定的人加進去，預約改成「服務中」。已經開過單就選那張
    @discardableResult
    func startService(_ r: Reservation) async -> Ticket? {
        if let t = openTicket(for: r) {
            selectedTicketId = t.id
            return t
        }
        guard let me = currentStaff else { return nil }
        var ref = memberRef(for: r)
        // 只有電話（網站、電話預約）：先查一次會員，課程卡、儲值金才看得到
        if ref?.id == nil, !r.phone.isEmpty {
            switch await findMember(code: r.phone) {
            case .found(let m), .cached(let m): ref = m.ref
            case .notFound, .offline, .failed: break
            }
        }
        let name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = openTicket(type: mode.defaultOrderType, customerName: name.isEmpty ? nil : name, member: ref, appointmentId: r.id) else { return nil }
        for s in r.services ?? [] {
            let who = s.staffId ?? r.staffId
            if let item = catalog.item(s.itemId) {
                add(item, quantity: 1, modifiers: [], note: "", price: s.price, staffId: who)
            } else {
                // 菜單上已經沒有這一項：照預約上的名字、價格加一行
                let line = TicketLine(id: newID(), itemId: nil, name: s.name, unitPrice: s.price ?? .zero, addedAt: Date(), addedBy: me.id,
                                      kind: .service, staffId: who, durationMinutes: s.durationMinutes)
                record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line])))
            }
        }
        await markAppointment(r, status: .seated, ticketId: t.id)
        selectedTicketId = t.id
        show("\(name.isEmpty ? t.number : name) 開始服務・\(t.number)" + (role.takesPayment ? "" : "・已同步到結帳櫃台"))
        return state.tickets[t.id]
    }

    /// 現場客（沒有預約）：右側鍵盤問電話（不留就直接按「開單」），開一張單
    @discardableResult
    func walkIn() async -> Ticket? {
        let spec = KeypadSpec(kind: .code(minLength: 0, maxLength: 10), title: "現場客", subtitle: "打電話查會員；不留電話直接按「開單」", confirmLabel: "開單")
        guard let entry = await keypad.ask(spec, validate: { e in
            e.digits.isEmpty || (e.digits.count == 10 && e.digits.hasPrefix("09")) ? nil : "手機號碼是 09 開頭 10 碼；不留電話就清空"
        }) else { return nil }
        var ref: MemberRef? = nil
        if !entry.digits.isEmpty {
            switch await findMember(code: entry.digits) {
            case .found(let m), .cached(let m):
                ref = m.ref
            case .notFound:
                let created = await createMember(phone: entry.digits, name: nil)
                ref = created?.ref ?? MemberRef(phone: entry.digits)
            case .offline, .failed:
                ref = MemberRef(phone: entry.digits)
            }
        }
        guard let t = openTicket(type: mode.defaultOrderType, member: ref) else { return nil }
        let who = ref.map { $0.name ?? $0.maskedPhone } ?? "現場客"
        show("\(who) 開單・\(t.number)" + (role.takesPayment ? "" : "・已同步到結帳櫃台"))
        return t
    }

    // MARK: - 入場報到

    /// 這個會員現在能不能進、用哪一張卡
    func checkInPlan(for m: Member, at date: Date = Date()) -> CheckInPlan {
        guard let acct = account(for: m.ref) else {
            return CheckInPlan(pass: nil, choices: [], problem: .noAccount)
        }
        let choices = acct.checkInPasses(at: date)
        if let first = choices.first { return CheckInPlan(pass: first, choices: choices, problem: nil) }
        // 不能進：最近一張入場用的卡是過期還是用完
        let entryPasses = acct.passes.filter { $0.spec.checkIn && $0.status != .cancelled }
        let latest = entryPasses.max { ($0.expiresAt ?? $0.startsAt) < ($1.expiresAt ?? $1.startsAt) }
        guard let latest else { return CheckInPlan(pass: nil, choices: [], problem: .noPass) }
        if let e = latest.expiresAt, e <= date {
            let days = max(1, Int((date.timeIntervalSince(e) / 86_400).rounded(.up)))
            return CheckInPlan(pass: nil, choices: [], problem: .expired(days: days, name: latest.name))
        }
        if latest.spec.kind == .visits && (latest.remaining ?? 0) <= 0 {
            return CheckInPlan(pass: nil, choices: [], problem: .usedUp(name: latest.name))
        }
        return CheckInPlan(pass: nil, choices: [], problem: .noPass)
    }

    /// 記一筆入場（用卡就扣次數；沒卡的單次入場 pass 是 nil，另外開單收錢）
    @discardableResult
    func recordCheckIn(_ ref: MemberRef, pass: MemberPass?, sessionId: String? = nil, reservationId: String? = nil, note: String = "") -> CheckIn? {
        guard let me = currentStaff else { return nil }
        let ci = CheckIn(id: newID(), member: ref, passId: pass?.id, passName: pass?.name, uses: CheckInPlan.uses(of: pass),
                         sessionId: sessionId, reservationId: reservationId, note: note, at: Date(), by: me.id)
        guard record(.checkedIn(CheckedIn(checkIn: ci))) else { return nil }
        return ci
    }

    /// 取消報到（店長）：次數還回去；課程的報名改回「已預約」
    func voidCheckIn(_ c: CheckIn, reason: String) async -> Bool {
        let who = c.member.name ?? c.member.maskedPhone
        guard await authorize(.voidTicket, detail: "取消 \(who) 的報到") != nil else { return false }
        guard record(.checkInVoided(CheckInVoided(checkInId: c.id, reason: reason))) else { return false }
        if let rid = c.reservationId, let r = reservations.first(where: { $0.id == rid }) {
            await markAppointment(r, status: .booked)
        }
        show("已取消 \(who) 的報到" + (c.uses > 0 ? "・次數還回去了" : ""), tone: .neutral)
        return true
    }

    /// 續約、買卡、儲值：加到這位會員開著的單（沒有就開一張），然後結帳
    func sell(_ item: MenuItem, to ref: MemberRef) async {
        var price: Money? = nil
        if item.openPrice {
            guard let p = await keypad.askMoney(item.itemKind == .storedValue ? .topUp() : .openPrice(name: item.name)) else { return }
            price = p
        }
        if let id = ref.id, let open = state.openTickets.first(where: { $0.member?.id == id }) {
            selectedTicketId = open.id
        } else {
            guard openTicket(type: mode.defaultOrderType, member: ref) != nil else { return }
        }
        add(item, quantity: 1, modifiers: [], note: "", price: price)
        if let t = selectedTicket { checkoutOrHandOff(t) }
    }

    /// 開好單之後：會收錢的崗位直接結帳；報到接待（不收錢）交給結帳櫃台
    func checkoutOrHandOff(_ t: Ticket) {
        if role.takesPayment {
            beginCheckout(t)
        } else {
            let who = t.member.map { $0.name ?? $0.maskedPhone } ?? t.number
            show("\(who) 的單 \(t.number)・\(t.totals.amountDue.formatted) 已同步到結帳櫃台")
        }
    }

    // MARK: - 團體課

    /// 這堂課的名單（取消的不列）
    func roster(of s: ClassSession) -> [Reservation] {
        reservations.filter { $0.kind == .classBooking && $0.sessionId == s.id && $0.status != .cancelled }
    }

    /// 能抵這堂課的卡（期間會籍優先）
    func classPass(for account: MemberAccount, session: ClassSession, at date: Date = Date()) -> MemberPass? {
        let categoryId = session.itemId.flatMap { catalog.item($0) }?.categoryId
        let passes = account.passes(covering: session.itemId, categoryId: categoryId, at: date)
        return passes.first { $0.spec.kind == .period } ?? passes.first
    }

    /// 報名一堂課
    func bookClass(_ s: ClassSession, member: Member?, name: String, phone: String) async -> Reservation? {
        let input = ReservationInput(kind: .classBooking, name: name, phone: phone, partySize: 1, startsAt: s.startsAt,
                                     durationMinutes: s.durationMinutes, memberId: member?.id, sessionId: s.id)
        guard let r = await saveReservation(id: nil, input) else { return nil }
        if let i = classes.firstIndex(where: { $0.id == s.id }) { classes[i].booked += 1 }
        show("\(name) 報名了 \(s.name)")
        return r
    }

    /// 取消報名（名額空出來）
    func cancelClassBooking(_ r: Reservation) async {
        guard await saveReservationQuietly(id: r.id, ReservationInput(status: .cancelled)) != nil else {
            show("離線，取消不了報名，連上網路再試", tone: .warning)
            return
        }
        if let sid = r.sessionId, let i = classes.firstIndex(where: { $0.id == sid }) { classes[i].booked = max(classes[i].booked - 1, 0) }
        show("已取消 \(r.name) 的報名", tone: .neutral)
    }

    /// 課程簽到：用卡扣次數（期間會籍不扣），報名改成「已報到」
    @discardableResult
    func signIn(_ r: Reservation, session: ClassSession, member: Member?, pass: MemberPass?) async -> Bool {
        let ref = member?.ref ?? memberRef(for: r) ?? MemberRef(phone: r.phone, name: r.name)
        guard recordCheckIn(ref, pass: pass, sessionId: session.id, reservationId: r.id, note: pass == nil ? "單堂" : "") != nil else { return false }
        await markAppointment(r, status: .seated)
        var left = ""
        if let p = pass, p.spec.kind == .visits, let remaining = p.remaining { left = "・剩 \(max(remaining - 1, 0)) 次" }
        show("\(r.name) 簽到・\(session.name)\(left)")
        return true
    }

    /// 沒卡的人上一堂：開單收單堂價，順便簽到，然後結帳
    func dropIn(_ r: Reservation?, session: ClassSession, member: Member?) async {
        guard let me = currentStaff else { return }
        let ref = member?.ref ?? r.flatMap { memberRef(for: $0) }
        let name = r?.name ?? member?.name
        guard let t = openTicket(type: mode.defaultOrderType, customerName: name, member: ref) else { return }
        if let id = session.itemId, let item = catalog.item(id) {
            add(item, quantity: 1, modifiers: [], note: "", price: session.dropInPrice, staffId: session.staffId)
        } else {
            let price = session.dropInPrice ?? .zero
            let line = TicketLine(id: newID(), itemId: nil, name: "\(session.name)（單堂）", unitPrice: price, addedAt: Date(), addedBy: me.id,
                                  kind: .service, staffId: session.staffId, durationMinutes: session.durationMinutes)
            record(.linesAdded(LinesAdded(ticketId: t.id, lines: [line])))
        }
        if let r {
            recordCheckIn(ref ?? MemberRef(phone: r.phone, name: r.name), pass: nil, sessionId: session.id, reservationId: r.id, note: "單堂 \(t.number)")
            await markAppointment(r, status: .seated)
        }
        if let fresh = state.tickets[t.id] { checkoutOrHandOff(fresh) }
    }

    // MARK: - 內部

    /// 存預約但不跳錯誤（狀態這種小事：離線就先改手上的）
    private func saveReservationQuietly(id: String, _ input: ReservationInput) async -> Reservation? {
        guard let api else { return nil }
        do {
            let r = try await api.updateReservation(id: id, input)
            if let i = reservations.firstIndex(where: { $0.id == r.id }) { reservations[i] = r } else { reservations.append(r) }
            reservations.sort { $0.startsAt < $1.startsAt }
            return r
        } catch {
            return nil
        }
    }
}
