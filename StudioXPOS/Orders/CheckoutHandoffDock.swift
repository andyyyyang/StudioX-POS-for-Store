import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

extension View {
    /// 結帳櫃台：別台（前場的手機、報到接待）送來結帳的單，在右欄等著——大鍵「去結帳」、× 先放著。
    /// 正在結帳、選了別的單、鍵盤在問數字、這一頁自己選了東西時不出來（只有上方的提示與側欄的數字）
    func checkoutHandoffDock(enabled: Bool = true) -> some View {
        modifier(CheckoutHandoffDock(enabled: enabled))
    }
}

/// 送來結帳的單（POSModel+Handoff）交給右欄：和其他「選起來的一筆」一樣，裡面的（這一頁自己選的）優先
private struct CheckoutHandoffDock: ViewModifier {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let enabled: Bool

    func body(content: Content) -> some View {
        content.dockSelection(selection)
    }

    private var selection: DockSelection? {
        guard enabled, model.checkoutTicketId == nil, model.selectedTicketId == nil, !keypad.isAsking else { return nil }
        let waiting = model.incomingHandoffs
        guard let t = waiting.first else { return nil }
        let model = model
        // 外帶叫號的店不寫單號（客人只認取餐號碼）：改寫開單的時間，好幾張一起送來也分得出來
        var detail = [model.orderNumber(t) ?? TaipeiTime.clock(t.openedAt), "\(t.itemCount) 項", t.totals.amountDue.formatted]
        if let who = model.staffMember(t.openedBy) { detail.append(who.name) }
        if let at = t.billPrintedAt { detail.append("\(TaipeiTime.clock(at)) 送來") }
        let badge = waiting.count > 1 ? DockBadge("還有 \(waiting.count - 1) 張", tone: .warning) : DockBadge("待結帳", tone: .warning)
        return DockSelection(
            id: "handoff-\(t.id)",
            kind: "從\(t.billSentFrom ?? "其他裝置")送來結帳",
            title: model.orderTitle(t),
            detail: detail.joined(separator: "・"),
            badge: badge,
            // 送來「付現」的：大鍵直接收現金（打收了多少、找零自動算）；其他的進結帳畫面選付款方式
            primary: POSModel.wantsCash(t)
                ? POSAction("收現金 \(t.totals.balance.formatted)", icon: "banknotes", enabled: model.takesPayment && model.role.hasDrawer) {
                    model.beginCheckout(t)
                    Task {
                        if let fresh = model.state.tickets[t.id] { await model.takeCash(fresh) }
                    }
                }
                : POSAction("去結帳", icon: "credit-card", enabled: model.takesPayment) { model.beginCheckout(t) },
            accent: true,
            actions: [
                POSAction("看單", icon: "eye") {
                    model.selectedTicketId = t.id
                    model.go(.order)
                },
            ],
            // ×＝先放著（這次開著的時候不再跳；同一張單再送一次會再出來）
            clear: { HandoffInbox.shared.dismiss(t) }
        )
    }
}
