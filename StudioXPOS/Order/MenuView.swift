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
    /// 換分類時新的品項從哪一邊推進來（左右滑、點分類）
    @State private var pushFrom: Edge = .trailing
    /// 左右滑換分類時，品項跟著手指走的距離（拖的時候只有品項那一層重畫）
    @State private var swipeShift = SwipeShift()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 6)
            // 規格（顏色、尺寸）與加料（甜度、冰塊）：浮在菜單上的一張卡，不佔滿整區（菜單還看得到）；點卡外面＝不加了
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if query.isEmpty {
                            categories
                        }
                        SwipeShifted(shift: swipeShift) {
                            items
                        }
                    }
                    .padding(.horizontal, 24)
                    // 第一排的選取框（分類方塊的框畫在方塊外 4 點）、品項卡的框與數量圓點：ScrollView 會切掉邊界外的，
                    // 上面留 8 點才不會被切（頁首下面的間距跟著少 8，看起來一樣）
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                // 左右滑換分類（搜尋中、客製的卡開著時不換；防誤觸見 CategorySwipe）
                .categorySwipe(model.catalog.categories, current: categoryId, enabled: swipeEnabled, shift: swipeShift) { id in
                    select(id)
                }
                .sensoryFeedback(.selection, trigger: categoryId)
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
        // 卡片的字級（每台自己選）
        .environment(\.menuText, model.settings.menuText)
        .animation(Motion.ease, value: model.modifierItem)
        .animation(Motion.ease, value: model.variantItem)
        // 結帳櫃台：手機送來結帳的單（還沒開單時在右欄，大鍵「去結帳」）
        .onAppear {
            if categoryId == nil { categoryId = model.catalog.categories.first?.id }
        }
    }

    private var swipeEnabled: Bool {
        query.isEmpty && model.variantItem == nil && model.modifierItem == nil
    }

    /// 換分類：新的品項從對的那一邊推進來
    private func select(_ id: String) {
        guard id != categoryId else { return }
        pushFrom = CategorySwipe.edge(from: categoryId, to: id, in: model.catalog.categories)
        withAnimation(Motion.spring) { categoryId = id }
        model.touch()
    }

    private func closeCustomize() {
        model.variantItem = nil
        model.modifierItem = nil
    }

    // MARK: 上面

    /// 頁首：現在看的分類｜搜尋。自訂品項、掃條碼、開新單在右欄（單子的動作）；內用／外帶／外送在單子的頁首
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            // 單子的名字在中間那一欄已經有了：這裡只寫現在看的是哪一類（省下一整行給品項）
            Group {
                if !query.isEmpty {
                    Eyebrow("搜尋「\(query)」")
                } else if let c = categoryId.flatMap({ model.catalog.category($0) }) {
                    Eyebrow("\(c.name)・\(model.catalog.items(in: c.id).count) 項")
                } else {
                    Eyebrow("點餐")
                }
            }
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 12)
            // 菜單的字大小（每台自己選；設定 → 外觀與安全也能改）
            MenuTextSizeMenu()
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
                    select(c.id)
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
            // 名字都很短（小吃、飲料）而且品項多：卡片小一點、一排放多一點
            let dense = list.count >= 8 && list.allSatisfy { $0.name.count <= 5 }
            VStack(alignment: .leading, spacing: 12) {
                // 字大了卡片跟著變寬（一排少放一點，名字才不會被切掉）
                let k = model.settings.menuText.space
                LazyVGrid(columns: [GridItem(.adaptive(minimum: (dense ? 112 : 150) * k, maximum: (dense ? 190 : 240) * k),
                                             spacing: dense ? 10 : 12)],
                          spacing: dense ? 10 : 12) {
                    ForEach(list) { item in
                        if item.hasVariants && VariantPanel.isSimple(item) {
                            // 小吃的兩種價錢：價錢就是卡上的鍵，點了直接加
                            PriceGroupCard(item: item, swatch: model.catalog.category(item.categoryId)?.swatch ?? .sand,
                                           available: model.isAvailable(item), compact: dense) {
                                decrement(item)
                            } toggleAvailability: {
                                model.toggleAvailability(item)
                            }
                        } else if item.hasVariants {
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
                                     hasOptions: !item.modifierGroupIds.isEmpty, multiplier: keypad.multiplier, compact: dense) {
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
            // 換分類：整區從左右推進來（左右滑、點分類）
            .id(query.isEmpty ? (categoryId ?? "all") : "search")
            .transition(.push(from: pushFrom))
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
            // 一行就好：分類名＋幾項（省下高度給品項）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Theme.tileInk.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                Text(category.name)
                    .font(.brand(17, .semibold))
                    .foregroundStyle(Theme.tileInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tileInkMuted)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Theme.swatch(category.swatch), in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: selected ? 2.5 : 0)
                    .padding(-4)
            }
        }
        // 選到、按下都不縮放：一排分類的位置要穩
        .buttonStyle(PressTint())
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
    /// 小一點的卡（名字短、品項多的菜單）
    var compact = false
    let tap: () -> Void
    let minus: () -> Void
    let toggleAvailability: () -> Void
    /// 菜單的字級（設定裡選；卡片跟著變大）
    @Environment(\.menuText) private var text

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.swatch(swatch))
                    .frame(width: 22, height: 4)
                Text(item.name)
                    .font(text.font(16, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta {
                    HStack(spacing: 5) {
                        HeroIcon(meta.icon, size: 13 * text.scale)
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
                    .font(text.font(12, .medium))
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(priceText)
                        .font(text.font(15, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                    Spacer()
                    if !available {
                        StatusBadge("賣完", tone: .danger)
                    } else if item.hasVariants {
                        Text("選規格")
                            .font(text.font(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    } else if hasOptions {
                        Text("可選")
                            .font(text.font(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    } else if let m = multiplier, m > 1 {
                        Text("+\(m)")
                            .font(text.font(12, .semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                }
                // 「賣完」的標籤比價錢高一點：這一行固定高，標示賣完卡片也不會變高
                .frame(minHeight: 21 * text.scale)
            }
            .padding(compact ? 11 : 14)
            .frame(maxWidth: .infinity, minHeight: (compact ? 88 : 112) * text.space, alignment: .topLeading)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(inTicket > 0 ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: inTicket > 0 ? 1.5 : 1)
            }
            // 點了幾份：疊在右上角（不佔版面，點了卡片的大小、裡面的字都不會動）
            .overlay(alignment: .topTrailing) {
                if inTicket > 0 {
                    CountBadge(count: inTicket, size: text.badge)
                        .offset(x: 6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .opacity(available ? 1 : 0.5)
        }
        // 按下不縮放（位置、大小要穩，手會記住）
        .buttonStyle(PressTint())
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
        // 小吃的兩種價錢（黃毛丫頭的鴨胸 140／150）：直接寫出來
        if item.hasVariants && VariantPanel.isSimple(item) {
            let prices = item.activeVariants.map { item.price(of: $0).plain }.joined(separator: "／")
            return Meta(icon: "tag", text: [prices, portion].compactMap { $0 }.joined(separator: "・"))
        }
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
            return portion.map { Meta(icon: "cube", text: $0) }
        }
    }

    /// 份量（「3入」「1串」「5片」）：單位裡有數字才寫（「份」「杯」不用寫）
    private var portion: String? {
        item.unit.contains(where: \.isNumber) ? item.unit : nil
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

/// 卡片、價錢鍵右上角的「點了幾份」：疊在角上、不佔版面（點了卡片大小不變）；外圈一圈底色，和卡片的框分開
struct CountBadge: View {
    let count: Int
    var size: CGFloat = 24

    var body: some View {
        Text("\(count)")
            .font(.brand(size * 0.54, .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, size * 0.25)
            .frame(minWidth: size, minHeight: size)
            .background(Theme.accent, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.page, lineWidth: 2) }
            .fixedSize()
            .accessibilityHidden(true)
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
    @Environment(\.menuText) private var text

    private var total: Int? { item.totalStock }

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 0) {
                BoutiqueImage(item: item, swatch: swatch, dot: 26)
                    .frame(height: 124)
                    .overlay(alignment: .topTrailing) {
                        if inTicket > 0 {
                            CountBadge(count: inTicket, size: text.badge)
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
                        .font(text.font(15.5, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(VariantPanel.summary(of: item))
                        .font(text.font(12, .medium))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(priceText)
                            .font(text.font(15.5, .semibold))
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
        .buttonStyle(PressTint())
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
                    .font(text.font(12, .medium))
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
                // 外帶叫號的店不寫單號（右邊大大的取餐號碼才是客人認的）
                Text(model.hidesSaleNumber(sale) ? "上一筆 \(sale.total.formatted)" : "上一筆 \(sale.number)・\(sale.total.formatted)")
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.onInverse)
                Text(sale.invoice.map { "發票 \($0.display)・\($0.buyer.summary)" } ?? "沒有開發票")
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.inverseMuted)
            }
            Spacer()
            // 外帶叫號：取餐號碼最大（客人等一下看叫號螢幕就是這個號碼）
            if let n = model.state.sales[sale.ticketId]?.queueNumber ?? sale.queueNumber {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("取餐號碼")
                        .font(.brand(12, .medium))
                        .foregroundStyle(Theme.inverseMuted)
                    Text("\(n) 號")
                        .font(.brand(26, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onInverse)
                }
            }
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
