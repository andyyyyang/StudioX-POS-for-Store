import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 錢櫃與交班：開班（零用金）、存入／取出、只開錢櫃、交班點錢（右側鍵盤一種面額一種面額打）、打卡
extension POSModel {
    func startShift() async {
        guard openShift == nil else { return }
        let suggested = state.shifts.values.filter { $0.deviceId == device.id && !$0.isOpen }.max { $0.openedAt < $1.openedAt }?.openingCash ?? Money(dollars: 2000)
        guard let cash = await keypad.askMoney(.openingCash(suggested: suggested)) else { return }
        guard record(.shiftOpened(ShiftOpened(shiftId: newID(), openingCash: cash, businessDate: businessDate))) else { return }
        printers.openDrawer()
        show("開班了・零用金 \(cash.formatted)")
    }

    func moveCash(_ kind: CashMoveKind, reason: String) async {
        guard let shift = openShift, let me = currentStaff else {
            show("請先開班", tone: .warning)
            return
        }
        guard let auth = await authorize(kind == .noSale ? .openDrawer : .cashInOut, detail: kind.label) else { return }
        var amount = Money.zero
        if kind != .noSale {
            guard let m = await keypad.askMoney(.cashMove(kind)) else { return }
            amount = m
        }
        let move = CashMove(id: newID(), kind: kind, amount: amount, reason: reason, at: Date(), by: me.id, authorizedBy: auth.authorizerId)
        guard record(.cashMoved(CashMoved(shiftId: shift.id, move: move))) else { return }
        printers.openDrawer()
        show(kind == .noSale ? "已開錢櫃" : "\(kind.label) \(amount.formatted)")
    }

    /// 點錢：常用面額一個一個問（打 0 或直接按「下一個」跳過）；中途取消回 nil
    func countCash(start: CashCount = CashCount()) async -> CashCount? {
        var count = start
        for d in Denomination.common {
            guard let n = await keypad.askNumber(.denomination(d, current: count.count(d))) else { return nil }
            count.set(d, n)
        }
        return count
    }

    /// 交班：存交班單、印 Z 帳、推播給負責人（後台做）
    func closeShift(counted: CashCount, note: String) async {
        guard let shift = openShift else { return }
        guard await authorize(.closeShift, detail: "交班") != nil else { return }
        let open = state.openTickets.filter { $0.deviceId == device.id && !$0.approvedPayments.isEmpty }
        if !open.isEmpty {
            alert = AlertInfo(title: "還有收了一部分錢的單", message: "\(open.map(\.number).joined(separator: "、")) 收了錢還沒結帳，請先結完或退回再交班。")
            return
        }
        let expected = state.expectedCash(shiftId: shift.id)
        var closing = shift
        closing.closedAt = Date()
        closing.closedBy = currentStaff?.id
        closing.counted = counted
        closing.expectedAtClose = expected
        let report = ShiftReport(shift: closing, state: state, now: Date(), counted: counted)
        guard record(.shiftClosed(ShiftClosed(shiftId: shift.id, counted: counted, expected: expected, note: note, report: report))) else { return }
        printers.print(Templates.shiftReport(report, store: store, deviceName: device.name, staffName: { self.staffName($0) }), role: .receipt)
        let diff = report.difference ?? .zero
        show("已交班" + (diff.isZero ? "・現金相符" : diff.isNegative ? "・短少 \(Money(cents: -diff.cents).formatted)" : "・溢收 \(diff.formatted)"),
             tone: diff.isZero ? .active : .warning)
    }

    /// X 帳：交班前看一下（不關班）
    func printXReport() {
        guard let shift = openShift else { return }
        let report = ShiftReport(shift: shift, state: state, now: Date())
        printers.print(Templates.shiftReport(report, store: store, deviceName: device.name, staffName: { self.staffName($0) }), role: .receipt)
    }

    // MARK: 打卡

    func isClockedIn(_ s: StaffMember) -> Bool { state.clockedIn.contains(s.id) }

    func toggleClock(_ s: StaffMember) {
        if isClockedIn(s) {
            record(.clockedOut(StaffRef(staffId: s.id)))
            show("\(s.name) 下班了・今天 \(hoursToday(s))", tone: .neutral)
        } else {
            record(.clockedIn(StaffRef(staffId: s.id)))
            show("\(s.name) 上班了")
        }
    }

    func hoursToday(_ s: StaffMember) -> String {
        let minutes = state.attendance.filter { $0.staffId == s.id && TaipeiTime.businessDate($0.inAt, cutoffHour: store.businessDayCutoffHour) == businessDate }
            .reduce(0) { $0 + $1.minutes(now: Date()) }
        return "\(minutes / 60) 小時 \(minutes % 60) 分"
    }
}

/// 訂位與候位（存在後台：網站、電話訂的也在這裡）
extension POSModel {
    func loadReservations() async {
        guard let api else { return }
        do {
            reservations = try await api.reservations(date: businessDate).sorted { $0.startsAt < $1.startsAt }
        } catch {}
    }

    func saveReservation(id: String?, _ input: ReservationInput) async -> Bool {
        guard let api else { return false }
        do {
            let r: Reservation
            if let id {
                r = try await api.updateReservation(id: id, input)
            } else {
                r = try await api.createReservation(input)
            }
            if let i = reservations.firstIndex(where: { $0.id == r.id }) { reservations[i] = r } else { reservations.append(r) }
            reservations.sort { $0.startsAt < $1.startsAt }
            return true
        } catch let e as APIError {
            alert = AlertInfo(title: "存不了", message: e.userMessage)
        } catch {
            alert = AlertInfo(title: "存不了", message: error.localizedDescription)
        }
        return false
    }

    func setStatus(_ status: ReservationStatus, for r: Reservation) async {
        _ = await saveReservation(id: r.id, ReservationInput(status: status))
    }

    /// 候位叫號：發簡訊「您的位子好了」
    func notify(_ r: Reservation) async {
        guard let api else { return }
        do {
            try await api.notifyReservation(id: r.id)
            if let i = reservations.firstIndex(where: { $0.id == r.id }) {
                reservations[i].status = .notified
                reservations[i].notifiedAt = Date()
            }
            show("已通知 \(r.name)")
        } catch let e as APIError {
            if case .http(_, "sms_off", _) = e {
                alert = AlertInfo(title: "沒有開簡訊", message: "這家店沒有「簡訊」服務，請直接打電話給客人：\(r.phone)")
            } else {
                alert = AlertInfo(title: "沒有送出", message: e.userMessage)
            }
        } catch {}
    }

    /// 入座：開單、桌號、人數、稱呼，訂位改成「已入座」
    func seat(_ r: Reservation, at tableIds: [String]) async {
        guard let t = openTicket(type: .dineIn, tableIds: tableIds, guests: r.partySize, customerName: r.name) else { return }
        _ = await saveReservation(id: r.id, ReservationInput(tableIds: tableIds, status: .seated))
        selectedTicketId = t.id
        section = .order
    }
}
