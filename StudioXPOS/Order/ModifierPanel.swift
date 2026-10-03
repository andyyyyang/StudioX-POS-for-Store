import POSCore
import SwiftUI

/// 選甜度、冰塊、加料（在工作區裡打開、不是跳出來的視窗：右側鍵盤一樣可以用來改數量）
struct ModifierPanel: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let item: MenuItem

    @State private var picked: [String: [String]] = [:]
    @State private var quantity = 1
    @State private var note = ""
    @State private var price: Money?

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
                        Button {
                            model.modifierItem = nil
                        } label: {
                            HeroIcon("x-mark", size: 18)
                        }
                        .buttonStyle(SquareIconButtonStyle(size: 44))
                        .accessibilityLabel("關閉")
                        .keyboardShortcut(.cancelAction)
                    }

                    if item.openPrice {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("時價")
                            Button {
                                Task {
                                    if let p = await keypad.askMoney(.openPrice(name: item.name)) { price = p }
                                }
                            } label: {
                                Text(price?.formatted ?? "在右邊輸入價格")
                                    .font(.brand(20, .medium))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.choice(price != nil, height: 56))
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
            }
            .scrollIndicators(.hidden)

            footer
        }
        .background(Theme.page)
        .onAppear(perform: reset)
        .onChange(of: item.id) { _, _ in reset() }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // 數量：− ＋，點數字用右側鍵盤打
            HStack(spacing: 0) {
                Button {
                    quantity = max(quantity - 1, 1)
                } label: {
                    HeroIcon("minus", size: 18).frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
                Button {
                    Task { if let q = await keypad.askNumber(.quantity(name: item.name, current: quantity)) { quantity = max(q, 1) } }
                } label: {
                    Text("\(quantity)")
                        .font(.brand(22, .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 44, minHeight: 52)
                }
                .buttonStyle(.plain)
                Button {
                    quantity = min(quantity + 1, 999)
                } label: {
                    HeroIcon("plus", size: 18).frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.ink)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }

            if let problem {
                Text(problem)
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.warningFG)
            }
            Spacer()
            Button {
                add()
            } label: {
                Text("加入 \((unit * quantity).formatted)")
                    .monospacedDigit()
            }
            .buttonStyle(.brand(.accent, size: .lg, arrow: true))
            .disabled(problem != nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.dock)
        .overlay(alignment: .top) { Rule() }
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
        model.add(item, quantity: quantity, modifiers: applied, note: note.trimmingCharacters(in: .whitespaces), price: price)
        model.modifierItem = nil
    }
}
