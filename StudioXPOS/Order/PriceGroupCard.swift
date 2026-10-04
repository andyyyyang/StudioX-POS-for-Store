import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 小吃的兩種價錢（黃毛丫頭的鴨胸 140／150）：一張卡，價錢就是卡上的鍵，點哪個加哪個——不用打開選規格的卡。
///
///   ━━                 3     ← 這張單點了幾份（全部的價錢加起來）
///   鴨胸
///   3入
///   ┌──────┐┌──────┐
///   │ 140  ││ 150 ×2│        ← 點了的那個價錢亮起來、寫幾份
///   └──────┘└──────┘
///
/// 先在右側鍵盤打數字＝加那麼多份（和一般的品項一樣）。長按：少一份、標示賣完
struct PriceGroupCard: View {
    @Environment(POSModel.self) private var model
    let item: MenuItem
    let swatch: Swatch
    let available: Bool
    /// 小一點的卡（名字短、品項多的菜單）
    var compact = false
    let minus: () -> Void
    let toggleAvailability: () -> Void

    var body: some View {
        let total = count(nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.swatch(swatch))
                    .frame(width: 22, height: 4)
                Spacer()
                if total > 0 {
                    Text("\(total)")
                        .font(.brand(13, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Theme.accent, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Text(item.name)
                .font(.brand(16, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let portion {
                Text(portion)
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if available {
                HStack(spacing: 6) {
                    ForEach(item.activeVariants) { v in
                        priceKey(v)
                    }
                }
            } else {
                StatusBadge("賣完", tone: .danger)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 88 : 112, alignment: .topLeading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(total > 0 ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: total > 0 ? 1.5 : 1)
        }
        .opacity(available ? 1 : 0.5)
        .animation(Motion.spring, value: total)
        .contextMenu {
            if total > 0 {
                Button("少一份", systemImage: "minus") { minus() }
            }
            Button(available ? "標示賣完" : "恢復供應", systemImage: available ? "nosign" : "checkmark") { toggleAvailability() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name)\(portion.map { "，\($0)" } ?? "")\(available ? "" : "，賣完")\(total > 0 ? "，已點 \(total)" : "")")
    }

    /// 卡上的一個價錢鍵
    private func priceKey(_ v: ItemVariant) -> some View {
        let n = count(v)
        let price = item.price(of: v)
        let label = v.options.joined(separator: " ")
        // 選項本身就是價錢（「140」）就只寫價錢；不是（「大」「小」）就寫「大 150」
        let title = label == price.plain ? price.plain : "\(label) \(price.plain)"
        return Button {
            Task { await model.tap(item, variant: v) }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.brand(16, .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if n > 0 {
                    Text("×\(n)")
                        .font(.brand(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accentText)
                }
            }
            .foregroundStyle(v.isAvailable ? Theme.ink : Theme.faint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(n > 0 ? Theme.accentSoft : Theme.ink.opacity(0.06), in: .rect(cornerRadius: Metric.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(n > 0 ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.94))
        .disabled(!v.isAvailable)
        .accessibilityLabel("\(item.name) \(title)\(n > 0 ? "，已點 \(n)" : "")\(v.isAvailable ? "" : "，賣完")")
    }

    /// 這張單點了幾份（nil＝全部的價錢加起來）
    private func count(_ v: ItemVariant?) -> Int {
        model.selectedTicket?.activeLines
            .filter { $0.itemId == item.id && (v == nil || $0.skuId == v?.id) }
            .reduce(0) { $0 + $1.quantity } ?? 0
    }

    /// 份量（「3入」「1串」）：單位裡有數字才寫
    private var portion: String? {
        item.unit.contains(where: \.isNumber) ? item.unit : nil
    }
}

extension POSModel {
    /// 卡上的價錢鍵：直接加那個價錢（不用打開選規格的卡）；有加料（甜度、辣度）的照樣打開加料的卡
    func tap(_ item: MenuItem, variant v: ItemVariant) async {
        touch()
        guard isAvailable(item), v.isAvailable else {
            show("\(item.name) \(v.label) 今天賣完了", tone: .warning)
            return
        }
        if !catalog.groups(for: item).isEmpty {
            modifierItem = nil
            variantItem = item
            return
        }
        let qty = keypad.takeQuantity()
        guard await ensureMemberIfNeeded(for: item) else { return }
        add(item, variant: v, quantity: qty, modifiers: [], note: "")
    }
}
