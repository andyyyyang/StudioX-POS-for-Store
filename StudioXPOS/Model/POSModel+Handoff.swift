import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 統一結帳：不收錢的裝置（前場的手機、報到接待）把單「送到結帳櫃台」，客人到櫃台（iPad）一起結。
///
///   送出：記一筆 `bill.printed`（帶 sentFrom：「手機」「報到接待」）——不發明新的事件種類，「待結帳」本來就是這一筆；
///         同一份事件照常走區網（Bonjour）與後台同步，舊版 App 也照樣看成待結帳
///   櫃台：收到別台送來的（POSModel.describeRemote → noteHandoffs）→ 上方提示「A2 從手機送來結帳」；
///         沒在忙的時候右欄出現那張單（大鍵「去結帳」，× 先放著）；側欄「訂單」的數字＝待結帳的單
///   手機：「訂單 → 待結帳」看得到送出去的單，櫃台結完變成「已結帳」（也會提示一下）
extension POSModel {
    /// 送單時寫的「從哪裡來」：手機、或這台的崗位（報到接待）
    var handoffSource: String { isPhone ? "手機" : role.label }

    /// 送到結帳櫃台：單子變成待結帳，櫃台跳出來。手機送出去就換下一桌（單子在「訂單 → 待結帳」）
    func sendToRegister(_ t: Ticket) {
        guard !t.activeLines.isEmpty else {
            show("還沒有點東西", tone: .warning)
            return
        }
        guard record(.billPrinted(TicketRef(ticketId: t.id, sentFrom: handoffSource))) else { return }
        show("\(orderTitle(t)) 送到結帳櫃台了，請客人到櫃台結帳", tone: .info)
        if isPhone, selectedTicketId == t.id { selectedTicketId = nil }
    }

    /// 結帳到一半要付現金、這台又沒有錢櫃（收款的手機、報到接待）：送到結帳櫃台「付現」，客人到櫃台付。
    /// 櫃台跳出「從手機（付現）送來結帳」，大鍵直接是收現金；這台回到點餐（刷卡、電子支付已經收的照樣算）。
    /// cash＝false：要印發票證明聯、這支手機又沒有發票出單機——到櫃台用什麼付都可以（櫃台照一般的結帳）
    func sendToRegisterForCash(_ t: Ticket, cash: Bool = true) {
        guard !t.activeLines.isEmpty else { return }
        let due = t.totals.balance
        let from = cash ? "\(handoffSource)（付現）" : handoffSource
        guard record(.billPrinted(TicketRef(ticketId: t.id, sentFrom: from))) else { return }
        keypad.cancel()
        checkoutTicketId = nil
        if isPhone || selectedTicketId == t.id { selectedTicketId = nil }
        show("\(orderTitle(t)) 送到櫃台\(cash ? "付現" : "結帳")：請客人到櫃台付 \(due.formatted)", tone: .info)
    }

    /// 不是收銀台的（手機、點餐 iPad、接待）：這張要印電子發票證明聯（紙本、統編），這台又印不了＝不能在這裡收
    /// （刷卡、電子支付反灰，不跳警告）：輸入手機條碼、捐贈就能收；不然到櫃台付款。
    /// 印證明聯要兩樣：財政部 QR Code 的金鑰（後台只給收銀台）和發票出單機
    func needsCounterForInvoice(_ t: Ticket) -> Bool {
        guard !role.hasDrawer, features.invoice, invoiceSettings.enabled, t.invoiceBuyer.printsProof else { return false }
        let printsHere = !(invoiceSettings.qrKey ?? "").isEmpty && !printers.targets(.invoice).isEmpty
        guard !printsHere else { return false }
        return InvoiceBuilder.coverage(for: t, prepaid: store.prepaidInvoicing).amount.cents > 0
    }

    /// 這張是送到櫃台「付現」的
    static func wantsCash(_ t: Ticket) -> Bool { t.billSentFrom?.contains("付現") == true }

    /// 待結帳的單（印了結帳單、或送到結帳櫃台的）：側欄與手機「訂單」的數字
    var awaitingCheckout: [Ticket] {
        state.openTickets.filter { $0.billPrintedAt != nil }
    }

    var awaitingCheckoutCount: Int { awaitingCheckout.count }

    /// 結帳櫃台（有錢櫃）：別台送來、還沒結、也還沒按「先放著」的單，先送來的在前面
    var incomingHandoffs: [Ticket] {
        guard role.hasDrawer else { return [] }
        let inbox = HandoffInbox.shared
        return state.openTickets
            .filter { $0.billPrintedAt != nil && $0.billSentFrom != nil && !inbox.isDismissed($0) }
            .sorted { ($0.billPrintedAt ?? .distantPast) < ($1.billPrintedAt ?? .distantPast) }
    }

    /// 今天送到結帳櫃台、櫃台已經結好的單（手機的「訂單 → 待結帳」最下面：送出去之後看得到結果）
    var handedOffAndPaid: [Ticket] {
        let today = businessDate
        return state.tickets.values
            .filter { $0.status == .closed && $0.businessDate == today && $0.billSentFrom != nil }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
    }

    /// 收到別台的事件（區網、後台）：送來結帳的單 → 櫃台上方提示；這台送出去的單在櫃台結好了 → 這台上方提示
    func noteHandoffs(in events: [POSEvent]) {
        for e in events where e.deviceId != device.id {
            switch e.body {
            case .billPrinted(let ref):
                guard role.hasDrawer, let from = ref.sentFrom, let t = state.tickets[ref.ticketId], t.isOpen,
                      t.billSentFrom != nil else { continue }
                remoteActivity = "\(orderTitle(t)) 從\(from)送來結帳"
            case .ticketClosed(let c):
                guard !role.hasDrawer, let t = state.tickets[c.ticketId], t.deviceId == device.id, t.billSentFrom != nil else { continue }
                remoteActivity = "\(orderTitle(t)) 在櫃台結好了"
            default:
                continue
            }
        }
    }
}

/// 櫃台按了「先放著」（右欄的 ×）的送來結帳的單：只在這次開著的時候；同一張單再送一次會再出來
@Observable
final class HandoffInbox {
    static let shared = HandoffInbox()

    private(set) var dismissed: Set<String> = []

    private init() {}

    private func key(_ t: Ticket) -> String { "\(t.id)@\(t.billPrintedAt?.timeIntervalSince1970 ?? 0)" }

    func isDismissed(_ t: Ticket) -> Bool { dismissed.contains(key(t)) }

    func dismiss(_ t: Ticket) { dismissed.insert(key(t)) }
}
