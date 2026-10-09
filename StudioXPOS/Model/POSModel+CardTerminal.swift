import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 跟刷卡機做完一筆
enum TerminalFinish {
    case approved(ECRResult, recovered: Bool)
    /// 店員選了「手動記一筆」／「只改 POS」
    case bypassed
    /// 取消不行，改用退貨
    case alternate
    case cancelled
}

/// 退款、退回付款要不要經刷卡機
enum TerminalReversal {
    /// 不是刷卡機收的
    case notNeeded
    /// 刷卡機退好了（nil：店員選「只改 POS」）
    case done(CardTerminalRef?)
    case cancelled
}

/// 刷卡機（銀行 EDC 的收銀機連線）：結帳時金額送到刷卡機、客人在刷卡機上刷卡／感應／給付款碼，核准了自動記一筆；
/// 刷卡機收的款，退回、退款也在刷卡機上做（當天整筆＝取消，其他＝退貨）。
/// 等不到結果一定先查上一筆，不會自動重送（不重複扣款）。設定在「設定 → 刷卡機」（Services/CardTerminal.swift）
extension POSModel {
    // MARK: 用不用刷卡機

    /// 這種付款方式這台要不要經刷卡機（沒打開、手機、沒設定 IP：照舊手動輸入）
    func usesTerminal(for tender: Tender) -> Bool {
        guard !isPhone, cardTerminal.isReady(demo: isDemo) else { return false }
        return cardTerminal.covers(tender, demo: isDemo)
    }

    /// 這台已經記過的刷卡機交易（同一台、同一批、同一個調閱編號）：查上一筆時認得出來，不會記兩次
    var knownTerminalKeys: Set<String> {
        var keys = Set<String>()
        for t in state.tickets.values {
            for p in t.payments { if let k = p.terminal?.key { keys.insert(k) } }
            for r in t.refunds { if let k = r.terminal?.key { keys.insert(k) } }
        }
        for s in state.sales.values {
            for p in s.payments { if let k = p.terminal?.key { keys.insert(k) } }
        }
        return keys
    }

    // MARK: 收款

    /// 刷卡、電子票證、電子錢包經刷卡機收：核准了記一筆（授權碼＋調閱編號、末四碼、端末、批次）
    func chargeOnTerminal(_ t: Ticket, tender: Tender, amount: Money) async {
        guard let me = currentStaff else { return }
        guard cardTerminal.session == nil else {
            show("刷卡機還在處理上一筆", tone: .warning)
            return
        }
        let kind = CardTerminalHub.kind(for: tender)
        let session = TerminalSession(purpose: .charge(kind), title: Self.terminalTitle(for: tender), amount: amount)
        cardTerminal.session = session
        let op = ECROperation.sale(amount, kind: kind, installments: nil)
        switch await runTerminal(op, session: session, bypass: "刷卡機上有成功：手動記一筆", bypassAlways: false) {
        case .approved(let r, let recovered):
            let p = Payment(id: newID(), tender: Self.tender(for: r, chosen: tender), amount: r.amount ?? amount, reference: r.reference,
                            cardLast4: r.last4, at: Date(), by: me.id, shiftId: openShift?.id,
                            terminal: r.terminalRef(format: cardTerminal.config.format))
            // 刷卡機已經扣款了：一定要記（這張單在別台先結了也照記，交給店長退）
            guard record(.paymentAdded(PaymentAdded(ticketId: t.id, payment: p))) else {
                cardTerminal.end(session)
                alert = AlertInfo(title: "刷卡機收了，但這台存不進去",
                                  message: "\(p.amount.formatted)・\(r.reference)\n請記下來，重新開機後在這張單手動記一筆（不要再刷一次）。")
                return
            }
            lastChange = .zero
            await cardTerminal.end(session, after: .milliseconds(recovered ? 1_400 : 900))
            if recovered { show("刷卡機上已經成功了，這筆照收（\(r.reference)）", tone: .info) }
            if let fresh = state.tickets[t.id], fresh.isOpen, fresh.totals.isPaidInFull { await complete(fresh) }
        case .bypassed:
            cardTerminal.end(session)
            await recordManual(tender, amount: amount, for: t)
        case .alternate, .cancelled:
            cardTerminal.end(session)
        }
    }

    // MARK: 退回、退款

    /// 刷卡機收的款要退：當天、整筆＝取消（30，客人不用再刷）；其他＝退貨（02，客人要再刷原卡）。
    /// 取消不行（刷卡機已經結帳換批）可以改退貨。刷卡機退好了才在 POS 記
    func reverseOnTerminal(_ p: Payment, amount: Money, wholePayment: Bool) async -> TerminalReversal {
        guard let ref = p.terminal, let receipt = ref.receiptNo, !receipt.isEmpty else { return .notNeeded }
        guard !isPhone else {
            show("這筆是刷卡機收的：請在 iPad 上退", tone: .warning)
            return .cancelled
        }
        guard cardTerminal.session == nil else {
            show("刷卡機還在處理上一筆", tone: .warning)
            return .cancelled
        }
        let kind = ref.kind.flatMap(ECRPaymentKind.init(rawValue:)) ?? .card
        let sameDay = TaipeiTime.businessDate(p.at, cutoffHour: store.businessDayCutoffHour) == businessDate
        var useVoid = sameDay && wholePayment
        while true {
            let op: ECROperation = useVoid ? .void(ref, amount: p.amount) : .refund(amount, kind: kind, original: ref)
            let session = TerminalSession(purpose: useVoid ? .void : .refund(kind), title: useVoid ? "取消刷卡交易" : "刷卡機退貨",
                                          amount: useVoid ? p.amount : amount)
            cardTerminal.session = session
            let finish = await runTerminal(op, session: session, bypass: "刷卡機上已經退了：只改 POS", bypassAlways: true,
                                           alternate: useVoid ? "改用退貨（客人要再刷卡）" : nil)
            switch finish {
            case .approved(let r, _):
                await cardTerminal.end(session, after: .milliseconds(900))
                return .done(r.terminalRef(format: cardTerminal.config.format))
            case .bypassed:
                cardTerminal.end(session)
                return .done(nil)
            case .alternate:
                cardTerminal.end(session)
                useVoid = false
            case .cancelled:
                cardTerminal.end(session)
                return .cancelled
            }
        }
    }

    /// 這張單這種付款方式經刷卡機收的那一筆（退款從它退）：金額剛好的優先，其次夠退的
    func terminalSource(in sale: SaleRecord, tender: Tender, amount: Money) -> (payment: Payment?, viaTerminal: [Payment]) {
        let list = sale.payments.filter { $0.status == .approved && $0.tender == tender && $0.terminal?.receiptNo != nil }
        let exact = list.first { $0.amount == amount }
        let enough = list.filter { $0.amount >= amount }.max { $0.amount < $1.amount }
        return (exact ?? enough, list)
    }

    // MARK: 跟刷卡機做一筆（含問店員）

    /// 做一筆，沒成功就停下來問店員：沒有扣款的可以再試；不確定的只能再查（不重送），或照刷卡機的簽單手動處理
    func runTerminal(_ op: ECROperation, session: TerminalSession, bypass: String?, bypassAlways: Bool,
                     alternate: String? = nil) async -> TerminalFinish {
        if isDemo { session.onCancel = { [weak self] in self?.cardTerminal.cancelDemo() } }
        var outcome = await cardTerminal.perform(op, known: knownTerminalKeys, watch: session.watch, demo: isDemo)
        while true {
            if case .approved(let r, let recovered) = outcome {
                session.phase = .approved(Self.approvedLine(r, op: op, recovered: recovered))
                return .approved(r, recovered: recovered)
            }
            // 按了取消、刷卡機也確定沒做：直接關掉
            if session.watch.isCancelRequested, outcome.isSettledNo {
                show(op.isCharge ? "已取消，沒有扣款" : "已取消", tone: .neutral)
                return .cancelled
            }
            let prompt = Self.terminalPrompt(outcome, op: op, bypass: bypass, bypassAlways: bypassAlways, alternate: alternate)
            switch await session.ask(prompt.phase, buttons: prompt.buttons) {
            case .retry:
                session.renewWatch()
                outcome = await cardTerminal.perform(op, known: knownTerminalKeys, watch: session.watch, demo: isDemo)
            case .recheck:
                session.phase = .checking
                outcome = await cardTerminal.verify(op, known: knownTerminalKeys, demo: isDemo)
            case .bypass:
                return .bypassed
            case .alternate:
                return .alternate
            case .close:
                return .cancelled
            }
        }
    }

    /// 沒成功時那張卡上寫什麼、有哪些按鈕
    static func terminalPrompt(_ outcome: ECROutcome, op: ECROperation, bypass: String?, bypassAlways: Bool,
                               alternate: String?) -> (phase: TerminalSession.Phase, buttons: [TerminalButton]) {
        let noun = op.noun
        var buttons: [TerminalButton] = []
        let phase: TerminalSession.Phase
        var unsure = false
        switch outcome {
        case .approved(let r, _):
            phase = .approved(r.message)
        case .declined(let r):
            phase = .failed("沒有成功", "\(r.message)。沒有\(noun)。")
            buttons.append(TerminalButton(choice: .retry, title: "再試一次", prominent: true))
        case .notCharged(let e):
            let why = e == .notOnTerminal ? "刷卡機上沒有這一筆" : e.message
            phase = .failed("沒有成功", "\(why)。沒有\(noun)。")
            buttons.append(TerminalButton(choice: .retry, title: "再試一次", prominent: true))
        case .unknown(let e):
            unsure = true
            let hint = bypass.map { "有成功就按「\($0)」；沒有就關掉。" } ?? "沒有成功就關掉。"
            phase = .unknown("不確定有沒有\(noun)", "\(e.message)。請看刷卡機的畫面或簽單：\(hint)")
            buttons.append(TerminalButton(choice: .recheck, title: "再查一次", prominent: true))
        }
        if let alternate, !unsure { buttons.append(TerminalButton(choice: .alternate, title: alternate)) }
        if let bypass, unsure || bypassAlways { buttons.append(TerminalButton(choice: .bypass, title: bypass)) }
        buttons.append(TerminalButton(choice: .close, title: unsure ? "沒有成功，關掉" : "關掉"))
        return (phase, buttons)
    }

    /// 「已收款・Visa ****1234」「已取消刷卡交易」「已退款」
    static func approvedLine(_ r: ECRResult, op: ECROperation, recovered: Bool) -> String {
        let card = [r.brand?.label, r.last4.map { "****\($0)" }].compactMap { $0 }.joined(separator: " ")
        let head: String
        switch op {
        case .sale: head = card.isEmpty ? "已收款" : "已收款・\(card)"
        case .refund: head = "已退款"
        case .void: head = "已取消刷卡交易"
        }
        return recovered ? "\(head)（查上一筆確認的）" : head
    }

    static func terminalTitle(for tender: Tender) -> String {
        switch tender {
        case .card: "刷卡"
        case .stored: "電子票證"
        default: "\(tender.label)（刷卡機）"
        }
    }

    /// 刷卡機回的卡別／錢包 → 付款方式（客人實際用的：選了 LINE Pay、客人給全支付的碼，記全支付）
    static func tender(for r: ECRResult, chosen: Tender) -> Tender {
        guard let brand = r.brand else { return chosen }
        switch brand {
        case .linePay: return .linePay
        case .easyWallet: return .easyWallet
        case .pxPay: return .pxPay
        case .icashPay, .plusPay, .piWallet: return .other
        case .easyCard, .iPass, .iCash: return .stored
        case .uCard, .visa, .mastercard, .jcb, .amex, .unionPay, .diners, .smartPay: return .card
        }
    }

    // MARK: 設定頁

    func testCardTerminal() async {
        await cardTerminal.test(demo: isDemo)
        if let h = cardTerminal.health { show(h.ok ? "刷卡機連線正常" : h.message, tone: h.ok ? .active : .danger) }
    }

    func checkLastTerminalTransaction() async {
        await cardTerminal.checkLast(demo: isDemo)
    }

    /// 刷卡機結帳（日結）：交班時順便做；要能交班的人
    func settleCardTerminal() async {
        guard await authorize(.closeShift, detail: "刷卡機結帳") != nil else { return }
        let ok = await cardTerminal.settle(demo: isDemo)
        show(cardTerminal.lastSummary ?? (ok ? "刷卡機結帳完成" : "刷卡機結帳沒有成功"), tone: ok ? .active : .danger)
    }
}

extension ECROutcome {
    /// 確定沒做（刷卡機回了不核准，或查上一筆沒有這一筆）
    var isSettledNo: Bool {
        switch self {
        case .declined, .notCharged: true
        case .approved, .unknown: false
        }
    }
}

extension ECROperation {
    var isCharge: Bool {
        if case .sale = self { return true }
        return false
    }

    /// 「扣款」「退款」「取消」
    var noun: String {
        switch self {
        case .sale: "扣款"
        case .refund: "退款"
        case .void: "取消"
        }
    }
}
