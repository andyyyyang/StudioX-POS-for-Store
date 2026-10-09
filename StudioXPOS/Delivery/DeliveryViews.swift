import Foundation
import POSCore
import POSPrinting
import POSSync
import SwiftUI

// 外送平台的單在畫面上的樣子（訂單看板、廚房、右欄）。
// 平台用品牌色（Uber Eats 綠、foodpanda 粉紅）：店員一眼就知道是哪個平台、要給哪個外送員。

extension DeliveryPlatform {
    var tint: Color {
        switch self {
        case .ubereats: Color(light: 0x06A35A, dark: 0x34D27B)
        case .foodpanda: Color(light: 0xD70F64, dark: 0xF2559A)
        }
    }
}

/// 「● Uber Eats #3F2A1」
struct DeliveryTag: View {
    let delivery: DeliveryOrder
    var showsCode = true
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(delivery.platform.tint).frame(width: 7, height: 7)
            Text(showsCode ? "\(delivery.platform.label) #\(delivery.code)" : delivery.platform.label)
        }
        .font(.brand(size, .semibold))
        .foregroundStyle(delivery.platform.tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(delivery.platform.tint.opacity(0.13), in: .rect(cornerRadius: Metric.chip))
        .accessibilityLabel("\(delivery.platform.label) 訂單 \(delivery.code)")
    }
}

/// 外送單的時間：待接單倒數（「還剩 9:42 接單」，最後兩分鐘紅字）、接了之後「12 分後要好」、做好了看外送員
struct DeliveryClock: View {
    let delivery: DeliveryOrder
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (text, tone) = Self.describe(delivery, now: ctx.date)
            Text(text)
                .font(.brand(size, .semibold))
                .monospacedDigit()
                .foregroundStyle(tone.foreground)
                .lineLimit(1)
        }
    }

    static func describe(_ d: DeliveryOrder, now: Date) -> (String, Tone) {
        switch d.status {
        case .pending:
            guard let s = d.secondsToAccept(at: now) else { return ("待接單", .warning) }
            if s <= 0 { return ("快逾時了", .danger) }
            return ("還剩 \(s / 60):\(String(format: "%02d", s % 60)) 接單", s < 120 ? .danger : .warning)
        case .accepted:
            guard let m = d.minutesToReady(at: now) else { return ("製作中", .info) }
            return m >= 0 ? ("\(m) 分後要好", m <= 3 ? .warning : .info) : ("晚了 \(-m) 分", .danger)
        case .ready:
            if d.kind == .pickup { return ("等客人取餐", .active) }
            guard let c = d.courier else { return ("等外送員", .active) }
            if c.status == .arrived { return ("外送員到了", .gold) }
            if let eta = c.eta {
                let m = max(Int(eta.timeIntervalSince(now) / 60), 0)
                return (m == 0 ? "外送員快到了" : "外送員 \(m) 分後到", .active)
            }
            return (c.status.label, .active)
        case .pickedUp: return ("已取餐", .neutral)
        case .rejected: return ("已拒單", .neutral)
        case .cancelled: return ("平台取消", .danger)
        }
    }
}

/// 訂單看板上的外送單：平台、倒數、客人、幾項多少、備註
struct DeliveryOrderCard: View {
    let ticket: Ticket
    let selected: Bool

    var body: some View {
        if let d = ticket.delivery {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    DeliveryTag(delivery: d)
                    Spacer(minLength: 4)
                    DeliveryClock(delivery: d)
                }
                Text(d.customerName.map { "\($0)・\(d.kind == .pickup ? "自取" : "外送")" } ?? (d.kind == .pickup ? "自取" : "外送"))
                    .font(.brand(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(ticket.itemCount) 項・\(d.subtotal.formatted)")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if let note = d.customerNote, !note.isEmpty {
                    Text("※ \(note)")
                        .font(.brand(13, .semibold))
                        .foregroundStyle(Theme.warningFG)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .frame(width: 236, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : (d.status == .pending ? d.platform.tint : Theme.line),
                                  lineWidth: selected || d.status == .pending ? 2 : 1)
            }
            .contentShape(.rect)
        }
    }
}

/// 右欄卡片下面：時間、建議的備餐時間、品項
private struct DeliveryDockExtra: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket

    var body: some View {
        if let d = ticket.delivery {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DeliveryTag(delivery: d, showsCode: false, size: 12)
                    DeliveryClock(delivery: d, size: 14)
                }
                if d.status == .pending {
                    // 建議的分鐘數看廚房現在的份數；打數字就用打的
                    Text("建議 \(model.suggestedPrepMinutes(for: ticket)) 分（廚房 \(model.kitchenLoad) 份待做）・打數字改分鐘數")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ticket.activeLines.prefix(6)) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(l.quantity)")
                                .font(.brand(13, .semibold))
                                .monospacedDigit()
                                .frame(minWidth: 16, alignment: .trailing)
                            Text(l.modifierText.isEmpty ? l.name : "\(l.name)（\(l.modifierText)）")
                                .font(.brand(13, .regular))
                                .lineLimit(1)
                            if (l.itemId ?? "").isEmpty {
                                // 平台上的品項對不到 POS 的（菜單沒同步）：照樣做，標出來
                                StatusBadge("沒對到", tone: .warning)
                            }
                        }
                        .foregroundStyle(Theme.ink2)
                    }
                    if ticket.activeLines.count > 6 {
                        Text("還有 \(ticket.activeLines.count - 6) 項").font(.brand(12, .regular)).foregroundStyle(Theme.muted)
                    }
                }
                if let note = d.customerNote, !note.isEmpty {
                    Text("※ \(note)")
                        .font(.brand(13, .semibold))
                        .foregroundStyle(Theme.warningFG)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 外送單選起來時的右欄：
///   待接單 → 大鍵「接單・18 分」（打數字就是打的分鐘數）、「拒單…」
///   製作中 → 「出餐好了」（廚房整張做好會自動按）、「重印廚房單」「取消訂單…」
///   等取餐 → 「外送員拿走了」
@MainActor
func deliveryDock(_ t: Ticket, model: POSModel, reject: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void,
                  clear: @escaping @MainActor () -> Void) -> DockSelection? {
    guard let d = t.delivery else { return nil }
    let busy = model.deliveryBusy.contains(t.id)
    var primary: POSAction?
    var actions: [POSAction] = []
    switch d.status {
    case .pending:
        let suggested = model.suggestedPrepMinutes(for: t)
        let minutes = model.keypad.multiplier ?? suggested
        primary = POSAction(busy ? "接單中…" : "接單・\(minutes) 分", icon: "check-circle", enabled: !busy) {
            let m = model.keypad.multiplier ?? suggested
            model.keypad.clearIdle()
            Task { await model.acceptDelivery(t, prepMinutes: m) }
        }
        actions.append(POSAction("拒單…", icon: "x-circle", destructive: true, perform: reject))
    case .accepted:
        primary = POSAction(busy ? "通知中…" : "出餐好了", icon: "check-circle", enabled: !busy) {
            Task { await model.markDeliveryReady(t) }
        }
        actions.append(POSAction("重印廚房單", icon: "printer") { model.printKitchen(t, lines: t.activeLines, mode: .new) })
        actions.append(POSAction("取消訂單…", icon: "x-circle", destructive: true, perform: cancel))
    case .ready:
        primary = POSAction(d.kind == .pickup ? "客人拿走了" : "外送員拿走了", icon: "truck") { model.markDeliveryPickedUp(t) }
        actions.append(POSAction("重印廚房單", icon: "printer") { model.printKitchen(t, lines: t.activeLines, mode: .new) })
    case .pickedUp, .rejected, .cancelled:
        break
    }
    let tone: Tone = switch d.status {
    case .pending: .warning
    case .accepted: .info
    case .ready: .active
    case .cancelled: .danger
    case .pickedUp, .rejected: .neutral
    }
    var detail = ["\(t.itemCount) 項", d.subtotal.formatted]
    if let name = d.customerName { detail.insert(name, at: 0) }
    if d.status == .cancelled, t.status == .closed { detail.append("已結帳：到「訂單 → 全部」退款") }
    return DockSelection(
        id: "delivery-\(t.id)-\(d.status.rawValue)",
        kind: d.kind == .pickup ? "外送平台・自取" : "外送平台",
        title: d.title,
        detail: detail.joined(separator: "・"),
        badge: DockBadge(d.status.label, tone: tone),
        primary: primary,
        accent: d.status == .pending,
        actions: actions,
        extra: AnyView(DeliveryDockExtra(ticket: t)),
        clear: clear
    )
}

/// 拒單、取消的原因（面板）：平台要原因，選一個就送出
struct DeliveryReasonChoices: View {
    let onPick: (DeliveryReason) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(DeliveryReason.allCases, id: \.self) { r in
                Button { onPick(r) } label: {
                    HStack {
                        Text(r.label).font(.brand(16, .medium))
                        Spacer()
                        HeroIcon("chevron-right", size: 14).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(KeyStyle())
            }
            Text("一直拒單或不接，平台會暫停你的店。忙不過來可以先按「忙碌」加時間。")
                .font(.brand(12.5, .regular))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

/// 外送平台的狀態列（右欄、設定）：哪個平台在接單、暫停到幾點、忙碌加幾分
struct DeliveryPlatformRow: View {
    let state: DeliveryPlatformState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(state.platform.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.platform.label).font(.brand(14.5, .semibold)).foregroundStyle(Theme.ink)
                Text(caption).font(.brand(12, .regular)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 6)
            StatusBadge(statusText, tone: statusTone)
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        if !state.connected { return "沒連上" }
        return state.isOnline ? "接單中" : "暫停"
    }

    private var statusTone: Tone {
        if !state.connected { return .danger }
        return state.isOnline ? .active : .warning
    }

    private var caption: String {
        var parts: [String] = []
        if let until = state.pausedUntil, !state.isOnline { parts.append("暫停到 \(TaipeiTime.clock(until))") }
        if state.pausedBy == "watchdog" { parts.append("POS 斷線時自動暫停") }
        if state.busyExtraMinutes > 0 { parts.append("忙碌 +\(state.busyExtraMinutes) 分") }
        parts.append(state.autoAccept ? "自動接單" : "手動接單")
        parts.append("備餐 \(state.defaultPrepMinutes) 分")
        if let e = state.lastError { parts.append("錯誤：\(e.message)") }
        return parts.joined(separator: "・")
    }
}
