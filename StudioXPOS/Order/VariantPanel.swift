import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 服飾：選顏色、尺寸（在工作區裡打開、不是跳出來的視窗：右側鍵盤一樣可以打數量）。
///
///   商品照（沒有照片就是這款的色票）＋名字、價格；下面是尺寸表：每一列是一個顏色（真的色票），
///   每一格是那個尺寸的大顆膠囊，小字是這家店的庫存（剩 1–2 件橘黃、帳上沒有的劃掉——照樣可以點，數字可能還沒更新）。
///   掃吊牌條碼直接加那個規格，不會打開這張卡。
///
///   左邊選、右邊做：表在左邊；「加入 NT$…」是右欄最下面的大鍵，數量在右欄（打開前在鍵盤打的數字就是數量），右欄的 × 關掉這張卡。
struct VariantPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let item: MenuItem

    @State private var selectedId: String? = nil
    @State private var quantity = 1
    @State private var adding = false

    private var selected: ItemVariant? { item.variant(selectedId) }
    private var unit: Money { item.price(of: selected) }
    private var swatch: Swatch { model.catalog.category(item.categoryId)?.swatch ?? .sand }

    private var problem: String? {
        guard let v = selected else { return "先選一個規格" }
        if !v.isAvailable { return "\(v.label) 今天不能賣" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heading

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Eyebrow(Self.dimensionTitle(of: item))
                            Text(selected == nil ? "點一格選規格" : "小字是這家店的庫存")
                                .font(.brand(12, .medium))
                                .foregroundStyle(selected == nil ? Theme.accentText : Theme.muted)
                        }
                        VariantMatrix(item: item, selectedId: selectedId) { v in
                            withAnimation(Motion.spring) { selectedId = v.id }
                            model.touch()
                        }
                        legend
                    }

                    selection
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.page)
        .dockSelection(dock)
        .onAppear { reset() }
        .onChange(of: item.id) { _, _ in reset() }
    }

    // MARK: 右欄

    /// 待機時在鍵盤打的數字就是數量；沒打就用這張卡的數量
    private var currentQuantity: Int { keypad.multiplier ?? quantity }

    /// 右欄：這一款（選了哪個規格、庫存）；大鍵＝加入；動作鍵＝數量
    private var dock: DockSelection {
        let q = currentQuantity
        let addAction = POSAction(selected == nil ? "先選規格" : "加入 \((unit * q).formatted)", icon: "plus-circle",
                                  enabled: problem == nil && !adding) { add() }
        var actions = [POSAction("數量 \(q)", icon: "calculator") { askQuantity() }]
        // 鍵盤上打了數字時，右欄最下面那顆會變成「清除／品號」：加入也放在動作鍵
        if !keypad.idle.digits.isEmpty && selected != nil { actions.insert(addAction, at: 0) }
        return DockSelection(id: "variant-\(item.id)", kind: "規格", title: item.name, detail: dockDetail(q),
                             badge: dockBadge(q), primary: addAction, accent: true, actions: actions,
                             clear: { model.variantItem = nil })
    }

    private func dockDetail(_ q: Int) -> String {
        guard let v = selected else { return "\(Self.summary(of: item))・在左邊的表選顏色尺寸" }
        return "\(v.label)・×\(q)・\(stockLine(v))"
    }

    private func dockBadge(_ q: Int) -> DockBadge? {
        guard let v = selected else { return nil }
        if !v.isAvailable { return DockBadge("停售", tone: .danger) }
        guard let s = v.stock else { return nil }
        if s <= 0 { return DockBadge("帳上沒庫存", tone: .warning) }
        if s < q { return DockBadge("帳上只有 \(s) 件", tone: .warning) }
        return s <= 2 ? DockBadge("剩 \(s) 件", tone: .warning) : nil
    }

    private func askQuantity() {
        let q = currentQuantity
        keypad.clearIdle()
        Task {
            if let n = await keypad.askNumber(.quantity(name: item.name, current: q)) { quantity = max(n, 1) }
        }
    }

    // MARK: 上面：照片、名字、價格

    private var heading: some View {
        HStack(alignment: .top, spacing: 18) {
            BoutiqueImage(item: item, swatch: swatch, dot: 22)
                .frame(width: 120, height: 150)
                .clipShape(.rect(cornerRadius: Metric.radiusLg, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(model.catalog.category(item.categoryId)?.name ?? "")
                Headline(item.name, role: .h2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.priceRange(of: item))
                    .font(.brand(20, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 10) {
                    VariantSwatchStrip(item: item, size: 16)
                    Text(Self.summary(of: item))
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.muted)
                    if let total = item.totalStock {
                        StatusBadge(total > 0 ? "庫存 \(total)" : "帳上全部缺貨", tone: total > 0 ? .neutral : .warning)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Text("2")
                    .font(.brand(11, .semibold))
                    .foregroundStyle(Theme.warningFG)
                Text("剩 1–2 件")
            }
            HStack(spacing: 5) {
                Text("M")
                    .font(.brand(11, .semibold))
                    .strikethrough()
                    .foregroundStyle(Theme.faint)
                Text("帳上沒有，照樣可以賣")
            }
            HStack(spacing: 5) {
                Text("—")
                    .font(.brand(11, .semibold))
                Text("沒有管庫存")
            }
        }
        .font(.brand(11.5, .regular))
        .foregroundStyle(Theme.muted)
        .accessibilityElement(children: .combine)
    }

    // MARK: 選到的規格

    @ViewBuilder
    private var selection: some View {
        if let v = selected {
            HStack(alignment: .center, spacing: 14) {
                if let c = Self.colorValue(of: v, in: item) {
                    ColorSwatchDot(color: Self.swatchFill(for: c), size: 34, selected: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.label)
                        .font(.brand(20, .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(stockLine(v))
                        .font(.brand(13, .regular))
                        .foregroundStyle(stockTone(v).foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("×\(currentQuantity)")
                        .font(.brand(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    MoneyText(money: item.price(of: v) * currentQuantity, role: .number)
                }
            }
            .panel(padding: 16)
            .id(v.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity))
        }
    }

    private func stockLine(_ v: ItemVariant) -> String {
        if !v.isAvailable { return "今天停售" }
        let sku = v.sku.map { "・\($0)" } ?? ""
        guard let s = v.stock else { return "沒有管庫存\(sku)" }
        if s <= 0 { return "帳上 0 件：數字可能還沒更新，照樣可以加入\(sku)" }
        return "這家店還有 \(s) 件\(sku)"
    }

    private func stockTone(_ v: ItemVariant) -> Tone {
        if !v.isAvailable { return .danger }
        if let s = v.stock, s <= 0 { return .warning }
        return .neutral
    }

    // MARK: 動作

    private func reset() {
        quantity = keypad.takeQuantity()
        adding = false
        // 只有一個能賣的規格就直接選好
        let open = item.activeVariants.filter(\.isAvailable)
        selectedId = open.count == 1 ? open.first?.id : nil
    }

    private func add() {
        guard problem == nil, !adding, let v = selected else { return }
        adding = true
        let q = currentQuantity
        keypad.clearIdle()
        let it = item
        Task {
            // 課程卡、儲值要記在會員身上（服飾通常不會，但規則一樣）
            guard await model.ensureMemberIfNeeded(for: it) else {
                adding = false
                return
            }
            model.add(it, variant: v, quantity: q, modifiers: [], note: "")
            adding = false
            if model.variantItem?.id == it.id { model.variantItem = nil }
        }
    }
}

// MARK: - 規格的文字與色票（點餐的品項卡、單子也用）

extension VariantPanel {
    /// 「顏色 × 尺寸」
    static func dimensionTitle(of item: MenuItem) -> String {
        let names = (item.optionNames ?? []).filter { !$0.isEmpty }
        return names.isEmpty ? "規格" : names.joined(separator: " × ")
    }

    /// 規格有幾個維度
    static func dimensions(of item: MenuItem) -> Int {
        max(item.optionNames?.count ?? 0, item.activeVariants.map(\.options.count).max() ?? 0)
    }

    /// 「6 色 × 5 尺寸」「5 尺寸」「12 款」
    static func summary(of item: MenuItem) -> String {
        let names = item.optionNames ?? []
        let dims = dimensions(of: item)
        guard dims > 0 else { return "\(item.activeVariants.count) 款" }
        let parts = (0..<min(dims, 3)).map { i -> String in
            let name = i < names.count ? names[i] : ""
            return "\(item.optionValues(i).count) \(unitWord(name))"
        }
        return parts.joined(separator: " × ")
    }

    private static func unitWord(_ name: String) -> String {
        if isColorName(name) { return "色" }
        return name.isEmpty ? "種" : name
    }

    private static func isColorName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("色") || n.contains("color") || n.contains("colour")
    }

    /// 哪一個維度是顏色（名字有「色」，或值是顏色字）；沒有就是 nil
    static func colorDimension(of item: MenuItem) -> Int? {
        let names = item.optionNames ?? []
        if let i = names.firstIndex(where: { isColorName($0) }) { return i }
        for i in 0..<dimensions(of: item) where item.optionValues(i).contains(where: { swatchColor(for: $0) != nil }) {
            return i
        }
        return nil
    }

    /// 這款有哪些顏色（照後台的順序）
    static func colorValues(of item: MenuItem) -> [String] {
        colorDimension(of: item).map { item.optionValues($0) } ?? []
    }

    /// 這個規格的顏色（「黑・M」→「黑」）
    static func colorValue(of v: ItemVariant, in item: MenuItem) -> String? {
        guard let d = colorDimension(of: item), d < v.options.count else { return nil }
        return v.options[d]
    }

    /// 尺寸的範圍（「S – XL」）：顏色以外的那個維度的第一個到最後一個
    static func sizeRange(of item: MenuItem) -> String? {
        let dims = dimensions(of: item)
        let color = colorDimension(of: item)
        guard let d = (0..<dims).first(where: { $0 != color }) else { return nil }
        let values = item.optionValues(d)
        guard let first = values.first, let last = values.last else { return nil }
        return values.count == 1 ? first : "\(first) – \(last)"
    }

    /// 「NT$1,280」或「NT$1,280 – 1,580」（規格的價格不一樣）
    static func priceRange(of item: MenuItem) -> String {
        let prices = item.activeVariants.map { item.price(of: $0) }
        guard let lo = prices.min(), let hi = prices.max(), lo != hi else { return item.price(of: item.activeVariants.first).formatted }
        return "\(lo.formatted) – \(hi.plain)"
    }

    /// 最低價（品項卡上的「$1,280 起」）；規格都一樣價就是 nil
    static func startingPrice(of item: MenuItem) -> Money? {
        let prices = item.activeVariants.map { item.price(of: $0) }
        guard let lo = prices.min(), let hi = prices.max(), lo != hi else { return nil }
        return lo
    }

    /// 對不到顏色字時的中性色票
    static let neutralSwatch = Color(light: 0xD8D3C9, dark: 0x4A4844)

    /// 色票：顏色字對得到就用那個顏色，對不到用中性色
    static func swatchFill(for value: String) -> Color {
        swatchColor(for: value) ?? neutralSwatch
    }

    /// 常見的顏色字 → 色票（「黑」「霧藍」「燕麥」「卡其」；對不到是 nil）
    static func swatchColor(for value: String) -> Color? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty else { return nil }
        if let hex = colorWords[v] { return Color(hex: hex) }
        // 「霧霾藍」「深卡其」：找最長的顏色字；一樣長取比較後面的（中文的主色在後面：灰藍＝藍）
        var best: String? = nil
        var bestEnd = v.startIndex
        for key in colorWords.keys {
            guard let r = v.range(of: key, options: .backwards) else { continue }
            if let b = best {
                if key.count > b.count || (key.count == b.count && r.upperBound > bestEnd) {
                    best = key
                    bestEnd = r.upperBound
                }
            } else {
                best = key
                bestEnd = r.upperBound
            }
        }
        guard let key = best, let hex = colorWords[key] else { return nil }
        return Color(hex: hex)
    }

    private static let colorWords: [String: UInt32] = [
        "黑": 0x1E1E1C, "白": 0xF7F6F2, "米白": 0xEFE8DA, "象牙白": 0xF3EDDD, "奶油": 0xF2E6C9, "米": 0xE6DBC4, "杏": 0xE3CBA8,
        "燕麥": 0xD8C9AE, "沙": 0xD9C7A7, "奶茶": 0xCDB09A, "卡其": 0xC2AE86, "駝": 0xB38B5D, "焦糖": 0xB86B2E, "摩卡": 0x8B6A55,
        "大地": 0x9C7A57, "咖啡": 0x6F4E37, "咖": 0x7A5A43, "棕": 0x7B5B42, "可可": 0x5C4033,
        "灰": 0x9B9B98, "淺灰": 0xCFCFCB, "麻灰": 0xB3B1AC, "深灰": 0x555553, "炭灰": 0x3E3E3C, "鐵灰": 0x4A4C50,
        "藍": 0x3C5DA8, "淺藍": 0xA8C8E8, "天藍": 0x87BDE6, "水藍": 0x9ED0EA, "寶藍": 0x2346A0, "深藍": 0x1F2C4D, "藏青": 0x1E2A44,
        "海軍藍": 0x1F2A44, "霧藍": 0x8EA3B8, "丹寧": 0x4C6A92, "牛仔": 0x4C6A92,
        "綠": 0x4E7D4A, "軍綠": 0x5A5E3A, "橄欖": 0x6B6B3A, "墨綠": 0x2E4A3A, "森林綠": 0x2F5D3A, "薄荷": 0xB5E3CF, "抹茶": 0x9DAF6B,
        "紅": 0xC23B33, "酒紅": 0x7A1F2B, "磚紅": 0xA9483A, "粉": 0xF1B7C5, "粉紅": 0xF1B7C5, "玫瑰": 0xD9738C, "桃紅": 0xE0507A,
        "黃": 0xE9C84A, "鵝黃": 0xF6E3A0, "芥末": 0xC9A23A, "橘": 0xE97C2E, "橙": 0xE97C2E,
        "紫": 0x7E5BA8, "芋": 0xB9A2C8, "薰衣草": 0xC5B5E3, "金": 0xC9A54B, "銀": 0xC5C5C2,
        "black": 0x1E1E1C, "white": 0xF7F6F2, "ivory": 0xF3EDDD, "cream": 0xF2E6C9, "oat": 0xD8C9AE, "beige": 0xE6DBC4,
        "sand": 0xD9C7A7, "khaki": 0xC2AE86, "camel": 0xB38B5D, "brown": 0x7B5B42, "grey": 0x9B9B98, "gray": 0x9B9B98,
        "charcoal": 0x3E3E3C, "navy": 0x1F2A44, "blue": 0x3C5DA8, "denim": 0x4C6A92, "green": 0x4E7D4A, "olive": 0x6B6B3A,
        "red": 0xC23B33, "burgundy": 0x7A1F2B, "wine": 0x7A1F2B, "pink": 0xF1B7C5, "yellow": 0xE9C84A, "orange": 0xE97C2E,
        "purple": 0x7E5BA8, "gold": 0xC9A54B, "silver": 0xC5C5C2,
    ]
}

// MARK: - 尺寸表

/// 尺寸表：每一列是一個顏色（色票＋名字，點了換成那個顏色），每一格是一個尺寸的大顆膠囊——
/// 尺寸大字、庫存小字（剩 1–2 件橘黃、帳上沒有劃掉）、規格自己的加價；選到的那一格有品牌橘的框、彈一下。
/// 一個維度（或三個以上）排成一排膠囊。點餐的規格卡用大的，單子上換尺寸用小的（compact）
struct VariantMatrix: View {
    let item: MenuItem
    let selectedId: String?
    var compact = false
    let select: (ItemVariant) -> Void

    private var selected: ItemVariant? { item.variant(selectedId) }
    /// 列：顏色那個維度（沒有顏色就第一個）；欄：另一個
    private var rowDim: Int { VariantPanel.colorDimension(of: item) ?? 0 }
    private var colDim: Int { rowDim == 0 ? 1 : 0 }
    private var rows: [String] { item.optionValues(rowDim) }
    private var columns: [String] { item.optionValues(colDim) }
    private var rowsAreColors: Bool { VariantPanel.colorDimension(of: item) == rowDim }

    private var isGrid: Bool {
        VariantPanel.dimensions(of: item) == 2 && !rows.isEmpty && !columns.isEmpty
    }

    private var cellWidth: CGFloat { compact ? 44 : 60 }
    private var cellHeight: CGFloat { compact ? 38 : 56 }

    var body: some View {
        Group {
            if isGrid {
                // 尺寸太多放不下就左右滑
                ViewThatFits(in: .horizontal) {
                    grid
                    ScrollView(.horizontal) {
                        grid.fixedSize(horizontal: true, vertical: false)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                FlowLayout(spacing: compact ? 6 : 10, rowSpacing: compact ? 6 : 10) {
                    ForEach(item.activeVariants) { v in
                        pill(v)
                    }
                }
                .padding(4)
            }
        }
        .animation(Motion.spring, value: selectedId)
    }

    // MARK: 表格

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 6 : 8, verticalSpacing: compact ? 6 : 10) {
            ForEach(rows, id: \.self) { r in
                GridRow {
                    rowLabel(r)
                    ForEach(columns, id: \.self) { c in
                        slot(item.variant(matching: rowDim == 0 ? [r, c] : [c, r]), title: c)
                    }
                }
            }
        }
        // 選到的那格會放大一點、有外框：留一點邊
        .padding(compact ? 3 : 5)
    }

    private func rowLabel(_ value: String) -> some View {
        let on = option(selected, rowDim) == value
        return Button {
            selectRow(value)
        } label: {
            HStack(spacing: compact ? 7 : 10) {
                if rowsAreColors {
                    ColorSwatchDot(color: VariantPanel.swatchFill(for: value), size: compact ? 14 : 22, selected: on)
                }
                Text(value)
                    .font(.brand(compact ? 12.5 : 15, on ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(on ? Theme.ink : Theme.ink2)
            .padding(.trailing, compact ? 4 : 10)
            .frame(minHeight: cellHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowsAreColors ? "顏色 \(value)" : value)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 點顏色：同一個尺寸換成這個顏色；沒有這個尺寸就選這個顏色第一個有貨的
    private func selectRow(_ value: String) {
        let inRow = item.activeVariants.filter { option($0, rowDim) == value && $0.isAvailable }
        if let size = option(selected, colDim), let v = inRow.first(where: { option($0, colDim) == size }) {
            select(v)
        } else if let v = inRow.first(where: { ($0.stock ?? 1) > 0 }) ?? inRow.first {
            select(v)
        }
    }

    @ViewBuilder
    private func slot(_ variant: ItemVariant?, title: String) -> some View {
        if let v = variant {
            capsule(v, title: title, swatch: nil)
        } else {
            // 沒有這個組合（這個顏色沒有 XL）
            Capsule()
                .strokeBorder(Theme.hair, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(minWidth: cellWidth, maxWidth: .infinity, minHeight: cellHeight)
                .overlay {
                    Text(title)
                        .font(.brand(compact ? 12 : 14, .medium))
                        .foregroundStyle(Theme.faint.opacity(0.7))
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: 一排膠囊（一個維度）

    private func pill(_ v: ItemVariant) -> some View {
        let color = VariantPanel.colorValue(of: v, in: item)
        return capsule(v, title: v.label, swatch: color.map { VariantPanel.swatchFill(for: $0) })
    }

    // MARK: 一格

    private func capsule(_ v: ItemVariant, title: String, swatch: Color?) -> some View {
        let on = v.id == selectedId
        let soldOut = (v.stock ?? 1) <= 0
        let low = (v.stock ?? 0) > 0 && (v.stock ?? 0) <= 2
        let dim = soldOut || !v.isAvailable
        let stockInk: Color = low ? Theme.warningFG : (dim ? Theme.faint : Theme.muted)
        let fill: Color = on ? Theme.accentSoft : (dim ? Theme.page : Theme.surface)
        return Button {
            select(v)
        } label: {
            HStack(spacing: 7) {
                if let swatch {
                    ColorSwatchDot(color: swatch, size: compact ? 12 : 16, selected: false)
                }
                VStack(spacing: compact ? 0 : 2) {
                    Text(title)
                        .font(.brand(compact ? 13 : 16, .semibold))
                        .strikethrough(dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(dim ? Theme.faint : Theme.ink)
                    HStack(spacing: 4) {
                        Text(v.isAvailable ? Self.stockText(v) : "停售")
                            .foregroundStyle(stockInk)
                        if !compact, let d = Self.deltaText(v, item: item) {
                            Text(d)
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                    .font(.brand(compact ? 9.5 : 10.5, .semibold))
                    .monospacedDigit()
                }
            }
            .padding(.horizontal, compact ? 8 : 14)
            .frame(minWidth: cellWidth, maxWidth: swatch == nil ? .infinity : nil, minHeight: cellHeight)
            .background(fill, in: .capsule)
            .overlay {
                Capsule().strokeBorder(on ? Theme.accent : Theme.line, lineWidth: on ? 2 : 1)
            }
            .scaleEffect(on ? 1.05 : 1)
            .shadow(color: on ? Theme.accent.opacity(0.18) : .clear, radius: 8, y: 3)
            .contentShape(.capsule)
        }
        .buttonStyle(PressScale(scale: 0.94))
        .disabled(!v.isAvailable)
        .accessibilityLabel(Self.accessibility(v, item: item))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 文字

    private func option(_ v: ItemVariant?, _ i: Int) -> String? {
        guard let v, i < v.options.count else { return nil }
        return v.options[i]
    }

    /// 「3」「0」「—」（沒有管庫存）
    static func stockText(_ v: ItemVariant) -> String {
        guard let s = v.stock else { return "—" }
        return String(max(s, 0))
    }

    /// 規格自己的價格和品項不一樣：「+200」「−100」
    static func deltaText(_ v: ItemVariant, item: MenuItem) -> String? {
        guard let p = v.price, p != item.price else { return nil }
        let d = p - item.price
        return (d.isNegative ? "−" : "+") + Money(cents: abs(d.cents)).plain
    }

    static func accessibility(_ v: ItemVariant, item: MenuItem) -> String {
        var parts = [v.label, item.price(of: v).formatted]
        if !v.isAvailable {
            parts.append("停售")
        } else if let s = v.stock {
            parts.append(s > 0 ? "庫存 \(s) 件" : "帳上沒有庫存")
        } else {
            parts.append("沒有管庫存")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 色票、商品照

/// 一顆色票：顏色＋細框；選到的外面一圈品牌橘
struct ColorSwatchDot: View {
    let color: Color
    var size: CGFloat = 18
    var selected = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(Theme.line, lineWidth: 1) }
            .padding(selected ? 2.5 : 0)
            .overlay {
                if selected { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
            }
            .accessibilityHidden(true)
    }
}

/// 這款有哪些顏色：一排疊在一起的色票（最多 5 顆，多的寫 +N）
struct VariantSwatchStrip: View {
    let item: MenuItem
    var size: CGFloat = 16
    var limit = 5

    var body: some View {
        let colors = VariantPanel.colorValues(of: item)
        HStack(spacing: -size * 0.28) {
            ForEach(Array(colors.prefix(limit).enumerated()), id: \.offset) { i, value in
                Circle()
                    .fill(VariantPanel.swatchFill(for: value))
                    .frame(width: size, height: size)
                    .overlay { Circle().strokeBorder(Theme.line, lineWidth: 1) }
                    .background { Circle().fill(Theme.surface).padding(-max(1.5, size * 0.09)) }
                    .zIndex(Double(limit - i))
            }
            if colors.count > limit {
                Text("+\(colors.count - limit)")
                    .font(.brand(max(size * 0.42, 9), .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .frame(width: size, height: size)
                    .background(Theme.surface, in: .circle)
                    .overlay { Circle().strokeBorder(Theme.line, lineWidth: 1) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(colors.joined(separator: "、"))
    }
}

/// 商品照（後台有 imageURL）；沒有照片、還沒載到就是分類色的底＋這款的色票，像選物店的目錄
struct BoutiqueImage: View {
    let item: MenuItem
    var swatch: Swatch = .sand
    var dot: CGFloat = 24

    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    LinearGradient(colors: [Theme.swatch(swatch).opacity(0.62), Theme.swatch(swatch).opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if VariantPanel.colorValues(of: item).isEmpty {
                        Text(String(item.name.prefix(1)))
                            .font(.serif(dot * 2))
                            .foregroundStyle(Theme.tileInk.opacity(0.45))
                    } else {
                        VariantSwatchStrip(item: item, size: dot)
                    }
                    if let s = item.imageURL, let url = URL(string: s) {
                        AsyncImage(url: url, transaction: Transaction(animation: Motion.ease)) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .transition(.opacity)
                            }
                        }
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }
}
