import AudioToolbox
import Foundation
import POSCore
import POSSync

/// 外送平台（Uber Eats、foodpanda）：平台的單在後台收下、變成一張「外送」的單同步過來（docs/DELIVERY.md）。
///
///   待接單（倒數）──打分鐘數、接單──▶ 這台結帳（平台已經收了錢）、送廚房 ──全部做好──▶ 自動告訴平台「出餐好了」
///                                                                              ──外送員拿走──▶ 結束
///
/// 接單、拒單要連線（平台那邊有時限，斷線時擋住按鈕並說明）；示範模式在這台自己演一次。
extension POSModel {
    // MARK: - 狀態

    /// 這家店有串外送平台
    var deliveryEnabled: Bool { features.delivery && !(deliveryConfig?.enabled.isEmpty ?? true) }

    /// 待接單：最快到期的在前面
    var deliveryPending: [Ticket] {
        state.tickets.values
            .filter { $0.isOpen && $0.delivery?.status == .pending }
            .sorted { ($0.delivery?.acceptBy ?? .distantFuture) < ($1.delivery?.acceptBy ?? .distantFuture) }
    }

    /// 接了、還沒被拿走的（多半已經結帳）：答應的時間最早的在前面
    var deliveryActive: [Ticket] {
        state.tickets.values
            .filter { t in
                guard t.status != .voided, let d = t.delivery else { return false }
                return d.status == .accepted || d.status == .ready
            }
            .sorted { ($0.delivery?.readyAt ?? .distantFuture) < ($1.delivery?.readyAt ?? .distantFuture) }
    }

    /// 接單之後才被平台取消、錢已經記了：要退款
    var deliveryNeedsRefund: [Ticket] {
        state.tickets.values.filter { t in
            t.status == .closed && t.delivery?.status == .cancelled && t.refundedAmount < t.totals.total
        }
    }

    func deliveryState(_ p: DeliveryPlatform) -> DeliveryPlatformState? { deliveryConfig?.state(p) }

    /// 有平台被暫停（店裡按的、或 POS 斷線時後台自動暫停的）
    var deliveryPaused: [DeliveryPlatformState] { deliveryConfig?.enabled.filter { !$0.isOnline } ?? [] }

    /// 忙碌：多加的分鐘數（各平台一樣，取最大）
    var deliveryBusyMinutes: Int { deliveryConfig?.enabled.map(\.busyExtraMinutes).max() ?? 0 }

    /// 廚房現在還沒做好的份數（內用、外帶、叫號、外送一起算）
    var kitchenLoad: Int {
        kitchenTickets().flatMap(\.lines)
            .filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) }
            .reduce(0) { $0 + $1.quantity }
    }

    /// 建議的備餐時間：平台設定的基本時間＋廚房現在的份數＋忙碌加的（PrepTimeAdvisor）
    func suggestedPrepMinutes(for t: Ticket) -> Int {
        let p = t.delivery.flatMap { deliveryState($0.platform) }
        let advisor = PrepTimeAdvisor(baseMinutes: p?.defaultPrepMinutes ?? 15, busyExtraMinutes: p?.busyExtraMinutes ?? 0)
        return advisor.suggest(pendingItems: kitchenLoad, orderItems: t.itemCount)
    }

    // MARK: - 動作

    /// 接單：告訴平台幾分鐘做好；這台接的就由這台結帳（平台已經收了錢）、送廚房
    func acceptDelivery(_ t: Ticket, prepMinutes: Int) async {
        guard let d = t.delivery, d.status == .pending else { return }
        let minutes = min(max(prepMinutes, 5), 120)
        await deliveryAction(t) {
            if isDemo {
                guard record(.deliveryUpdated(DeliveryUpdated(ticketId: t.id, status: .accepted, readyAt: Date().addingTimeInterval(Double(minutes) * 60),
                                                              prepMinutes: minutes, acceptedBy: device.id))) else { return }
            } else {
                guard let api else { throw APIError.offline("沒有連上後台") }
                do {
                    let r = try await api.delivery(.accept(orderId: d.orderId, prepMinutes: minutes))
                    // 後台記的接單事件等一下同步來；先把這台要做的做掉（結帳、送廚房），不用等
                    guard r.mine != false else {
                        show("另一台接了 \(d.title)", tone: .neutral)
                        return
                    }
                } catch let e as APIError where e.isAlreadyAccepted {
                    show("另一台已經接了 \(d.title)", tone: .neutral)
                    return
                }
            }
            show("已接單 \(d.title)・\(minutes) 分鐘")
            await settleDelivery(t)
            if !isDemo { await syncNow() }
        }
    }

    /// 拒單（後台告訴平台、這張單作廢）
    func rejectDelivery(_ t: Ticket, reason: DeliveryReason) async {
        guard let d = t.delivery, d.status == .pending else { return }
        await deliveryAction(t) {
            if isDemo {
                record([.deliveryUpdated(DeliveryUpdated(ticketId: t.id, status: .rejected, reason: reason.label)),
                        .ticketVoided(TicketVoided(ticketId: t.id, reason: "外送拒單：\(reason.label)"))])
            } else {
                guard let api else { throw APIError.offline("沒有連上後台") }
                _ = try await api.delivery(.reject(orderId: d.orderId, reason: reason, message: nil))
                await syncNow()
            }
            if selectedTicketId == t.id { selectedTicketId = nil }
            show("已拒單 \(d.title)（\(reason.label)）", tone: .neutral)
        }
    }

    /// 出餐好了：平台叫外送員、通知自取的客人。廚房把整張單做好時自動按（kitchenDidUpdate）
    func markDeliveryReady(_ t: Ticket, quiet: Bool = false) async {
        guard let d = t.delivery, d.status == .accepted else { return }
        await deliveryAction(t) {
            if isDemo {
                record(.deliveryUpdated(DeliveryUpdated(ticketId: t.id, status: .ready)))
            } else {
                guard let api else { throw APIError.offline("沒有連上後台") }
                _ = try await api.delivery(.ready(orderId: d.orderId))
                await syncNow()
            }
            if !quiet { show("\(d.title) 出餐好了，已通知 \(d.platform.label)") }
        }
    }

    /// 外送員拿走了（平台會自己通知；示範、或平台沒通知時手動按）
    func markDeliveryPickedUp(_ t: Ticket) {
        guard let d = t.delivery, !d.status.isFinal else { return }
        record(.deliveryUpdated(DeliveryUpdated(ticketId: t.id, status: .pickedUp)))
        show("\(d.title) 已取餐")
    }

    /// 接了之後取消（做不出來）：平台退客人的錢；這張單的錢要退（右欄提示）
    func cancelDelivery(_ t: Ticket, reason: DeliveryReason) async {
        guard let d = t.delivery, d.status == .accepted || d.status == .ready else { return }
        await deliveryAction(t) {
            if isDemo {
                record(.deliveryUpdated(DeliveryUpdated(ticketId: t.id, status: .cancelled, reason: reason.label)))
            } else {
                guard let api else { throw APIError.offline("沒有連上後台") }
                _ = try await api.delivery(.cancel(orderId: d.orderId, reason: reason, message: nil))
                await syncNow()
            }
            show("已取消 \(d.title)，記得退款", tone: .warning)
        }
    }

    /// 忙碌：之後的單備餐時間多加幾分鐘（0＝恢復）
    func setDeliveryBusy(_ extra: Int) async {
        await deliveryStoreAction(.busy(extraMinutes: extra, minutes: nil)) { p in p.busyExtraMinutes = extra }
        show(extra > 0 ? "外送忙碌：之後的單多加 \(extra) 分鐘" : "外送恢復正常備餐時間", tone: extra > 0 ? .warning : .active)
    }

    /// 暫停接單（nil＝全部平台；minutes nil＝到明天開店）
    func pauseDelivery(_ platform: DeliveryPlatform?, minutes: Int?) async {
        let until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        await deliveryStoreAction(.pause(platform: platform, minutes: minutes), only: platform) { p in
            p.status = "paused"; p.pausedUntil = until; p.pausedBy = "manual"
        }
        show("\(platform?.label ?? "外送平台")暫停接單" + (minutes.map { " \($0) 分鐘" } ?? "（到明天開店）"), tone: .warning)
    }

    func resumeDelivery(_ platform: DeliveryPlatform?) async {
        await deliveryStoreAction(.resume(platform: platform), only: platform) { p in
            p.status = "online"; p.pausedUntil = nil; p.pausedBy = nil
        }
        show("\(platform?.label ?? "外送平台")恢復接單")
    }

    /// 測試單（後台開了測試模式；示範模式在這台做一張）
    func simulateDelivery(_ platform: DeliveryPlatform) async {
        if isDemo {
            DemoDelivery.place(platform: platform, in: self)
            return
        }
        guard let api else { return }
        do {
            _ = try await api.delivery(.simulate(platform: platform))
            await syncNow()
        } catch {
            show((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .warning)
        }
    }

    /// 各平台最新的狀態（設定頁、右欄的平台狀態）
    func refreshDelivery() async {
        guard features.delivery, !isDemo, let api else { return }
        if let r = try? await api.delivery() { deliveryConfig = DeliveryConfig(platforms: r.platforms) }
    }

    // MARK: - 自動

    /// 每兩秒（POSModel 的背景工作）：新的外送單響一聲、這台負責的已接單結帳；refresh＝順便更新各平台的狀態
    func deliveryBackgroundTick(refresh: Bool) async {
        guard features.delivery else { return }
        if refresh { await refreshDelivery() }
        guard deliveryEnabled, phase == .ready else { return }
        let pending = deliveryPending
        let fresh = pending.filter { !deliverySeen.contains($0.id) }
        if let first = fresh.first, let d = first.delivery {
            deliverySeen.formUnion(fresh.map(\.id))
            // 響一聲（和平板版的平台 App 一樣要聽得到），右上角提示
            AudioServicesPlaySystemSound(1007)
            show(fresh.count > 1 ? "\(fresh.count) 張外送新單" : "\(d.platform.label) 新單 #\(d.code)・\(first.itemCount) 項", tone: .warning)
        }
        // 這台接的（或後台自動接、指定這台）還沒結帳的：結帳、送廚房
        for t in state.tickets.values where t.isOpen {
            guard let d = t.delivery, d.status == .accepted || d.status == .ready else { continue }
            let mine = d.acceptedBy == device.id || (d.acceptedBy == "server" && role.hasDrawer)
            if mine && !deliveryBusy.contains(t.id) { await settleDelivery(t) }
        }
    }

    /// 廚房改了狀態：外送的單整張都做好了 → 自動告訴平台「出餐好了」（不用另外按）
    func kitchenDidUpdate(_ ticketId: String) {
        guard let t = state.tickets[ticketId], let d = t.delivery, d.status == .accepted else { return }
        let lines = t.activeLines
        guard !lines.isEmpty, lines.allSatisfy({ $0.kitchen == .ready || $0.kitchen == .served }) else { return }
        Task { await markDeliveryReady(t, quiet: true) }
    }

    // MARK: - 內部

    /// 接了的外送單：發票照平台給的載具／統編（有給才有）、結帳（平台代收的錢已經記了）、送廚房
    private func settleDelivery(_ given: Ticket) async {
        guard let t = state.tickets[given.id], t.isOpen, currentStaff != nil else { return }
        deliveryBusy.insert(t.id)
        defer { deliveryBusy.remove(t.id) }
        if let buyer = t.delivery?.invoice?.buyer, t.invoiceBuyer == .paper {
            record(.ticketUpdated(TicketUpdated(ticketId: t.id, invoiceBuyer: buyer)))
        }
        guard let fresh = state.tickets[t.id], fresh.totals.isPaidInFull else {
            show("\(t.delivery?.title ?? t.number) 的平台付款和金額對不上，請檢查", tone: .danger)
            return
        }
        await complete(fresh)
    }

    /// 送一個單的動作（同一張單同時只送一個；失敗說明原因）
    private func deliveryAction(_ t: Ticket, _ work: () async throws -> Void) async {
        guard !deliveryBusy.contains(t.id) else { return }
        touch()
        deliveryBusy.insert(t.id)
        defer { deliveryBusy.remove(t.id) }
        do {
            try await work()
        } catch APIError.offline(_) {
            show("要連上網路才能告訴平台（外送平台的單有時限）", tone: .danger)
        } catch let e as APIError {
            show(e.userMessage, tone: .danger)
        } catch {
            show(error.localizedDescription, tone: .danger)
        }
    }

    /// 店家層級的動作（忙碌、暫停）：後台回各平台的新狀態；示範模式直接改
    private func deliveryStoreAction(_ action: DeliveryAction, only: DeliveryPlatform? = nil, demo: (inout DeliveryPlatformState) -> Void) async {
        touch()
        if isDemo || api == nil {
            guard var c = deliveryConfig else { return }
            for i in c.platforms.indices where only == nil || c.platforms[i].platform == only { demo(&c.platforms[i]) }
            deliveryConfig = c
            return
        }
        do {
            let r = try await api!.delivery(action)
            if let p = r.platforms { deliveryConfig = DeliveryConfig(platforms: p) }
        } catch {
            show((error as? APIError)?.userMessage ?? error.localizedDescription, tone: .danger)
        }
    }
}
