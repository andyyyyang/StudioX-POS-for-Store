import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右欄最上面固定的一塊（只在收銀台的右欄，鎖定、配對、手機的鍵盤不放）：叫號。沒有要放的就是空的。
///
///   外帶取餐（叫號 usage 有 takeout；點餐、訂單、廚房）       排隊等內用（usage 有 dineIn；桌位）
///   ┌──────────────────────────────┐                  ┌──────────────────────────────┐
///   │ 現在 23            等 8 位  › │ ← 點一下：叫號面板   │ 排隊 5 組・下一號 31（4 位）  › │
///   │ [ 叫下一號 24     ][再唸一次] │                  └──────────────────────────────┘
///   └──────────────────────────────┘
///
/// 剛結帳取到號碼時，上面那一行換成大大的「24 號」幾秒（客人看得到、店員念得出來）。
/// 不超過 120 點高（號碼一行約 38＋叫號鍵 46＋分隔線）：下面的數字鍵永遠在同一個位置。叫號頁開著、結帳時、這個營業模式用不到時不放；
/// 放著的時候每 3 秒抓一次號碼（POSModel.queuePinnedLoop）。
struct DockPinned: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        if let usage = model.queuePinned {
            VStack(alignment: .leading, spacing: 0) {
                if let s = model.queue.state {
                    switch usage {
                    case .takeout: QueuePinnedTakeout(state: s)
                    case .dineIn: QueuePinnedDineIn()
                    }
                    Rule(color: Theme.hair)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                } else {
                    // 還沒抓到號碼：不佔位置，抓到了才出現
                    Color.clear.frame(height: 0)
                }
            }
            .task(id: usage) { await model.queuePinnedLoop() }
        }
    }
}

// MARK: - 外帶取餐

/// 外帶的叫號卡：「現在 23　等 8 位 ›」（點了打開叫號面板）＋「叫下一號 24」「再唸一次」。
/// compact：手機點餐頁上面那張（字小一點）
struct QueuePinnedTakeout: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: QueueState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.openQueuePanel(.takeout)
            } label: {
                Group {
                    if let flash = model.queue.justTaken {
                        justTaken(flash)
                    } else {
                        summary
                    }
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 34 : 38, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打開叫號：叫指定的號碼、過號、返回前一號")
            keys
        }
        .animation(reduceMotion ? nil : Motion.spring, value: model.queue.justTaken)
        .task(id: model.queue.justTaken) {
            // 剛取到的號碼顯示 8 秒
            guard let flash = model.queue.justTaken else { return }
            try? await Task.sleep(for: .seconds(8))
            if model.queue.justTaken == flash { model.queue.justTaken = nil }
        }
    }

    /// 「現在 23　等 8 位 ›」（連不上時右邊是「連不上」）
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("現在")
                .font(.brand(13, .medium))
                .foregroundStyle(Theme.muted)
            Text(state.current.map { String($0) } ?? "—")
                .font(.brand(compact ? 28 : 32, .semibold))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(state.current == nil ? Theme.muted : Theme.ink)
                .contentTransition(.numericText(value: Double(state.current ?? 0)))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.brand(14, .medium))
                .monospacedDigit()
                .foregroundStyle(blocked ? Theme.warningFG : Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HeroIcon("chevron-right", size: 13)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("叫號：現在 \(state.current.map { "\($0) 號" } ?? "還沒叫")，\(trailing)")
    }

    /// 剛結帳取到的號碼：「24 號　A023 已結帳」
    private func justTaken(_ flash: QueueJustTaken) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("取號")
                .font(.brand(13, .medium))
                .foregroundStyle(Theme.accentText)
            Text("\(flash.number)")
                .font(.brand(compact ? 30 : 34, .semibold))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Text("號")
                .font(.brand(compact ? 15 : 17, .semibold))
                .foregroundStyle(Theme.accentText)
            Spacer(minLength: 6)
            Text("\(flash.ticketNumber) 已結帳")
                .font(.brand(13, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(flash.ticketNumber) 已結帳，取餐號碼 \(flash.number) 號")
    }

    /// 「叫下一號 24」（和數字鍵同一種鍵）＋「再唸一次」
    private var keys: some View {
        let next = state.waiting.first
        let can = model.queueCanAct
        return HStack(spacing: 8) {
            Button {
                Task { await model.nextQueue() }
            } label: {
                HStack(spacing: 7) {
                    HeroIcon("megaphone", size: 16)
                    Text(next.map { "叫下一號 \($0)" } ?? "沒有人在等")
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.brand(compact ? 14.5 : 15, .semibold))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: compact ? 42 : 46)
            }
            .buttonStyle(KeyStyle())
            .disabled(!can || next == nil || model.queueCooling(.next))
            .opacity(can && next != nil ? 1 : 0.45)
            .layoutPriority(1)
            Button {
                if let c = state.current { model.announceQueue(c, prefix: "再唸一次・", force: true) }
            } label: {
                HStack(spacing: 5) {
                    HeroIcon("speaker-wave", size: 15)
                    Text("再唸一次")
                        .lineLimit(1)
                }
                .font(.brand(compact ? 13.5 : 14, .medium))
                .padding(.horizontal, 11)
                .frame(minHeight: compact ? 42 : 46)
            }
            .buttonStyle(KeyStyle())
            .disabled(state.current == nil)
            .opacity(state.current == nil ? 0.45 : 1)
        }
    }

    private var blocked: Bool { model.queue.problem?.blocksPage == true }

    private var trailing: String {
        if blocked { return "連不上" }
        return state.waiting.isEmpty ? "沒有人在等" : "等 \(state.waiting.count) 位"
    }
}

// MARK: - 排隊等內用

/// 桌位頁的一行：「排隊 5 組・下一號 31（4 位）›」（點了打開叫號面板：點一組叫號入座）
struct QueuePinnedDineIn: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        Button {
            model.openQueuePanel(.dineIn)
        } label: {
            HStack(spacing: 10) {
                HeroIcon("users", size: 16)
                    .foregroundStyle(Theme.accentText)
                Text(model.queueDineInSummary ?? "")
                    .font(.brand(14.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                HeroIcon("chevron-right", size: 13)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(model.queueDineInSummary ?? "排隊")
        .accessibilityHint("打開叫號：點一組叫號入座")
    }
}

// MARK: - 手機

/// 手機點餐頁的叫號：平常只是頁首的一顆小鍵「27・等 6」（畫面留給菜單），點了才展開下面這張卡
struct PhoneQueueButton: View {
    @Environment(POSModel.self) private var model
    @Binding var open: Bool

    var body: some View {
        if model.queuePinned == .takeout {
            Button {
                withAnimation(Motion.spring) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    HeroIcon("megaphone", size: 16)
                    if let s = model.queue.state {
                        Text(s.current.map(String.init) ?? "—")
                            .font(.brand(16, .semibold))
                            .monospacedDigit()
                        if !s.waiting.isEmpty {
                            Text("\(s.waiting.count)")
                                .font(.brand(11.5, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Theme.accent, in: .capsule)
                        }
                    }
                }
                .foregroundStyle(open ? Theme.page : Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(open ? Theme.ink : Theme.surface, in: .capsule)
                .overlay { Capsule().strokeBorder(open ? Color.clear : Theme.line) }
                .contentShape(.capsule)
            }
            .buttonStyle(PressScale(scale: 0.96))
            .accessibilityLabel(queueLabel)
            .accessibilityHint(open ? "收起叫號" : "打開叫號")
            // 收起來時也要知道叫到幾號：抓號碼的迴圈跟著這顆鍵
            .task { await model.queuePinnedLoop() }
        }
    }

    private var queueLabel: String {
        guard let s = model.queue.state else { return "叫號" }
        return "叫號：現在 \(s.current.map(String.init) ?? "沒有")，等 \(s.waiting.count) 位"
    }
}

/// 手機點餐頁的叫號卡（全外帶的店）：頁首的叫號鍵點開才出現；和 iPad 右欄同一張，小一點。點了打開叫號面板（sheet）
struct PhoneQueueCard: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        if model.queuePinned == .takeout {
            VStack(spacing: 0) {
                if let s = model.queue.state {
                    QueuePinnedTakeout(state: s, compact: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
        }
    }
}
