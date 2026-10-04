import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 選甜度、冰塊、加料（在工作區裡打開、不是跳出來的視窗：右側鍵盤一樣可以用來改數量）。
/// 左邊選、右邊做：選項在左邊；「加入 NT$…」是右欄最下面的大鍵，數量、時價在右欄，右欄的 × 關掉這張卡
struct ModifierPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let item: MenuItem
    /// iPad：浮在菜單上的卡（CustomizeCard）——高度跟著內容、底色交給卡片
    var card = false

    @State private var picked: [String: [String]] = [:]
    @State private var quantity = 1
    @State private var note = ""
    @State private var price: Money?
    /// 內容的高度（卡片的高度跟著它）
    @State private var contentHeight: CGFloat = 0

    private var groups: [ModifierGroup] { model.catalog.groups(for: item).sorted { $0.sortOrder < $1.sortOrder } }

    private var applied: [AppliedModifier] {
        groups.flatMap { g in
            (picked[g.id] ?? []).compactMap { id in
                g.options.first { $0.id == id }.map { AppliedModifier(groupId: g.id, groupName: g.name, optionId: $0.id, name: $0.name, priceDelta: $0.priceDelta) }
            }
        }
    }

    private var problem: String? {
        if item.openPrice && price == nil { return "請輸入時價" }
        return groups.lazy.compactMap { $0.problem(selected: picked[$0.id] ?? []) }.first
    }

    private var unit: Money { (price ?? item.price) + Money.sum(applied.map(\.priceDelta)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(model.catalog.category(item.categoryId)?.name ?? "")
                            Headline(item.name, role: .h2)
                        }
                        Spacer()
                    }

                    if item.openPrice {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("時價")
                            // 價格在右欄打（「時價…」）；這裡只顯示
                            Text(price?.formatted ?? "在右邊輸入價格")
                                .font(.brand(20, .medium))
                                .monospacedDigit()
                                .foregroundStyle(price == nil ? Theme.accentText : Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .padding(.horizontal, 16)
                                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Metric.radius)
                                        .strokeBorder(price == nil ? Theme.accent.opacity(0.5) : Theme.line)
                                }
                        }
                    }

                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Eyebrow(g.name)
                                Text(rule(g))
                                    .font(.brand(12, .medium))
                                    .foregroundStyle(g.isRequired && (picked[g.id] ?? []).isEmpty ? Theme.accentText : Theme.muted)
                            }
                            FlowLayout(spacing: 10, rowSpacing: 10) {
                                ForEach(g.options) { o in
                                    let on = (picked[g.id] ?? []).contains(o.id)
                                    OptionChip(title: o.name, detail: o.priceDelta.cents != 0 ? "+\(o.priceDelta.plain)" : nil, selected: on, disabled: !o.isAvailable) {
                                        toggle(o, in: g)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("備註")
                        TextField("例如：不要香菜、醬另外放", text: $note)
                            .font(.brand(16, .regular))
                            .padding(14)
                            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                    }
                }
                .padding(24)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: card && contentHeight > 0 ? contentHeight : .infinity)
        }
        .background(card ? Color.clear : Theme.page)
        // 卡片：量好高度再出現（不會先撐滿再縮）
        .opacity(card && contentHeight == 0 ? 0 : 1)
        .dockSelection(dock)
        .onAppear { reset() }
        .onChange(of: item.id) { _, _ in reset() }
    }

    // MARK: 右欄

    /// 待機時在鍵盤打的數字就是數量；沒打就用這張卡的數量
    private var currentQuantity: Int { keypad.multiplier ?? quantity }

    /// 右欄：這個品項（選了什麼）；大鍵＝加入；動作鍵＝數量、時價
    private var dock: DockSelection {
        let q = currentQuantity
        let addAction = POSAction("加入 \((unit * q).formatted)", icon: "plus-circle", enabled: problem == nil) { add() }
        var actions = [POSAction("數量 \(q)", icon: "calculator") { askQuantity() }]
        if item.openPrice {
            actions.append(POSAction(price.map { "時價 \($0.formatted)" } ?? "時價…", icon: "currency-dollar") { askPrice() })
        }
        // 鍵盤上打了數字時，右欄最下面那顆會變成「清除／品號」：加入也放在動作鍵
        if !keypad.idle.digits.isEmpty && problem == nil { actions.insert(addAction, at: 0) }
        let chosen = applied.map(\.name).joined(separator: "・")
        let detail = ["×\(q)", chosen.isEmpty ? nil : chosen, problem].compactMap { $0 }.joined(separator: "・")
        return DockSelection(id: "modifier-\(item.id)", kind: "加料", title: item.name, detail: detail,
                             badge: problem.map { DockBadge($0, tone: .warning) }, primary: addAction, accent: true,
                             actions: actions, clear: { model.modifierItem = nil })
    }

    private func askQuantity() {
        let q = currentQuantity
        keypad.clearIdle()
        Task {
            if let n = await keypad.askNumber(.quantity(name: item.name, current: q)) { quantity = max(n, 1) }
        }
    }

    private func askPrice() {
        Task {
            if let p = await keypad.askMoney(.openPrice(name: item.name)) { price = p }
        }
    }

    private func rule(_ g: ModifierGroup) -> String {
        if g.isRequired && g.isSingleChoice { return "必選" }
        if g.isRequired { return "至少 \(g.minSelect) 項" }
        if g.maxSelect > 1 { return "可選，最多 \(g.maxSelect) 項" }
        if g.maxSelect == 0 { return "可複選" }
        return "可選"
    }

    private func toggle(_ o: ModifierOption, in g: ModifierGroup) {
        var current = picked[g.id] ?? []
        if g.isSingleChoice {
            current = current == [o.id] && !g.isRequired ? [] : [o.id]
        } else if let i = current.firstIndex(of: o.id) {
            current.remove(at: i)
        } else if g.maxSelect == 0 || current.count < g.maxSelect {
            current.append(o.id)
        } else {
            model.show("\(g.name)最多選 \(g.maxSelect) 項", tone: .warning)
            return
        }
        picked[g.id] = current
        model.touch()
    }

    private func reset() {
        picked = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.defaultOptionIds) })
        quantity = keypad.takeQuantity()
        note = ""
        price = nil
        if item.openPrice {
            Task { if let p = await keypad.askMoney(.openPrice(name: item.name)) { price = p } }
        }
    }

    private func add() {
        guard problem == nil else { return }
        let q = currentQuantity
        keypad.clearIdle()
        model.add(item, quantity: q, modifiers: applied, note: note.trimmingCharacters(in: .whitespaces), price: price)
        model.modifierItem = nil
    }
}
