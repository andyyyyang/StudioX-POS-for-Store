import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 掃碼付怎麼結束（掃碼 → 送出 → 結果）
enum WalletEnd {
    /// 完成（收到了、沒扣款關掉、先關掉之後再查）
    case done
    /// 沒有扣款，再掃一次（新的付款 id）
    case again
}

/// 退款、退回付款要不要退回錢包
enum WalletReversal {
    /// 不是掃碼付收的
    case notNeeded
    /// 錢包退了（或 StudioX Pay 記下了、等錢包業者處理：note 說一聲）。refundId：送給後台的退款 id（記在 POS 的退款上，對得起來）
    case done(note: String?, refundId: String)
    case cancelled
}

/// 門市掃碼付（docs/API.md「掃碼付」）：結帳選 LINE Pay、街口…（後台開了掃碼付的錢包）→ 打金額 → 掃客人手機上的付款碼
/// （相機，或條碼機打進框裡）→ 後台經 StudioX Pay 收 → 成功記一筆（reference＝錢包的交易序號、intentId）。
///
/// 不重複扣款：
///   - 先把這一筆（付款 id）存在這台才送；後台用付款 id 冪等，斷線重送同一個請求拿到同一個結果
///   - 不知道結果（沒網路、逾時、後台出錯）不能當失敗：卡上自動再問；卡關掉了（或 App 重開）背景用「只查」問，不會再送付款碼
///   - 同一張單還有不知道結果的那一筆：先查清楚才能再收電子支付
///   - 斷線時不收（錢包的結果拿不到）
extension POSModel {
    // MARK: 用不用掃碼付

    /// 這種付款方式要不要掃客人的付款碼（後台開了這個錢包的掃碼付；這台接了刷卡機收錢包的照刷卡機）
    func scansWallet(_ tender: Tender) -> Bool {
        guard takesPayment, let c = walletScanConfig, c.tenders.contains(tender) else { return false }
        return !usesTerminal(for: tender)
    }

    /// 斷線了（掃碼付一定要連線；示範店不用）
    var walletOffline: Bool {
        guard !isDemo else { return false }
        return api == nil || syncStatus.health == .offline
    }

    static let walletOfflineMessage = "斷線時不能收電子支付"

    /// 處理中多久查一次
    private var walletPollSeconds: Double { Double(walletScanConfig?.pollMs ?? 3000) / 1000 }

    /// 錢包最多等幾分鐘（後台沒給 pollUntil 時用）
    private var walletWindow: TimeInterval { TimeInterval((walletScanConfig?.windowMinutes ?? 20) * 60) }

    // MARK: 收款

    /// 結帳選了掃碼付的錢包、打好金額：打開那張卡、掃客人的付款碼
    func payByWalletScan(_ t: Ticket, tender: Tender, amount: Money) async {
        guard walletPay.session == nil else {
            show("還有一筆電子支付在處理", tone: .warning)
            return
        }
        guard let method = WalletMethod.code(for: tender) else { return }
        let s = WalletPaySession(ticketId: t.id, ticketNumber: t.number, tender: tender, amount: amount)
        walletPay.session = s
        await runWallet(s, method: method, resume: nil)
        walletPay.end(s)
    }

    /// 送出去還不知道結果的那一筆：打開卡、先查清楚（App 重開、斷線、先關掉之後）
    func resumeWalletPending(_ p: WalletPending) async {
        guard walletPay.session == nil else {
            show("還有一筆電子支付在處理", tone: .warning)
            return
        }
        let s = WalletPaySession(ticketId: p.ticketId, ticketNumber: p.ticketNumber, tender: p.tender, amount: p.amount)
        walletPay.session = s
        await runWallet(s, method: p.method, resume: p)
        walletPay.end(s)
    }

    /// 卡被關掉（鎖定、離開結帳畫面）：流程停下來；還不知道結果的留著，背景查。只關這一張（下一筆已經開始的不動）
    func walletSheetClosed(_ s: WalletPaySession) {
        guard walletPay.session === s else { return }
        s.abort()
        walletPay.end(s)
    }

    private func runWallet(_ s: WalletPaySession, method: String, resume: WalletPending?) async {
        var current = resume
        while !s.aborted {
            var code: String? = nil
            if current == nil {
                guard let raw = await s.waitForCode() else { return }
                guard let c = WalletMethod.normalize(raw) else {
                    s.scanHint = "這不是付款碼：請客人打開\(s.tender.label)的付款碼（掃到 \(Self.excerpt(raw))）"
                    continue
                }
                guard let me = currentStaff, let t = state.tickets[s.ticketId], t.isOpen else {
                    _ = await s.ask(.failed("這張單已經結帳了", "沒有扣款"), buttons: [WalletButton(choice: .close, title: "關掉")])
                    return
                }
                guard s.amount <= t.totals.balance else {
                    _ = await s.ask(.failed("金額比還欠的多", "這張單只剩 \(t.totals.balance.formatted)，沒有扣款"), buttons: [WalletButton(choice: .close, title: "關掉")])
                    return
                }
                guard !walletOffline else {
                    s.scanHint = Self.walletOfflineMessage
                    continue
                }
                // 先存在這台才送：App 當掉、斷線之後照這一筆查（付款碼不存）
                let p = WalletPending(paymentId: newID(), ticketId: t.id, ticketNumber: t.number, tender: s.tender, method: method, amount: s.amount,
                                      intentId: nil, staffId: me.id, shiftId: openShift?.id, startedAt: Date(), pollUntil: nil)
                walletPay.upsert(p)
                current = p
                code = c
                s.scanHint = nil
                s.show(.charging)
            } else {
                s.show(.checking)
            }
            guard let p = current else { return }
            s.paymentId = p.paymentId
            switch await settleWallet(s, p, code: code) {
            case .done: return
            case .again: current = nil
            }
        }
    }

    /// 送出／查詢，直到有確定的結果、或店員先關掉（還不知道的留著背景查）
    private func settleWallet(_ s: WalletPaySession, _ start: WalletPending, code: String?) async -> WalletEnd {
        var p = start
        var wait = walletPollSeconds
        s.cancelRefused = false
        while !s.aborted {
            var result: WalletPayResult?
            do {
                result = try await walletQuery(p, code: code)
                s.note = nil
            } catch let e as APIError where !e.isUncertain && p.intentId == nil && code != nil {
                // 掃碼的請求被後台擋下來（沒開這個錢包、這台不收錢、沒開通…）：還沒送到錢包，確定沒有扣款
                walletPay.remove(p.paymentId)
                return await walletFailed(s, detail: e.userMessage)
            } catch {
                result = nil
            }

            if let r = result {
                if let id = r.intentId, p.intentId != id {
                    p.intentId = id
                    walletPay.upsert(p)
                }
                switch r.status {
                case .succeeded:
                    return await walletSucceeded(s, p, r)
                case .failed:
                    walletPay.remove(p.paymentId)
                    if r.isConflicted {
                        _ = await s.ask(.unknown("扣款金額不對", r.message ?? "錢包扣的金額和這筆不一樣：請店長到 StudioX 後台處理，不要再收一次"),
                                        buttons: [WalletButton(choice: .close, title: "關掉")])
                        return .done
                    }
                    return await walletFailed(s, detail: r.message ?? "付款沒有成功")
                case .processing:
                    if let until = r.pollUntil, p.pollUntil != until {
                        p.pollUntil = until
                        walletPay.upsert(p)
                    }
                    wait = min(max(Double(r.pollAfterMs ?? Int(walletPollSeconds * 1000)) / 1000, 1), 10)
                    let deadline = (p.pollUntil ?? p.startedAt.addingTimeInterval(walletWindow)).addingTimeInterval(60)
                    if Date() > deadline {
                        // 錢包 20 分鐘還不知道：後台下一次查會當失敗；先讓店員決定要不要等
                        s.show(.unknown("還不知道有沒有扣款", "錢包等了 \(walletScanConfig?.windowMinutes ?? 20) 分鐘還沒有結果。請客人看錢包有沒有扣款：有扣款這筆會自動記上，不要再收一次"),
                               buttons: [WalletButton(choice: .recheck, title: "再查一次", prominent: true), WalletButton(choice: .later, title: "先關掉，之後再查")])
                    } else {
                        s.show(.waiting(r.message ?? "等客人在手機上確認"),
                               buttons: s.cancelRefused ? [WalletButton(choice: .later, title: "先關掉，之後再查")] : [WalletButton(choice: .cancel, title: "取消")])
                    }
                }
            } else {
                s.show(.unknown("還不知道有沒有扣款", "連線不穩：連上之後自動再確認（同一筆，不會重複扣款）"),
                       buttons: [WalletButton(choice: .recheck, title: "再查一次", prominent: true), WalletButton(choice: .later, title: "先關掉，之後再查")])
            }

            // 等一下再問；按了按鈕就提早醒來
            await s.pause(wait)
            switch s.takePressed() {
            case .later, .close:
                // 先關掉：這一筆留在這台，背景繼續只查（收到了自動記上）
                show("\(p.tender.label) \(p.amount.formatted) 還不知道結果：這台會繼續查，結帳畫面上面可以再查", tone: .warning)
                return .done
            case .cancel:
                if let end = await cancelWallet(s, &p) { return end }
            case .recheck, .retry, nil:
                break
            }
        }
        return .done
    }

    /// 問一次：還沒拿到 intentId 時，卡上（客人還在、2 分鐘內）用同一個付款碼重送；其他時候只查，不再送付款碼
    private func walletQuery(_ p: WalletPending, code: String?) async throws -> WalletPayResult {
        guard let api else { throw APIError.offline("沒有連上後台") }
        if let id = p.intentId { return try await api.walletIntent(id: id) }
        let fresh = Date().timeIntervalSince(p.startedAt) < 120
        return try await api.walletScan(p.request(code: fresh ? code : nil))
    }

    /// 按了取消：錢包還沒收的取消掉；正在處理的取消不了（繼續等，卡上多一個「先關掉，之後再查」）。nil＝繼續等
    private func cancelWallet(_ s: WalletPaySession, _ p: inout WalletPending) async -> WalletEnd? {
        guard let id = p.intentId, let api else {
            s.note = "還沒有收到錢包的回覆，等一下再按取消"
            return nil
        }
        s.show(.cancelling)
        do {
            let r = try await api.cancelWalletIntent(id: id)
            switch r.status {
            case .failed:
                walletPay.remove(p.paymentId)
                show("已取消，沒有扣款", tone: .neutral)
                return .done
            case .succeeded:
                // 客人剛好付了：照收（要退照退款走）
                return await walletSucceeded(s, p, r)
            case .processing:
                s.cancelRefused = true
                s.note = r.message ?? "錢包正在處理，現在不能取消：等結果出來（扣了款可以退款）"
                return nil
            }
        } catch {
            s.note = "取消沒有送到，繼續等結果"
            return nil
        }
    }

    private func walletFailed(_ s: WalletPaySession, detail: String) async -> WalletEnd {
        var buttons = [WalletButton(choice: .close, title: "關掉")]
        if let t = state.tickets[s.ticketId], t.isOpen, s.amount <= t.totals.balance {
            buttons.insert(WalletButton(choice: .retry, title: "再掃一次", prominent: true), at: 0)
        }
        return await s.ask(.failed("沒有扣款", detail), buttons: buttons) == .retry ? .again : .done
    }

    private func walletSucceeded(_ s: WalletPaySession, _ p: WalletPending, _ r: WalletPayResult) async -> WalletEnd {
        let recorded = recordWalletPayment(p, r)
        walletPay.remove(p.paymentId)
        let ref = r.pspTransactionId.map { "・交易序號 \(Self.tail($0))" } ?? ""
        s.show(.approved("已收款・\(p.tender.label)\(ref)"))
        lastChange = .zero
        try? await Task.sleep(for: .milliseconds(900))
        walletPay.end(s)
        if recorded, let fresh = state.tickets[p.ticketId], fresh.isOpen, fresh.totals.isPaidInFull { await complete(fresh) }
        return .done
    }

    /// 錢包收到了：記一筆（同一個付款 id 只記一次）。這張單已經結帳了（店員先收了別的）：跳出來請店長退
    @discardableResult
    func recordWalletPayment(_ p: WalletPending, _ r: WalletPayResult) -> Bool {
        let ref = r.pspTransactionId ?? r.intentId ?? p.paymentId
        guard let t = state.tickets[p.ticketId] else {
            alert = AlertInfo(title: "\(p.tender.label) 收到了，找不到這張單", message: "\(p.ticketNumber)・\(p.amount.formatted)・交易序號 \(ref)\n請到 StudioX 後台查這筆，退給客人或補記。")
            return false
        }
        if t.payments.contains(where: { $0.id == p.paymentId }) { return true }
        guard t.isOpen else {
            alert = AlertInfo(title: "\(p.tender.label) 收到了，但這張單已經結帳",
                              message: "\(t.number)・\(p.amount.formatted)・交易序號 \(ref)\n客人多付了這一筆：請店長到 StudioX 後台退給客人。")
            return false
        }
        let payment = Payment(id: p.paymentId, tender: p.tender, amount: p.amount, reference: r.pspTransactionId, at: Date(), by: p.staffId,
                              shiftId: p.shiftId, intentId: r.intentId ?? p.intentId)
        // 錢包已經扣款了：一定要記（記不進去就請店員記下來，不要再收一次）
        guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: payment))) else {
            alert = AlertInfo(title: "\(p.tender.label) 收了，但這台存不進去", message: "\(p.amount.formatted)・交易序號 \(ref)\n請記下來，重新開機後在這張單手動記一筆（不要再收一次）。")
            return false
        }
        return true
    }

    // MARK: 背景查（App 重開、卡先關掉了）

    /// 送出去還不知道結果的：只查（不會再扣款）。收到了自動記上；沒扣款的拿掉
    func walletBackgroundTick() async {
        guard phase == .ready, api != nil, !walletPay.checking else { return }
        let skip = walletPay.session?.paymentId
        let list = walletPay.pending.filter { $0.paymentId != skip }
        guard !list.isEmpty else { return }
        walletPay.checking = true
        defer { walletPay.checking = false }
        for var p in list {
            guard let r = try? await walletQuery(p, code: nil) else { continue }
            // 這段時間店員可能在卡上查好了
            guard walletPay.pending.contains(where: { $0.paymentId == p.paymentId }), walletPay.session?.paymentId != p.paymentId else { continue }
            switch r.status {
            case .succeeded:
                if recordWalletPayment(p, r) {
                    show("\(p.tender.label) \(p.amount.formatted) 收到了，已經記在 \(p.ticketNumber)")
                }
                walletPay.remove(p.paymentId)
            case .failed:
                walletPay.remove(p.paymentId)
                if r.isConflicted {
                    alert = AlertInfo(title: "\(p.tender.label) 扣款金額不對", message: "\(p.ticketNumber)・\(p.amount.formatted)\n\(r.message ?? "請店長到 StudioX 後台處理，不要再收一次")")
                }
            case .processing:
                if let id = r.intentId, p.intentId != id { p.intentId = id }
                if let until = r.pollUntil { p.pollUntil = until }
                walletPay.upsert(p)
            }
        }
    }

    // MARK: 退款

    /// 這張單這種付款方式掃碼付收的那一筆（退款從它退）：金額剛好的優先，其次夠退的
    func walletSource(in sale: SaleRecord, tender: Tender, amount: Money) -> (payment: Payment?, viaWallet: [Payment]) {
        let list = sale.payments.filter { $0.status == .approved && $0.tender == tender && $0.intentId != nil }
        let exact = list.first { $0.amount == amount }
        let enough = list.filter { $0.amount >= amount }.max { $0.amount < $1.amount }
        return (exact ?? enough, list)
    }

    /// 掃碼付收的款退回客人的錢包（StudioX Pay）；退好了才在 POS 記。
    /// 超過店家設定的金額要店長：右側鍵盤打店長的 PIN（後台驗）。不知道退了沒有：同一筆的退款 id 留著，再按一次不會退兩次
    func refundOnWallet(_ p: Payment, amount: Money, reason: String) async -> WalletReversal {
        guard let intentId = p.intentId else { return .notNeeded }
        guard let api, !walletOffline else {
            show("斷線時不能退電子支付：連上網路再退", tone: .warning)
            return .cancelled
        }
        let key = "\(intentId):\(amount.cents)"
        let refundId = walletPay.refundIds[key] ?? newID()
        walletPay.refundIds[key] = refundId
        let staffId = currentStaff?.id
        func send(_ pin: String?) async throws -> WalletRefundResult {
            try await api.walletRefund(WalletRefundRequest(intentId: intentId, amount: amount, refundId: refundId, reason: reason, managerPin: pin, staffId: staffId))
        }
        var result: WalletRefundResult?
        var failure: Error?
        do {
            result = try await send(nil)
        } catch let e as APIError where e.needsManagerApproval {
            // 店長在右側鍵盤打 PIN：後台驗、驗過就退（PIN 不對留在鍵盤上再打）
            var approved: WalletRefundResult?
            var spec = KeypadSpec.pin(title: "店長核准", subtitle: e.userMessage)
            spec.confirmLabel = "核准"
            let entry = await keypad.ask(spec, clearsOnError: true, check: { entry in
                do {
                    approved = try await send(entry.digits)
                    return nil
                } catch let x as APIError where x.isWrongPin {
                    return x.userMessage
                } catch let x as APIError {
                    if case .http(429, _, let m) = x { return m ?? APIError.pinRateLimitedMessage }
                    failure = x
                    return nil
                } catch {
                    failure = error
                    return nil
                }
            })
            guard entry != nil else { return .cancelled }
            result = approved
        } catch {
            failure = error
        }
        if let failure {
            if let e = failure as? APIError, e.isUncertain {
                alert = AlertInfo(title: "不知道錢包有沒有退", message: "\(e.userMessage)\n再按一次退款會用同一筆（不會退兩次）。")
            } else {
                walletPay.refundIds[key] = nil
                show((failure as? APIError)?.userMessage ?? failure.localizedDescription, tone: .danger)
            }
            return .cancelled
        }
        guard let r = result else { return .cancelled }
        walletPay.refundIds[key] = nil
        switch r.status {
        case .failed:
            alert = AlertInfo(title: "錢包沒有退成功", message: r.message ?? "請稍後再試，或到 StudioX 後台處理")
            return .cancelled
        case .succeeded:
            return .done(note: nil, refundId: refundId)
        case .pending:
            return .done(note: "錢包退款處理中", refundId: refundId)
        case .requiresManualAction:
            return .done(note: r.message ?? "要到錢包業者的後台退款", refundId: refundId)
        }
    }

    /// 交易序號太長：留最後 8 碼（對帳看得出來）
    static func tail(_ s: String) -> String {
        s.count > 12 ? "…" + String(s.suffix(8)) : s
    }
}
