import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 叫號蓋住右欄的兩個面板（.dockPanel，選項是 DockChoice）：
//   - 「叫號」：右欄最上面那張叫號卡點開的。外帶＝點一個號碼叫他（先做好的先叫）；排隊等內用＝點一組叫號入座。下面是過號、返回前一號
//   - 「31 號入座」：叫到號之後選桌（坐得下的排前面），點一張就開內用單（人數、號碼掛上去）
// 兩個都掛在收得到 DockKey 的地方：iPad 的工作區（MainShell）、手機的這一頁（PhoneShell）。

extension View {
    /// 叫號的面板（叫號、叫到號之後選桌入座）。換頁就關掉
    func queueDockPanels() -> some View {
        modifier(QueueDockPanels())
    }
}

private struct QueueDockPanels: ViewModifier {
    @Environment(POSModel.self) private var model

    func body(content: Content) -> some View {
        content
            .dockPanel(item: seatingBinding, title: { "\($0.number) 號入座" }, subtitle: { "\($0.guests) 位・坐得下的排前面，點一張就入座" }) { seat in
                QueueSeatChoices(seat: seat)
            }
            .dockPanel(isPresented: panelBinding, title: "叫號", subtitle: panelSubtitle) {
                QueueCallPanel(usage: model.queue.panel ?? .takeout)
            }
            .onChange(of: model.section) { _, _ in
                model.queue.panel = nil
                model.queue.seating = nil
            }
    }

    private var seatingBinding: Binding<QueueSeat?> {
        Binding(get: { model.queue.seating }, set: { model.queue.seating = $0 })
    }

    /// 叫號卡收起來（換頁、結帳）時面板也不出現
    private var panelBinding: Binding<Bool> {
        Binding(get: { model.queue.panel != nil && model.queue.panel == model.queuePinned },
                set: { if !$0 { model.queue.panel = nil } })
    }

    private var panelSubtitle: String? {
        guard let s = model.queue.state else { return nil }
        if model.queue.panel == .dineIn { return model.queueDineInSummary }
        let now = s.current.map { "現在 \($0) 號" } ?? "還沒叫號"
        return s.waiting.isEmpty ? "\(now)・沒有人在等" : "\(now)・等 \(s.waiting.count) 位"
    }
}

// MARK: - 叫號

/// 等候中的號碼一個一列：外帶＝點了叫那一號（號碼的單做好了右邊寫「好了」）；排隊等內用＝點了叫號入座。
/// 原本的叫號伺服器只能照順序叫：只有第一位點得了，上面一行說明要改成後台叫號
struct QueueCallPanel: View {
    @Environment(POSModel.self) private var model
    let usage: QueueUsage

    var body: some View {
        // 每 30 秒重畫：等了幾分
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = model.queue.problem, p.blocksPage {
                note(p.message, tone: .danger)
            }
            if let s = model.queue.state {
                if let c = s.current {
                    DockChoice(title: "現在 \(c) 號", detail: currentDetail(c, s), trailing: "再唸一次") {
                        model.announceQueue(c, prefix: "再唸一次・", force: true)
                    }
                }
                if model.queueMode != .native && s.waiting.count > 1 {
                    note("原本的叫號伺服器只能照順序叫「下一號」。要叫指定的號碼（先做好的先叫），請在後台「叫號」把號碼改存在後台。", tone: .info)
                }
                Eyebrow(usage == .dineIn ? "排隊中・點一組叫號入座" : "等候中・點一個號碼叫他", color: Theme.muted)
                    .padding(.top, 10)
                if s.waiting.isEmpty {
                    Text("沒有人在等")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 6)
                }
                ForEach(s.waiting, id: \.self) { n in
                    DockChoice(title: "\(n) 號", detail: detail(n, s, now: now), trailing: trailing(n, s, now: now),
                               enabled: model.queueCanCall(n)) {
                        pick(n)
                    }
                }
                Eyebrow("按錯、沒來", color: Theme.muted)
                    .padding(.top, 10)
                DockChoice(title: "過號", detail: s.current.map { "\($0) 號沒來：移到過號、自動叫下一號" } ?? "現在沒有在叫",
                           enabled: model.queueCanAct && s.current != nil && !model.queueCooling(.miss)) {
                    model.queue.panel = nil
                    Task { await model.missQueue() }
                }
                DockChoice(title: "返回前一號", detail: s.current.map { "\($0) 號放回等候的最前面（叫錯時用）" } ?? "現在沒有在叫",
                           enabled: model.queueCanAct && s.current != nil) {
                    model.queue.panel = nil
                    Task { await model.previousQueue() }
                }
            } else {
                Text("正在抓號碼…")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func pick(_ n: Int) {
        switch usage {
        case .takeout:
            Task {
                if await model.callQueue(n) { model.queue.panel = nil }
            }
        case .dineIn:
            Task { await model.callToSeat(n) }
        }
    }

    /// 「A023・5 項・好了」「4 位」「12:05 叫的」
    private func currentDetail(_ c: Int, _ s: QueueState) -> String? {
        let parts = [model.queueDetail(c), s.calledAt.map { "\($0.clockText) 叫的" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 外帶：單子與進度（「A028・5 項・製作中」）；排隊：等了幾分（人數在右邊）
    private func detail(_ n: Int, _ s: QueueState, now: Date) -> String? {
        var parts: [String] = []
        if s.waiting.first == n { parts.append("下一號") }
        switch usage {
        case .takeout:
            if let d = model.queueDetail(n) { parts.append(d) }
        case .dineIn:
            if let m = s.waitMinutes(n, now: now) { parts.append(m == 0 ? "剛取號" : "等了 \(m) 分") }
            if let label = model.queueEntry(n)?.label { parts.append(label) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// 外帶：等了幾分；排隊：幾位
    private func trailing(_ n: Int, _ s: QueueState, now: Date) -> String? {
        switch usage {
        case .takeout:
            return s.waitMinutes(n, now: now).map { $0 == 0 ? "剛取" : "\($0) 分" }
        case .dineIn:
            return model.queueEntry(n)?.guests.map { "\($0) 位" }
        }
    }

    private func note(_ text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tone.dot).frame(width: 7, height: 7).padding(.top, 6)
            Text(text)
                .textRole(.small)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: .rect(cornerRadius: Metric.radius, style: .continuous))
    }
}

// MARK: - 叫到號之後選桌入座

/// 一張空桌一列（和訂位入座同一種）：坐得下的排前面（座位少的先，免得大桌被小團佔走）、比較擠的在後面；點一張就入座。
/// 沒有空桌：先不帶位、直接開單。人數不對可以在這裡改（右欄的鍵盤問，問完面板回來）
struct QueueSeatChoices: View {
    @Environment(POSModel.self) private var model
    let seat: QueueSeat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if free.isEmpty {
                Text("現在沒有空桌：先清桌，或請客人稍等一下。")
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            } else {
                if !fits.isEmpty {
                    Eyebrow("坐得下的", color: Theme.muted)
                    ForEach(fits) { t in choice(t) }
                }
                if !tight.isEmpty {
                    Eyebrow("比較擠", color: Theme.muted)
                        .padding(.top, fits.isEmpty ? 0 : 10)
                    ForEach(tight) { t in choice(t) }
                }
            }
            Eyebrow("其他", color: Theme.muted)
                .padding(.top, 10)
            DockChoice(title: "改人數", detail: "現在 \(seat.guests) 位", trailing: "\(seat.guests) 位") {
                Task { await changeGuests() }
            }
            DockChoice(title: "先不帶位，直接開單", detail: "開一張內用單：\(seat.guests) 位、\(seat.number) 號") {
                model.seatQueue(seat, at: [])
            }
        }
    }

    private func choice(_ t: DiningTable) -> some View {
        let area = model.floor.areas.first { a in a.tables.contains { $0.id == t.id } }?.name ?? ""
        return DockChoice(title: t.name, detail: area.isEmpty ? nil : area, trailing: "\(t.seats) 人") {
            model.seatQueue(seat, at: [t.id])
        }
    }

    private var free: [DiningTable] {
        model.floor.allTables.filter { model.tableStatus($0.id) == .available }
    }

    private var fits: [DiningTable] {
        free.filter { $0.seats >= seat.guests }.sorted { $0.seats < $1.seats }
    }

    private var tight: [DiningTable] {
        free.filter { $0.seats < seat.guests }.sorted { $0.seats > $1.seats }
    }

    private func changeGuests() async {
        let number = seat.number
        guard let g = await model.keypad.askNumber(.guests(current: seat.guests).with(subtitle: "\(number) 號幾位？")) else { return }
        model.queue.seating = QueueSeat(number: number, guests: max(g, 1))
    }
}
