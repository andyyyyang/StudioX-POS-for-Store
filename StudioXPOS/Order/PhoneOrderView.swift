import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 手機的點餐：上面一排分類、下面兩欄品項（大大的、點一下＝加一份）；加料、規格是一張 sheet（和 iPad 同一張卡）。
///
///   ┌ A023                  🔍 ┐
///   │ A2・4 位                  │
///   │ (咖啡) (茶) (早午餐) (甜點)  │  分類
///   │ ┌────────┐ ┌────────┐    │
///   │ │ 拿鐵  2 │ │ 美式    │    │  品項：點一下加一份，有加料、規格的打開 sheet
///   │ └────────┘ └────────┘    │
///   │ [≡ A2・3 項・NT$480   ⌃] │  單子：點開是單子的 sheet（點一行＝選起來，下面出現那一行的動作）
///   │ [⋯] [      送單 3      ]  │  整張單的大鍵（送單／送到結帳櫃台；這支手機能收款時是結帳）
///   └──────────────────────────┘
///
/// 還沒有單：大鍵是「開單」（選一張空桌入座，或外帶）。整張單的動作和 iPad 的單子欄是同一份（看不到的 TicketColumn 交上來）
struct PhoneOrderView: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @Environment(PhoneUI.self) private var ui

    @State private var categoryId: String?
    /// 換分類時新的品項從哪一邊推進來（左右滑、點分類）
    @State private var pushFrom: Edge = .trailing
    /// 左右滑換分類時，品項跟著手指走的距離（拖的時候只有品項那一層重畫）
    @State private var swipeShift = SwipeShift()
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// 「開單」的選擇（空桌、外帶…）
    @State private var opening = false
    @State private var ticketDetent: PresentationDetent = .medium
    /// 叫號卡展開著（平常收成頁首的一顆鍵，畫面留給菜單）
    @AppStorage("phoneQueueCardOpen") private var queueOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // 全外帶的店（叫號用在外帶取餐）：平常收成頁首的一顆鍵；點開才是這張卡（現在叫到幾號、叫下一號）
            if queueOpen {
                PhoneQueueCard()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if query.isEmpty {
                chips
            }
            items
        }
        // 卡片的字級（更多 → 這支手機）
        .environment(\.menuText, model.settings.menuText)
        .background { hiddenTicketColumn }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomStrip }
        .dockSelection(model.selectedTicket == nil ? openPage : nil)
        .dockPanel(isPresented: $opening, title: "開單", subtitle: openSubtitle) {
            openChoices
        }
        // 加料（甜度、冰塊）、規格（顏色 × 尺寸）：和 iPad 同一張卡，「加入」是下面的大鍵。
        // 這一張裡要打數字、選東西：鍵盤與面板從這一張的下面升起來（PhoneDockHost inSheet），不再疊一張 sheet
        .sheet(item: itemBinding) { item in
            PhoneDockHost(isActive: true, inSheet: true) {
                if model.variantItem?.id == item.id {
                    VariantPanel(item: item)
                } else {
                    ModifierPanel(item: item)
                }
            }
            .presentationDetents([.large])
            .phoneSheetStyle(Theme.page)
        }
        .onAppear {
            if categoryId == nil { categoryId = model.catalog.categories.first?.id }
            if ui.openTicketOnArrival {
                ui.openTicketOnArrival = false
                if model.selectedTicket != nil { openTicket() }
            }
        }
        .task { await preselectForScreenshot() }
        .onDisappear {
            ui.ticketOpen = false
            model.modifierItem = nil
            model.variantItem = nil
        }
        .onChange(of: model.selectedTicketId) { _, id in
            if id == nil { ui.ticketOpen = false }
        }
        .onChange(of: model.checkoutTicketId) { _, id in
            if id != nil { ui.ticketOpen = false }
        }
    }

    // MARK: 上面

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                // 開單前「The menu」、開了單是單號與桌名：兩種疊在一起只顯示一種，高度固定——
                // 點了第一個品項（開了單），下面的分類與菜單不會跳
                ZStack(alignment: .leading) {
                    ticketTitle
                        .opacity(model.selectedTicket == nil ? 0 : 1)
                        .accessibilityHidden(model.selectedTicket == nil)
                    menuTitle
                        .opacity(model.selectedTicket == nil ? 1 : 0)
                        .accessibilityHidden(model.selectedTicket != nil)
                }
                Spacer(minLength: 8)
                PhoneQueueButton(open: $queueOpen)
                scanButton
                Button {
                    withAnimation(Motion.fast) {
                        searching.toggle()
                        if !searching { query = "" }
                    }
                    searchFocused = searching
                } label: {
                    HeroIcon(searching ? "x-mark" : "magnifying-glass", size: 18)
                }
                .buttonStyle(SquareIconButtonStyle(size: 44))
                .accessibilityLabel(searching ? "關掉搜尋" : "搜尋品項")
            }
            if searching {
                HStack(spacing: 8) {
                    HeroIcon("magnifying-glass", size: 16)
                        .foregroundStyle(Theme.muted)
                    TextField("搜尋品項、品號", text: $query)
                        .font(.brand(16, .regular))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var ticketTitle: some View {
        let t = model.selectedTicket
        return VStack(alignment: .leading, spacing: 2) {
            // 外帶叫號的店不寫單號（客人只認取餐號碼）
            Eyebrow(t.map { model.orderNumber($0) ?? ($0.queueNumber == nil ? "取餐號碼結帳後給" : "取餐號碼") } ?? "A000")
            Text(t.map { model.orderTitle($0) } ?? "內用")
                .font(.brand(22, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var menuTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow("點餐")
            Headline("The *menu*", role: .h3)
                .lineLimit(1)
        }
    }

    /// 「掃碼」：手機不接條碼機，用相機掃——商品一個接一個、會員卡、發票載具、折價券（POSModel.handleScan 照內容判斷）
    private var scanButton: some View {
        Button {
            model.requestScan(.any)
        } label: {
            HStack(spacing: 6) {
                HeroIcon("qr-code", size: 17)
                Text("掃碼")
                    .font(.brand(15, .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Theme.surface, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.line) }
            .contentShape(.capsule)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityLabel("掃碼")
        .accessibilityHint("用相機掃商品、會員卡、發票載具、折價券")
    }

    /// 分類：一排可以左右滑的膠囊（選到的墨色實心）
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.catalog.categories) { c in
                        let on = categoryId == c.id
                        Button {
                            select(c.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Theme.swatch(c.swatch))
                                    .frame(width: 9, height: 9)
                                // 選到的變粗也不變寬：後面的膠囊不會被擠動
                                SteadyText(c.name, size: 15, on: on)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(on ? Theme.page : Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(on ? Theme.ink : Theme.surface, in: .capsule)
                            .overlay { Capsule().strokeBorder(on ? Color.clear : Theme.line) }
                            .contentShape(.capsule)
                        }
                        .buttonStyle(PressTint(radius: 20))
                        .id(c.id)
                        .accessibilityLabel(c.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 10)
            .onChange(of: categoryId) { _, id in
                guard let id else { return }
                // 點的那一顆已經看得到就不捲（膠囊的位置要穩）；左右滑換到畫面外的分類才捲到剛好看得到
                withAnimation(Motion.fast) { proxy.scrollTo(id) }
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
            EmptyState(icon: "magnifying-glass", title: query.isEmpty ? "這一類還沒有品項" : "找不到「\(query)」",
                       message: query.isEmpty ? "到後台「門市 POS → 菜單」新增" : nil)
        } else {
            ScrollView {
                // 左右滑時只有這一層跟著手指走（菜單其他地方不用重畫）
                SwipeShifted(shift: swipeShift) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(list) { item in
                            card(item)
                        }
                    }
                    .padding(.horizontal, 16)
                    // 卡片右上角疊的份數超出卡片 6 點：上面留 8 點才不會被切
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    // 換分類：整區從左右推進來
                    .id(query.isEmpty ? (categoryId ?? "all") : "search")
                    .transition(.push(from: pushFrom))
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            // 左右滑換分類（搜尋中不換；防誤觸見 CategorySwipe）
            .categorySwipe(model.catalog.categories, current: categoryId, enabled: query.isEmpty, shift: swipeShift) { id in
                select(id)
            }
            .sensoryFeedback(.selection, trigger: categoryId)
        }
    }

    @ViewBuilder
    private func card(_ item: MenuItem) -> some View {
        let swatch = model.catalog.category(item.categoryId)?.swatch ?? .sand
        if item.hasVariants && VariantPanel.isSimple(item) {
            // 小吃的兩種價錢：價錢就是卡上的鍵，點了直接加
            PriceGroupCard(item: item, swatch: swatch, available: model.isAvailable(item)) {
                decrement(item)
            } toggleAvailability: {
                model.toggleAvailability(item)
            }
        } else if item.hasVariants {
            BoutiqueItemCard(item: item, swatch: swatch, inTicket: quantity(of: item), available: model.isAvailable(item)) {
                Task { await model.tap(item) }
            } minus: {
                decrement(item)
            } toggleAvailability: {
                model.toggleAvailability(item)
            }
        } else {
            ItemCard(item: item, swatch: swatch, inTicket: quantity(of: item), available: model.isAvailable(item),
                     hasOptions: !item.modifierGroupIds.isEmpty, multiplier: keypad.multiplier) {
                Task { await model.tap(item) }
            } minus: {
                decrement(item)
            } toggleAvailability: {
                model.toggleAvailability(item)
            }
        }
    }

    /// 換分類：新的品項從對的那一邊推進來（上面的膠囊跟著捲到中間）
    private func select(_ id: String) {
        guard id != categoryId else { return }
        pushFrom = CategorySwipe.edge(from: categoryId, to: id, in: model.catalog.categories)
        withAnimation(Motion.spring) { categoryId = id }
        model.touch()
    }

    private func quantity(of item: MenuItem) -> Int {
        model.selectedTicket?.activeLines.filter { $0.itemId == item.id }.reduce(0) { $0 + $1.quantity } ?? 0
    }

    private func decrement(_ item: MenuItem) {
        guard let t = model.selectedTicket, let line = t.activeLines.last(where: { $0.itemId == item.id && !$0.isSent }) else { return }
        model.stepQuantity(line, in: t, by: -1)
    }

    private var itemBinding: Binding<MenuItem?> {
        Binding(get: { model.variantItem ?? model.modifierItem }, set: { value in
            if value == nil {
                model.variantItem = nil
                model.modifierItem = nil
            }
        })
    }

    // MARK: 下面：單子

    /// 看不到的單子欄：整張單的動作（送單、送到結帳櫃台／結帳、找會員、折扣、更多…）和 iPad 同一份，交給下面的大鍵與「⋯」
    @ViewBuilder
    private var hiddenTicketColumn: some View {
        if model.selectedTicket != nil {
            TicketColumn(preselects: false, offersScan: false)
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var bottomStrip: some View {
        VStack(spacing: 0) {
            if let t = model.selectedTicket {
                ticketBar(t)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let sale = model.lastSale, Date().timeIntervalSince(sale.closedAt) < 120 {
                LastSaleStrip(sale: sale)
            }
        }
        .animation(Motion.spring, value: model.selectedTicketId)
        // 單子：點一行選起來（鍵盤從這一張的下面升起來問它的數量，上面是那一行的動作：備註、折扣、刪除…）；左右滑加減、刪除。
        // 鍵盤、面板不再疊一張 sheet（PhoneDockHost inSheet）；要更多地方時拉到全高
        .sheet(isPresented: Binding(get: { ui.ticketOpen && model.selectedTicket != nil }, set: { ui.ticketOpen = $0 })) {
            PhoneDockHost(isActive: true, inSheet: true, onNeedsRoom: { more in
                if more { ticketDetent = .large }
            }) {
                TicketColumn()
                    // 套折價券要換掉原本的折扣：在這張 sheet 的下面問（不疊第二張）
                    .confirmDockPanel()
            }
            .presentationDetents([.medium, .large], selection: $ticketDetent)
            .phoneSheetStyle(Theme.page)
        }
        // 把單子打開給人看（-scanDemo 截圖：掃到的折價券、會員在單子上）
        .onChange(of: model.revealTicketRequest) { _, _ in
            if model.selectedTicket != nil { openTicket() }
        }
    }

    /// 「A2・3 項・NT$480」：點一下、往上滑打開單子
    private func ticketBar(_ t: Ticket) -> some View {
        PhoneTicketBar(title: "\(model.orderTitle(t))・\(t.itemCount) 項・\(t.totals.amountDue.formatted)",
                       hint: ticketHint(t)) { full in
            openTicket(full: full)
        }
    }

    private func ticketHint(_ t: Ticket) -> String {
        if model.couponShortfall(t) != nil { return "未達最低消費，結帳前會拿掉折價券" }
        if t.billPrintedAt != nil { return t.billSentFrom != nil ? "已送到結帳櫃台・點開看單子" : "已印結帳單・點開看單子" }
        let unsent = t.unsentLines.reduce(0) { $0 + $1.quantity }
        if unsent > 0 && model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst { return "\(unsent) 項還沒送廚房・點開改數量、備註" }
        if t.activeLines.isEmpty { return "點上面的品項加進來" }
        return "點開看單子、改數量、備註"
    }

    /// full：往上用力滑＝直接拉到全高
    private func openTicket(full: Bool = false) {
        ticketDetent = full ? .large : .medium
        ui.ticketOpen = true
        model.touch()
    }

    // MARK: 開單

    private var usesTables: Bool { model.visibleSections.contains(.floor) }

    /// 還沒有單：點品項就會開一張預設的單（和 iPad 一樣，不放「開一張新單」這種一樣的鍵）。
    /// 只放點品項做不到的：美業、課程先找會員；有桌位圖（選空桌入座）或還有其他用餐方式時的「開單」
    private var openPage: DockSelection? {
        if model.mode.wantsCustomer {
            return .page("phone-open", primary: POSAction("找會員開單", icon: "user-circle") { Task { await startWithMember() } })
        }
        if usesTables || !model.otherOrderTypes.isEmpty {
            return .page("phone-open", primary: POSAction("開單", icon: "plus-circle") { opening = true })
        }
        return nil
    }

    /// 「開單」面板裡的用餐方式：預設的那一種＋其他的（全外帶的店只有外帶）
    private var openTypes: [OrderType] {
        [model.mode.defaultOrderType] + model.otherOrderTypes
    }

    private var openSubtitle: String {
        usesTables ? "內用選一張空桌（下一步打人數），或外帶" : "選用餐方式"
    }

    /// 空桌（照區域）、不選桌的用餐方式
    @ViewBuilder
    private var openChoices: some View {
        let free = freeTables
        VStack(alignment: .leading, spacing: 8) {
            if usesTables {
                Eyebrow("內用・選一張空桌")
                if free.isEmpty {
                    Text("現在沒有空桌；可以先開外帶單，或到「桌位」看哪一桌快好了")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(free) { entry in
                    let status = model.tableStatus(entry.table.id)
                    DockChoice(title: entry.table.name, detail: "\(entry.area)・\(entry.table.seats) 人桌",
                               trailing: status == .reserved ? status.label : nil) {
                        opening = false
                        Task { await model.seat(table: entry.table) }
                    }
                }
                Eyebrow("不選桌")
                    .padding(.top, 10)
            }
            ForEach(openTypes, id: \.self) { type in
                DockChoice(title: "開\(type.label)單", detail: type == .dineIn && usesTables ? "先點，等一下再帶位" : nil,
                           selected: type == model.mode.defaultOrderType && !usesTables) {
                    opening = false
                    model.openTicket(type: type)
                }
            }
        }
    }

    /// 空著（或只是有訂位）的桌子，照區域排
    private var freeTables: [FreeTable] {
        model.floor.areas.flatMap { a in
            a.tables
                .filter { t in
                    let s = model.tableStatus(t.id)
                    return s == .available || s == .reserved
                }
                .map { FreeTable(table: $0, area: a.name) }
        }
    }

    /// 美業、課程：先找會員再點服務
    private func startWithMember() async {
        guard let t = model.ensureTicket() else { return }
        await model.attachMember(to: t)
    }

    // MARK: 截圖

    /// -preselect：打開一張有點東西的單（單子裡第一行選起來，下面是那一行的動作）
    private func preselectForScreenshot() async {
        guard LaunchArguments.preselect else { return }
        if model.selectedTicket == nil {
            let open = model.state.openTickets.filter { !$0.activeLines.isEmpty }
            if let t = open.last(where: { !$0.tableIds.isEmpty && $0.billPrintedAt == nil }) ?? open.last {
                model.selectedTicketId = t.id
            }
        }
        guard model.selectedTicket != nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        openTicket()
    }
}

/// 「開單」面板裡的一張空桌
private struct FreeTable: Identifiable {
    let table: DiningTable
    let area: String
    var id: String { table.id }
}

/// 下面那條單子：點一下＝打開單子（半高）；往上滑＝跟著手指升起來，放開就打開（滑得長、快＝全高）。
/// 自己一個 view：拖的時候只有這一條重畫，菜單不跟著重畫
private struct PhoneTicketBar: View {
    let title: String
    let hint: String
    /// true＝全高
    let open: (Bool) -> Void

    /// 往上拉了多少（負的；越拉越緊）
    @State private var lift: CGFloat = 0
    /// 拉過「放開就打開」的線（輕震一下）
    @State private var armed = false
    /// 這一下是滑的（不再當成點一下，免得打開兩次、全高又被改回半高）
    @State private var swiped = false

    var body: some View {
        Button {
            guard !swiped else { return }
            open(false)
        } label: {
            HStack(spacing: 12) {
                HeroIcon("list-bullet", size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.brand(16.5, .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(hint)
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.inverseMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .offset(y: armed ? -3 : 0)
            }
            .foregroundStyle(Theme.onInverse)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Theme.inverse, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.98))
        .offset(y: lift)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in drag(v.translation.height) }
                .onEnded { v in end(v) }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, now in now }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("單子 \(title)")
        .accessibilityHint("打開單子；也可以往上滑")
    }

    private func drag(_ dy: CGFloat) {
        swiped = true
        // 只認往上：最多升 28 點、越拉越緊
        let up = max(-dy, 0)
        lift = -28 * (1 - 1 / (up / 70 + 1))
        let now = up > 36
        if now != armed {
            withAnimation(Motion.fast) { armed = now }
        }
    }

    private func end(_ v: DragGesture.Value) {
        let up = -v.translation.height
        let flingUp = -v.predictedEndTranslation.height
        withAnimation(Motion.spring) {
            lift = 0
            armed = false
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            swiped = false
        }
        // 往上滑一段、或往上甩一下就打開；滑得長、甩得用力＝全高
        guard up > 36 || (flingUp > 120 && up > 12) else { return }
        open(up > 140 || flingUp > 420)
    }
}
