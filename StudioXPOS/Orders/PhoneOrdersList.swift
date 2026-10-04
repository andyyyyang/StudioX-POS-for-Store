import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 手機的訂單：還開著的單，分「進行中｜待結帳」。
///
///   進行中：點餐中、出餐中、用餐中的單（點一下＝到點餐頁、打開那張單）
///   待結帳：送到結帳櫃台（或印了結帳單）、等客人去付的；櫃台結好的留在下面，標「已結帳」（統一結帳：送出去之後看得到結果）
struct PhoneOrdersList: View {
    @Environment(POSModel.self) private var model
    @Environment(PhoneUI.self) private var ui

    private enum Tab: Hashable { case open, billing }

    @State private var tab: Tab = .open

    var body: some View {
        let open = model.state.openTickets.filter { $0.billPrintedAt == nil }.sorted { $0.openedAt > $1.openedAt }
        let waiting = model.awaitingCheckout.sorted { ($0.billPrintedAt ?? $0.openedAt) > ($1.billPrintedAt ?? $1.openedAt) }
        let paid = Array(model.handedOffAndPaid.prefix(20))
        VStack(alignment: .leading, spacing: 12) {
            PageTitle(title: "Open *tickets*", subtitle: "訂單")
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Picker("", selection: $tab) {
                Text("進行中 \(open.count)").tag(Tab.open)
                Text("待結帳 \(waiting.count)").tag(Tab.billing)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .accessibilityLabel("進行中或待結帳")
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        switch tab {
                        case .open:
                            if open.isEmpty {
                                empty("沒有進行中的單", "點餐頁開的單、桌位入座的單會出現在這裡")
                            }
                            ForEach(open) { t in
                                Button { openInOrder(t) } label: { row(t, now: ctx.date) }
                                    .buttonStyle(PressScale(scale: 0.98))
                            }
                        case .billing:
                            if waiting.isEmpty && paid.isEmpty {
                                empty("沒有等結帳的單", "單子「送到結帳櫃台」後會在這裡，櫃台結好會標「已結帳」")
                            }
                            ForEach(waiting) { t in
                                Button { openInOrder(t) } label: { row(t, now: ctx.date) }
                                    .buttonStyle(PressScale(scale: 0.98))
                            }
                            if !paid.isEmpty {
                                Eyebrow("櫃台結好了")
                                    .padding(.top, 12)
                                ForEach(paid) { t in
                                    row(t, now: ctx.date)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if LaunchArguments.preselect, !waiting.isEmpty { tab = .billing }
        }
    }

    /// 點一張開著的單：到點餐頁、單子打開在下面
    private func openInOrder(_ t: Ticket) {
        model.touch()
        guard t.isOpen, model.visibleSections.contains(.order) else { return }
        model.selectedTicketId = t.id
        ui.openTicketOnArrival = true
        model.go(.order)
    }

    private func empty(_ title: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .textRole(.h4)
                .foregroundStyle(Theme.ink2)
            Text(message)
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// 一張單：名字（桌號、外帶 A023）、單號・幾項・誰開的・多久、金額、狀態（點餐中／出餐中／用餐中／待結帳／已結帳）
    private func row(_ t: Ticket, now: Date) -> some View {
        let state = status(t, now: now)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t.title(floor: model.floor))
                        .font(.brand(17, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    StatusBadge(state.label, tone: state.tone)
                }
                Text(state.detail)
                    .font(.brand(13, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            MoneyText(money: t.isOpen ? t.totals.amountDue : t.totals.total, role: .h4,
                      color: t.isOpen ? Theme.ink : Theme.muted)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private struct RowStatus {
        var label: String
        var tone: Tone
        var detail: String
    }

    private func status(_ t: Ticket, now: Date) -> RowStatus {
        var parts = [t.number, "\(t.itemCount) 項", model.staffName(t.openedBy)]
        if !t.isOpen {
            if let at = t.closedAt { parts.append("\(TaipeiTime.clock(at)) 結帳") }
            return RowStatus(label: "已結帳", tone: .active, detail: parts.joined(separator: "・"))
        }
        if let at = t.billPrintedAt {
            parts.append(t.billSentFrom != nil ? "\(TaipeiTime.clock(at)) 送到櫃台" : "\(TaipeiTime.clock(at)) 印了結帳單")
            return RowStatus(label: "待結帳", tone: .warning, detail: parts.joined(separator: "・"))
        }
        let minutes = max(0, Int(now.timeIntervalSince(t.openedAt) / 60))
        parts.append("\(minutes) 分")
        let lines = t.activeLines
        if lines.isEmpty || lines.contains(where: { !$0.isSent }) && model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst {
            return RowStatus(label: "點餐中", tone: .gold, detail: parts.joined(separator: "・"))
        }
        if model.features.kitchen, lines.contains(where: { $0.isSent && $0.kitchen != .served && $0.kitchen != .ready }) {
            return RowStatus(label: "出餐中", tone: .info, detail: parts.joined(separator: "・"))
        }
        return RowStatus(label: "用餐中", tone: .active, detail: parts.joined(separator: "・"))
    }
}
