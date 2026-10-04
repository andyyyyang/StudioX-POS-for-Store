import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 要店員確認的一件事（套折價券會換掉原本的整單折扣）。
/// 平常是右欄（手機是下面）蓋上來的面板，兩個選擇；相機開著時是相機上的一張卡（Components/ScanSheets.swift）
struct ConfirmRequest: Identifiable {
    let id = UUID()
    /// 「換成折價券？」
    var title: String
    /// 「A012 已經有整單 9 折；一張單只能有一個整單折扣」
    var message: String
    /// 「換成折價券 新會員 100 元」
    var confirmLabel: String
    var confirmDetail: String?
    /// 「保留 9 折」
    var keepLabel: String
    var continuation: CheckedContinuation<Bool, Never>?
}

/// 門市折價券（docs/API.md「折價券（門市）」）：和網路商店同一份。
///
///   1. 掃折價券、或在折扣面板「輸入折價券代碼」
///   2. 問後台這張單能不能用（GET /coupons/:code?subtotal=…）：不能用的原因（過期、用完、只能網路用…）直接說；斷線不套用
///   3. 套成整張單的折扣（ticket.updated 的 discount 帶 couponCode）。原本有整單折扣的先問要不要換掉
///   4. 改了品項、小計低於最低消費：單子上提醒；結帳前還是不夠就拿掉（提示說一聲）
///   5. 結帳：sale.couponCode → 後台記一筆使用
extension POSModel {
    // MARK: 套用

    /// 套用折價券（輸入代碼、掃折價券），提示說結果；回傳結果（相機上的小標籤）
    @discardableResult
    func applyCoupon(code: String, to t: Ticket) async -> ScanOutcome {
        let outcome = await couponOutcome(code: code, to: t)
        show(outcome.text, tone: outcome.tone)
        return outcome
    }

    /// 套用折價券（不跳提示：handleScan、applyCoupon 自己說）。guessed：一般的掃碼猜是折價券（查不到時說「不是商品也不是折價券」）
    func couponOutcome(code raw: String, to given: Ticket?, guessed: Bool = false) async -> ScanOutcome {
        guard let code = ScanCode.couponCode(in: raw) else {
            return .failed(.coupon, "折價券代碼是 4–32 個英文、數字（\(Self.excerpt(raw))）")
        }
        guard let given, let t = state.tickets[given.id], t.isOpen else {
            return .failed(.coupon, "折價券 \(code)：先點好東西再套用（要有單）")
        }
        guard t.approvedPayments.isEmpty else {
            return .failed(.coupon, "折價券 \(code)：\(t.number) 已經收了一部分錢，不能再換折扣")
        }
        if let d = t.discount, d.couponCode == code {
            return .done(.coupon, "\(d.reason) 已經套用在 \(t.number)", tally: "折價券 \(code)")
        }
        guard let api else { return .failed(.coupon, "折價券要連線才能確認（\(code) 沒有套用）") }
        let lookup: CouponLookup?
        do {
            lookup = try await api.coupon(code: code, subtotal: t.totals.subtotal, memberId: t.member?.id)
        } catch let e as APIError {
            if case .offline = e { return .failed(.coupon, "折價券要連線才能確認（\(code) 沒有套用）") }
            return .failed(.coupon, "折價券 \(code)：\(e.userMessage)", tone: .danger)
        } catch {
            return .failed(.coupon, "折價券要連線才能確認（\(code) 沒有套用）")
        }
        guard let lookup else {
            return .failed(.coupon, guessed ? "找不到 \(code)：菜單上沒有這個條碼，也不是折價券" : "找不到折價券 \(code)", tone: .danger)
        }
        let coupon = lookup.coupon
        if let problem = lookup.problem {
            return .failed(.coupon, "折價券 \(coupon.displayName)：\(problem)", tone: .danger)
        }
        guard let discount = coupon.discount else {
            return .failed(.coupon, "折價券 \(coupon.displayName)：不能在門市用", tone: .danger)
        }
        return await applyCouponDiscount(discount, coupon: coupon, to: t.id)
    }

    /// 記成整張單的折扣；原本有別的整單折扣時先問要不要換掉（問的時候單子可能被別台改了：問完重新看一次）
    private func applyCouponDiscount(_ discount: Discount, coupon: Coupon, to ticketId: String) async -> ScanOutcome {
        guard let before = state.tickets[ticketId], before.isOpen else {
            return .failed(.coupon, "這張單已經結帳或作廢了，\(coupon.reason) 沒有套用")
        }
        if let old = before.discount, old.couponCode != discount.couponCode {
            let oldText = Self.describe(old)
            let off = discount.amount(on: before.totals.subtotal)
            let yes = await confirm(
                title: "換成折價券？",
                message: "\(before.number) 已經有\(oldText)。一張單只能有一個整單折扣：套用折價券會換掉它",
                confirmLabel: "換成\(coupon.reason)",
                confirmDetail: "−\(off.formatted)",
                keepLabel: "保留\(oldText)"
            )
            guard yes else {
                return .failed(.coupon, "沒有套用\(coupon.reason)：保留原本的\(oldText)", tone: .neutral)
            }
        }
        guard let t = state.tickets[ticketId], t.isOpen, t.approvedPayments.isEmpty else {
            return .failed(.coupon, "這張單已經結帳或收了錢，\(coupon.reason) 沒有套用")
        }
        guard record(.ticketUpdated(TicketUpdated(ticketId: ticketId, discount: discount))) else {
            return .failed(.coupon, "\(coupon.reason) 沒有記下來，請再試一次", tone: .danger)
        }
        let fresh = state.tickets[ticketId] ?? t
        let off = fresh.totals.orderDiscount
        var text = "\(coupon.reason) −\(off.formatted)"
        // 套上去了，但小計還沒到最低消費（後台查的時候到了、之後被別台改了）：提醒一聲
        if let short = discount.shortfall(subtotal: fresh.totals.subtotal) {
            text += "・還差 \(short.formatted) 才到最低消費"
        }
        return .done(.coupon, text, tally: "折價券 \(coupon.displayName)")
    }

    /// 「整單 9 折」「折價券 新會員 100 元」
    static func describe(_ d: Discount) -> String {
        if d.isCoupon, !d.reason.isEmpty { return d.reason }
        return d.reason.isEmpty ? "整單 \(d.label)" : "整單 \(d.label)（\(d.reason)）"
    }

    // MARK: 最低消費

    /// 折價券還差多少才到最低消費（單子上的提醒：結帳前會拿掉）；沒有折價券、到了都是 nil
    func couponShortfall(_ t: Ticket) -> Money? {
        guard let d = t.discount, d.isCoupon else { return nil }
        return d.shortfall(subtotal: t.totals.subtotal)
    }

    /// 結帳前：折價券還沒到最低消費就拿掉（提示說一聲）。拿掉了回 true
    @discardableResult
    func dropCouponBelowMinimum(_ t: Ticket) -> Bool {
        guard let d = t.discount, d.isCoupon, let short = d.shortfall(subtotal: t.totals.subtotal), let minimum = d.minimumOrder else { return false }
        guard record(.ticketUpdated(TicketUpdated(ticketId: t.id, clearDiscount: true))) else { return false }
        show("\(Self.describe(d)) 拿掉了：未達最低消費 \(minimum.formatted)（還差 \(short.formatted)）", tone: .warning)
        return true
    }

    // MARK: 確認

    /// 問店員要不要（右欄的面板，或相機上的一張卡）。同時只問一件：新的來了，舊的當作「不要」
    func confirm(title: String, message: String, confirmLabel: String, confirmDetail: String? = nil, keepLabel: String) async -> Bool {
        answerConfirm(false)
        return await withCheckedContinuation { c in
            confirmRequest = ConfirmRequest(title: title, message: message, confirmLabel: confirmLabel, confirmDetail: confirmDetail,
                                            keepLabel: keepLabel, continuation: c)
        }
    }

    /// 回答（面板的選擇、×、相機上的按鈕）；沒有在問就不做事
    func answerConfirm(_ yes: Bool) {
        guard let r = confirmRequest else { return }
        confirmRequest = nil
        r.continuation?.resume(returning: yes)
    }
}
