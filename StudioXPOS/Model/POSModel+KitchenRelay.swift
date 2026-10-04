import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 幫前場的手機印廚房單：
//
//   手機（或任何沒有設定廚房出單機的裝置）送單時，在 lines.sent 上註記 relayPrint（new／add／fire），自己不印。
//   櫃台的 iPad 從區網或後台收到這個事件，照同一個樣式印到負責那一站的出單機——手機不用另外設定出單機，
//   櫃台接的藍牙出單機也用得到。設定「幫手機出廚房單」（預設開）；有好幾台櫃台時只留一台打開。

extension POSModel {
    /// 收到別台的事件時呼叫（describeRemote）
    func relayKitchenPrints(in events: [POSEvent]) {
        guard settings.printKitchenTickets, settings.printKitchenForOthers,
              takesPayment, printers.hasKitchenPrinter else { return }
        let now = Date()
        for e in events where e.deviceId != device.id {
            guard case .linesSent(let sent) = e.body, let raw = sent.relayPrint,
                  let mode = Self.kitchenMode(raw) else { continue }
            // 重新同步、剛裝好時會收到很久以前的事件：只印 10 分鐘內送的單
            guard now.timeIntervalSince(e.date) < 600 else { continue }
            guard KitchenRelayLog.shared.claim(e.id) else { continue }
            guard let t = state.tickets[sent.ticketId] else { continue }
            let ids = Set(sent.lineIds)
            let lines = t.lines.filter { ids.contains($0.id) && $0.isActive }
            guard !lines.isEmpty else { continue }
            printKitchen(t, lines: lines, mode: mode)
        }
    }

    private static func kitchenMode(_ raw: String) -> Templates.KitchenMode? {
        switch raw {
        case "new": .new
        case "add": .add
        case "fire": .fire
        default: nil
        }
    }
}

/// 印過的事件（同一個事件從區網、後台各來一次也只印一張；重開 App 也記得）
final class KitchenRelayLog {
    static let shared = KitchenRelayLog()

    private let key = "kitchenRelayPrinted"
    private var ids: [String]

    private init() {
        ids = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 第一次看到這個事件＝true（要印）；印過＝false
    func claim(_ eventId: String) -> Bool {
        guard !ids.contains(eventId) else { return false }
        ids.append(eventId)
        if ids.count > 400 { ids.removeFirst(ids.count - 400) }
        UserDefaults.standard.set(ids, forKey: key)
        return true
    }
}
