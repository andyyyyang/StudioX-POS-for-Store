import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 點餐：上面是分類的粉彩大方塊，下面是這一類的品項。點一下＝加一份（先在右側鍵盤打數量＝加那麼多份）
struct MenuView: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @State private var categoryId: String?
    @State private var query = ""
    /// 菜單這一區的高度（客製的卡最多到它的三分之二）
    @State private var areaHeight: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)
            // 規格（顏色、尺寸）與加料（甜度、冰塊）：浮在菜單上的一張卡，不佔滿整區（菜單還看得到）；點卡外面＝不加了
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if query.isEmpty {
                            categories
                        }
                        items
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                if let item = model.variantItem ?? model.modifierItem {
                    Theme.page.opacity(0.55)
                        .contentShape(.rect)
                        .onTapGesture { closeCustomize() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    CustomizeCard(maxHeight: max(areaHeight * 0.66, 320), close: { closeCustomize() }) {
                        if model.variantItem != nil {
                            VariantPanel(item: item, card: true)
                                .id(item.id)
                        } else {
                            ModifierPanel(item: item, card: true)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { areaHeight = $0 })
            if let sale = model.lastSale, model.selectedTicket == nil, Date().timeIntervalSince(sale.closedAt) < 120 {
                LastSaleStrip(sale: sale)
            }
        }
        .animation(Motion.ease, value: model.modifierItem)
        .animation(Motion.ease, value: model.variantItem)
        // 結帳櫃台：手機送來結帳的單（還沒開單時在右欄，大鍵「去結帳」）
        .onAppear {
            if categoryId == nil { categoryId = model.catalog.categories.first?.id }
        }
    }

    private func closeCustomize() {
        model.variantItem = nil
        model.modifierItem = nil
    }

    // MARK: 上面

    /// 頁首：標題｜搜尋。自訂品項、掃條碼、開新單、用餐方式都在右欄（單子的動作）
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let t = model.selectedTicket {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(t.number)
                        Headline(t.title(floor: model.floor), role: .h3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow("點餐")
                        Headline("The *menu*", role: .h3)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                HeroIcon("magnifying-glass", size: 16)
                    .foregroundStyle(Theme.muted)
                TextField("搜尋品項、品號", text: $query)
                    .font(.brand(15, .regular))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        HeroIcon("x-circle", size: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("清除搜尋")
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 150, idealWidth: 240, maxWidth: 240, minHeight: 44, maxHeight: 44)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }
    }

    // MARK: 分類

    private var categories: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 12)], spacing: 12) {
            ForEach(model.catalog.categories) { c in
                CategoryTile(category: c, count: model.catalog.items(in: c.id).count, selected: categoryId == c.id) {
                    withAnimation(Motion.fast) { categoryId = c.id }
                    model.touch()
                }
            }
        }
    }

    // MARK: 品項

    private var shownItems: [MenuItem] {
        if !query.isEmpty { return model.catalog.search(query) }
        guard let id = categoryId else { return model.catalog.items }
        return model.catalog.items(in: id)
    }

    @ViewBuilder
    private var items: some View {
        let list = shownItems
        if list.isEmpty {
            EmptyState(icon: "magnifying-glass", title: query.isEmpty ? "這一類還沒有品項" : "找不到「\(query)」", message: query.isEmpty ? "到後台「門市 POS → 菜單」新增" : nil)
                .frame(height: 260)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let c = categoryId.flatMap({ model.catalog.category($0) }), query.isEmpty {
                    Eyebrow("\(c.name)・\(list.count) 項")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(list) { item in
                        if item.hasVariants {
                            // 服飾：像選物店的目錄（照片或色票、幾色幾碼、價格、庫存）
                            BoutiqueItemCard(item: item, swatch: model.catalog.category(item.categoryId)?.swatch ?? .sand,
                                             inTicket: quantity(of: item), available: model.isAvailable(item)) {
                                Task { await model.tap(item) }
                            } minus: {
                                decrement(item)
                            } toggleAvailability: {
                                model.toggleAvailability(item)
                            }
                        } else {
                            ItemCard(item: item, swatch: model.catalog.category(item.categoryId)?.swatch ?? .sand,
                                     inTicket: quantity(of: item), available: model.isAvailable(item),
                                     hasOptions: !item.modifierGroupIds.isEmpty, multiplier: keypad.multiplier) {
                                Task { await model.tap(item) }
                            } minus: {
                                decrement(item)
                            } toggleAvailability: {
                                model.toggleAvailability(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func quantity(of item: MenuItem) -> Int {
        model.selectedTicket?.activeLines.filter { $0.itemId == item.id }.reduce(0) { $0 + $1.quantity } ?? 0
    }

    private func decrement(_ item: MenuItem) {
        guard let t = model.selectedTicket, let line = t.activeLines.last(where: { $0.itemId == item.id && !$0.isSent }) else { return }
        model.stepQuantity(line, in: t, by: -1)
    }
}

/// 分類的大方塊：粉彩底、墨色字（和參考的 CosyPOS 同一個手感，色票換成 StudioX 的暖色系）
struct CategoryTile: View {
    let category: MenuCategory
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Circle()
                    .fill(Theme.tileInk.opacity(0.85))
                    .frame(width: 8, height: 8)
                Spacer(minLength: 10)
                Text(category.name)
                    .font(.brand(18, .semibold))
                    .foregroundStyle(Theme.tileInk)
                    .lineLimit(1)
                Text("\(count) 項")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.tileInkMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(Theme.swatch(category.swatch), in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: selected ? 2.5 : 0)
                    .padding(-4)
            }
            .scaleEffect(selected ? 1 : 0.985)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .accessibilityLabel("\(category.name)，\(count) 項")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一個品項（服務多了時間、課程卡多了次數與期限、儲值多了送多少、服飾多了幾色幾碼與庫存）
struct ItemCard: View {
    let item: MenuItem
    let swatch: Swatch
    let inTicket: Int
    let available: Bool
    let hasOptions: Bool
    let multiplier: Int?
    let tap: () -> Void
    let minus: () -> Void
    let toggleAvailability: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.swatch(swatch))
                        .frame(width: 22, height: 4)
                    Spacer()
                    if inTicket > 0 {
                        Text("\(inTicket)")
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
                if let meta {
                    HStack(spacing: 5) {
                        HeroIcon(meta.icon, size: 13)
                        Text(meta.text)
                            .lineLimit(1)
                        if let trailing = meta.trailing {
                            Spacer(minLength: 4)
                            Text(trailing)
                                .monospacedDigit()
                                .lineLimit(1)
                                .foregroundStyle(meta.warn ? Theme.warningFG : Theme.muted)
                        }
                    }
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(priceText)
                        .font(.brand(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    if !available {
                        StatusBadge("賣完", tone: .danger)
                    } else if item.hasVariants {
                        Text("選規格")
                            .font(.brand(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    } else if hasOptions {
                        Text("可選")
                            .font(.brand(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    } else if let m = multiplier, m > 1 {
                        Text("+\(m)")
                            .font(.brand(12, .semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(inTicket > 0 ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: inTicket > 0 ? 1.5 : 1)
            }
            .opacity(available ? 1 : 0.5)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .animation(Motion.spring, value: inTicket)
        .contextMenu {
            if inTicket > 0 {
                Button("少一份", systemImage: "minus") { minus() }
            }
            Button(available ? "標示賣完" : "恢復供應", systemImage: available ? "nosign" : "checkmark") { toggleAvailability() }
        }
        .accessibilityLabel("\(item.name)，\(priceText)\(meta.map { "，\($0.text)" } ?? "")\(available ? "" : "，賣完")\(inTicket > 0 ? "，已點 \(inTicket)" : "")")
    }

    // MARK: 依種類的小字

    private struct Meta {
        var icon: String
        var text: String
        var trailing: String? = nil
        var warn = false
    }

    /// 服務：「60 分」；課程卡：「10 次・180 天內」；儲值：「儲 10,000 送 1,000」；服飾：「6 色 × 5 尺寸　庫存 42」
    private var meta: Meta? {
        if item.hasVariants {
            let stock = item.totalStock
            return Meta(icon: "swatch", text: VariantPanel.summary(of: item),
                        trailing: stock.map { $0 > 0 ? "庫存 \($0)" : "缺貨" }, warn: (stock ?? 1) <= 0)
        }
        switch item.itemKind {
        case .service:
            guard let minutes = item.durationMinutes, minutes > 0 else { return nil }
            return Meta(icon: "clock", text: "\(minutes) 分")
        case .pass:
            guard let spec = item.pass else { return nil }
            return Meta(icon: "ticket", text: spec.summary)
        case .storedValue:
            return Meta(icon: "gift", text: storedValueText)
        case .goods:
            return nil
        }
    }

    private var storedValueText: String {
        if item.openPrice { return "自訂儲值金額" }
        let credit = item.credit ?? item.price
        let bonus = credit - item.price
        return bonus.cents > 0 ? "儲 \(item.price.plain) 送 \(bonus.plain)" : "儲值 \(credit.plain)"
    }

    private var priceText: String {
        if item.openPrice { return item.itemKind == .storedValue ? "自訂" : "時價" }
        if item.hasVariants, let from = VariantPanel.startingPrice(of: item) { return "\(from.short) 起" }
        if item.hasVariants { return item.price(of: item.activeVariants.first).short }
        return item.price.short
    }
}

/// 服飾的品項：像選物店的目錄——上面是商品照（沒有照片就是這款有哪些顏色的色票、尺寸範圍），
/// 下面是名字、「6 色 × 5 尺寸」、價格（規格價格不同寫「起」）、庫存的點（綠：有貨、橘黃：剩不多、紅：帳上缺貨）
struct BoutiqueItemCard: View {
    let item: MenuItem
    let swatch: Swatch
    let inTicket: Int
    let available: Bool
    let tap: () -> Void
    let minus: () -> Void
    let toggleAvailability: () -> Void

    private var total: Int? { item.totalStock }

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 0) {
                BoutiqueImage(item: item, swatch: swatch, dot: 26)
                    .frame(height: 124)
                    .overlay(alignment: .topTrailing) {
                        if inTicket > 0 {
                            Text("\(inTicket)")
                                .font(.brand(13, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.onAccent)
                                .frame(minWidth: 24, minHeight: 24)
                                .background(Theme.accent, in: .circle)
                                .padding(10)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let sizes = VariantPanel.sizeRange(of: item) {
                            Text(sizes)
                                .font(.brand(11, .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.surface.opacity(0.9), in: .capsule)
                                .overlay { Capsule().strokeBorder(Theme.hair) }
                                .padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(VariantPanel.summary(of: item))
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(priceText)
                            .font(.brand(15.5, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 4)
                        stock
                    }
                    .padding(.top, 3)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(inTicket > 0 ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: inTicket > 0 ? 1.5 : 1)
            }
            .opacity(available ? 1 : 0.5)
        }
        .buttonStyle(PressScale(scale: 0.97))
        .animation(Motion.spring, value: inTicket)
        .contextMenu {
            if inTicket > 0 {
                Button("少一件", systemImage: "minus") { minus() }
            }
            Button(available ? "標示賣完" : "恢復供應", systemImage: available ? "nosign" : "checkmark") { toggleAvailability() }
        }
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var stock: some View {
        if !available {
            StatusBadge("賣完", tone: .danger)
        } else if let total {
            HStack(spacing: 5) {
                Circle()
                    .fill(stockColor(total))
                    .frame(width: 6, height: 6)
                Text(total > 0 ? "\(total)" : "缺貨")
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 ? Theme.muted : Theme.warningFG)
            }
        }
    }

    private func stockColor(_ n: Int) -> Color {
        if n <= 0 { return Theme.dangerFG }
        if n <= 5 { return Theme.warningFG }
        return Theme.live
    }

    private var priceText: String {
        if let from = VariantPanel.startingPrice(of: item) { return "\(from.short) 起" }
        return item.price(of: item.activeVariants.first).short
    }

    private var accessibilityText: String {
        var parts = [item.name, priceText, VariantPanel.summary(of: item)]
        if let total { parts.append(total > 0 ? "庫存 \(total)" : "帳上缺貨") }
        if !available { parts.append("賣完") }
        if inTicket > 0 { parts.append("已點 \(inTicket)") }
        return parts.joined(separator: "，")
    }
}

/// 剛結帳的那一筆（2 分鐘內）：金額、找零（補印明細在右欄）
struct LastSaleStrip: View {
    @Environment(POSModel.self) private var model
    let sale: SaleRecord

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(Theme.live).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("上一筆 \(sale.number)・\(sale.total.formatted)")
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.onInverse)
                Text(sale.invoice.map { "發票 \($0.display)・\($0.buyer.summary)" } ?? "沒有開發票")
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.inverseMuted)
            }
            Spacer()
            if model.lastChange.cents > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("找零")
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.inverseMuted)
                    Text(model.lastChange.formatted)
                        .font(.brand(26, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.inverse)
        .transition(.move(edge: .bottom))
    }
}
