import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// iPhone：店員手上的點餐機（iPad 的 MainShell 不變）。
///
///   ┌──────────────────────────┐
///   │ 系統的時間列（手機照常顯示）  │
///   │ 提示：衝突、離線、別台剛做的事 │
///   │ 這一頁：清單、品項（點一下＝選）│ ← 上面選
///   │                          │
///   │ ┌ 桌位            ×  ┐   │ ← 選起來的一筆：一張卡（和 iPad 右欄同一份 DockSelection）
///   │ │ A2・4 位・32 分      │   │
///   │ │ [送到櫃台] [印結帳單] │   │   動作鍵兩欄
///   │ │ [        加點      ] │   │   主要動作＝最下面的大鍵
///   │ └─────────────────────┘   │ ← 下面做
///   │ 點餐  桌位  訂單  叫號  更多 │
///   └──────────────────────────┘
///
/// 沒選東西時，這一頁的主要動作浮在分頁上面（其他收進「⋯」）；要打數字時鍵盤從下面升起（sheet），問完收起來；
/// 不用打數字的選擇（.dockPanel）也是一張 sheet。結帳在結帳櫃台：「送到結帳櫃台」（POSModel+Handoff），
/// 這支手機打開「也能收款」才有結帳（刷卡、電子支付）。
struct PhoneShell: View {
    @Environment(POSModel.self) private var model
    @State private var ui = PhoneUI()

    var body: some View {
        VStack(spacing: 0) {
            PhoneBanners()
            PhoneDockHost(isActive: rootIsActive) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 叫號：點餐頁上面那張叫號卡點開的面板、叫到號之後選桌入座（和 iPad 同一份，這裡是 sheet）
                    .queueDockPanels()
                    // 要確認的事（套折價券會換掉原本的整單折扣）：下面升起來的面板（單子的 sheet 開著時由它自己放）
                    .confirmDockPanel()
            }
            PhoneTabBar()
        }
        .background(Theme.page.ignoresSafeArea())
        // 加進單子就輕震一下（點品項、價錢鍵、「加入」、掃到商品）
        .background { AddHaptic() }
        .environment(ui)
        .onAppear { normalizeSection() }
        .onChange(of: model.section) { _, _ in normalizeSection() }
        // 和 iPad 一樣：開不了發票、要不要印交易明細（這支手機打開「也能收款」時才會用到）
        .confirmationDialog(
            "開不了發票", isPresented: Binding(get: { model.pendingInvoiceFailure != nil }, set: { if !$0 { model.pendingInvoiceFailure = nil } }),
            presenting: model.pendingInvoiceFailure
        ) { f in
            Button("先結帳，之後補開") {
                if let t = model.state.tickets[f.ticketId] { Task { await model.complete(t, skipInvoice: true) } }
            }
            Button("取消", role: .cancel) {}
        } message: { f in
            Text(f.message)
        }
        .confirmationDialog(
            "要印交易明細嗎？", isPresented: Binding(get: { model.receiptOffer != nil }, set: { if !$0 { model.receiptOffer = nil } }),
            presenting: model.receiptOffer
        ) { sale in
            Button("印交易明細") { model.printReceipt(sale) }
            Button("不用", role: .cancel) {}
        }
        .simultaneousGesture(TapGesture().onEnded { model.touch() })
        // 相機掃碼（掃碼、掃會員條碼、掃折價券、掃載具）：先收起單子的 sheet 再打開（Components/ScanSheets.swift）
        .phoneScanPresenter(ui)
    }

    /// 最底下這一層是不是最上面的：點餐頁的單子、加料／規格的 sheet 開著時，鍵盤與面板由那張 sheet 出
    private var rootIsActive: Bool {
        !ui.ticketOpen && model.modifierItem == nil && model.variantItem == nil
    }

    @ViewBuilder
    private var page: some View {
        if let t = model.checkoutTicket, t.isOpen, [.order, .floor, .orders].contains(model.section) {
            // 這支手機也能收款：結帳畫面（刷卡、電子支付）。從左邊邊往右滑＝回到點餐（已經收的款照樣在單子上）
            PaymentView(ticketId: t.id)
                .swipeBack(model.section == .orders ? "訂單" : (model.section == .floor ? "桌位" : "點餐")) {
                    model.cancelCheckout()
                }
        } else {
            switch model.section {
            case .order: PhoneOrderView()
            case .floor: PhoneFloorList()
            case .orders: PhoneOrdersList()
            case .kitchen: KitchenView()
            case .queue: QueueView()
            case .members:
                PhoneSubpage(back: "更多", onBack: { model.go(.settings) }) {
                    MembersView()
                }
            default: PhoneMoreView()
            }
        }
    }

    /// 手機沒有的頁（預約表、報到、訂位、報表…）：回到這台的首頁
    private func normalizeSection() {
        let s = model.section
        guard !model.phoneTabs.contains(s), !model.phoneMoreSections.contains(s) else { return }
        model.section = model.phoneHome
    }
}

/// 手機上幾個畫面共用的狀態（哪一張 sheet 開著）
@Observable
final class PhoneUI {
    /// 點餐頁的單子（下面那條點開來的 sheet）
    var ticketOpen = false
    /// 從「訂單」點一張單：到點餐頁後直接打開單子
    var openTicketOnArrival = false
}

// MARK: - 上面選、下面做

/// 收各畫面交上來的 DockKey（和 iPad 的右欄同一份），畫在下面：
///   選起來的一筆＝下面一張卡；這一頁的動作＝浮在下面的大鍵＋「⋯」；問數字＝鍵盤；面板＝不用打數字的選擇。
/// 每一層（最底下的頁、單子的 sheet、加料的 sheet）自己也有一個，只有最上面那一層（isActive）出鍵盤、面板與提示。
///   最底下那一層：鍵盤與面板是一張 sheet
///   本身就是 sheet 的那一層（inSheet：單子、加料）：不再疊一張 sheet，鍵盤與面板從這一層的下面升起來（PhoneDock 的 drawer）
struct PhoneDockHost<Content: View>: View {
    var isActive: Bool
    /// 這一層本身是一張 sheet（單子、加料）
    var inSheet = false
    /// 下面要更多地方（選了一筆、鍵盤或面板升起來）：單子的 sheet 用來拉到全高
    var onNeedsRoom: ((Bool) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var dockHeight: CGFloat = 0
    @State private var areaHeight: CGFloat = 700

    var body: some View {
        ZStack(alignment: .bottom) {
            content()
                // 內容讓出下面那張卡／大鍵的高度（捲到底也看得到最後一筆）
                .safeAreaPadding(.bottom, dockHeight)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { areaHeight = $0 })
        .overlayPreferenceValue(DockKey.self, alignment: .bottom) { dock in
            // 單子的 sheet 裡：卡片最多四成高，上面的單子至少看得到三行
            PhoneDock(content: dock, isActive: isActive, inline: inSheet, areaHeight: areaHeight,
                      maxCardHeight: max(areaHeight * (inSheet ? 0.42 : 0.58), 200),
                      cardHeight: $dockHeight, onNeedsRoom: onNeedsRoom)
        }
        .overlay(alignment: .top) {
            if isActive { ToastHost(edge: .top) }
        }
    }
}

/// 手機上從下面升起來的 sheet：拖曳的橫條、圓角、底色都一樣（單子、加料用暖紙色；鍵盤、面板用右欄色）
extension View {
    func phoneSheetStyle(_ background: Color = Theme.dock) -> some View {
        presentationDragIndicator(.visible)
            .presentationCornerRadius(22)
            .presentationBackground(background)
    }
}

/// 下面那一塊：選起來的一筆（卡片）或這一頁的動作（浮著的大鍵）；鍵盤、面板也從這裡出
private struct PhoneDock: View {
    @Environment(KeypadController.self) private var keypad
    let content: DockContent
    let isActive: Bool
    /// 這一層本身是 sheet：鍵盤、面板從這一層的下面升起來（drawer），不疊 sheet
    let inline: Bool
    let areaHeight: CGFloat
    let maxCardHeight: CGFloat
    /// 下面那張卡／大鍵的高度（內容要讓出來的）；鍵盤、面板蓋上去的不算
    @Binding var cardHeight: CGFloat
    var onNeedsRoom: ((Bool) -> Void)?

    /// 現在放什麼（鍵盤或面板；關掉時晚一點點才收：連著問兩個數字時不會閃一下）。
    /// 鍵盤與面板是「同一張」sheet（或同一個 drawer）、裡面換內容：面板裡的選擇要打數字時不會整張收起來又升上來，
    /// 也不會因為換了一張 sheet 而被 SwiftUI 當成往下滑關掉（以前那樣會順手取消剛問的數字：鍵盤「跑掉」）
    @State private var presented: PhoneDockSheet?
    /// drawer 往下拖了多少
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            bar
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { cardHeight = $0 })
            if inline, presented != nil {
                // 後面的單子暗下來；點一下＝取消（和 sheet 往下滑一樣）
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { dismissByUser() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                drawer
                    .offset(y: dragY)
                    .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Motion.spring, value: content.selection?.id)
        .animation(Motion.spring, value: presented == nil)
        // drawer 開著時單子的 sheet 不能往下滑掉（往下滑的是 drawer 上面的橫條）
        .interactiveDismissDisabled(inline && presented != nil)
        .sheet(isPresented: inline ? .constant(false) : sheetShown) {
            dockContent
                .presentationDetents(detents)
                .phoneSheetStyle()
        }
        .task(id: wanted?.id ?? "none") {
            if let next = wanted {
                presented = next
                return
            }
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { presented = nil }
        }
        .onChange(of: needsRoom) { _, more in
            onNeedsRoom?(more)
        }
    }

    /// 選起來的一筆（卡片）或這一頁的動作（浮著的大鍵）。
    /// 單子的 sheet 裡鍵盤（或面板）升起來時卡片收起來：選起來那一行的小卡與動作鍵在鍵盤上面，不疊兩份；後面的單子照樣完整
    private var bar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if inline && presented != nil {
                EmptyView()
            } else if let s = content.selection, s.isItem {
                PhoneSelectionCard(selection: s, maxHeight: maxCardHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let s = content.selection, s.primary != nil || !s.actions.isEmpty {
                PhonePageBar(selection: s)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var needsRoom: Bool {
        (content.selection?.isItem ?? false) || (inline && presented != nil)
    }

    /// 現在該開什麼：面板開著就是面板（選起來那一行的數量也讓給面板）；面板裡的選擇要打數字、或沒有面板時問數字：鍵盤
    private var wanted: PhoneDockSheet? {
        guard isActive else { return nil }
        if let p = content.panel, !keypad.isAskingOther { return .panel(p.id) }
        if keypad.isAsking { return .keypad }
        return nil
    }

    /// 使用者往下滑關掉＝取消（問數字）／關掉（面板）。
    /// 自己收起來（presented 已經是 nil）時 SwiftUI 也可能寫一次 false：不做事；換內容的途中（要的已經不是這一張）也不算
    private var sheetShown: Binding<Bool> {
        Binding(get: { presented != nil }, set: { shown in
            guard !shown, let was = presented else { return }
            presented = nil
            guard was == wanted else { return }
            dismiss(was)
        })
    }

    /// drawer：點暗下來的地方、把橫條往下拉
    private func dismissByUser() {
        guard let was = presented, was == wanted else { return }
        dismiss(was)
    }

    private func dismiss(_ which: PhoneDockSheet) {
        switch which {
        case .keypad:
            keypad.cancel()
        case .panel(let id):
            if let p = content.panel, p.id == id { p.close() }
        }
    }

    /// 同一張 sheet（drawer）裡換內容（淡入淡出，不滑走）：
    ///   鍵盤：鍵位和 iPad 右欄一模一樣；上面留著選起來的那一筆（或面板的標題），知道這個數字是給誰的
    ///   面板：不用打數字的選擇；裡面的選擇要打數字時換成鍵盤，打完再換回來
    private var dockContent: some View {
        ZStack {
            Theme.dock.ignoresSafeArea()
            switch presented {
            case .keypad?:
                KeypadDock(content: DockContent(selection: content.selection, panel: content.panel), showsCancel: true, inSheet: true)
                    .transition(.opacity)
            case .panel(let id)?:
                if let p = content.panel, p.id == id {
                    DockPanelChrome(item: p, inSheet: true)
                        .transition(.opacity)
                }
            case nil:
                EmptyView()
            }
        }
        .animation(Motion.fast, value: presented)
    }

    /// 從這一層的下面升起來的鍵盤／面板（單子、加料的 sheet 裡）：圓角、上面一條可以往下拉的橫條
    private var drawer: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
        return dockContent
            .clipShape(shape)
            .overlay(alignment: .top) {
                // 拖曳的橫條（和系統的 sheet 一樣的位置）：往下拉＝取消／關掉
                Capsule()
                    .fill(Theme.faint)
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { v in dragY = max(v.translation.height, 0) }
                            .onEnded { v in
                                let close = v.translation.height > 70 || v.predictedEndTranslation.height > 180
                                withAnimation(Motion.spring) { dragY = 0 }
                                if close { dismissByUser() }
                            }
                    )
                    .accessibilityHidden(true)
            }
            .frame(height: drawerHeight)
            .frame(maxWidth: .infinity)
            .background {
                shape
                    .fill(Theme.dock)
                    .ignoresSafeArea(edges: .bottom)
                    .shadow(color: .black.opacity(0.22), radius: 24, y: -4)
            }
            .overlay {
                shape
                    .stroke(Theme.line, lineWidth: 1)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
    }

    /// 鍵盤照它要的高度（放不下可以拉到全高）；面板一半
    private var detents: Set<PresentationDetent> {
        presented == .keypad ? [.height(keypadHeight), .large] : [.medium, .large]
    }

    /// drawer 的高度：鍵盤照鍵盤要的（選起來那一行的數量：再加它的小卡與一兩排動作鍵）；面板六成。都不超過這一層
    private var drawerHeight: CGFloat {
        let room = max(areaHeight - 8, 320)
        switch presented {
        case .keypad?:
            var h = keypadHeight - 24
            if keypad.keepsSelection, let s = content.selection {
                h += CGFloat(min((s.actions.count + 1) / 2, 2)) * 60
            }
            return min(h, room)
        case .panel?:
            return min(max(areaHeight * 0.62, 340), room)
        case nil:
            return 0
        }
    }

    /// 鍵盤的高度：題目（兩行）、大字、四排 68 點的鍵、確認鍵都放得下（內容約 590，加上下面的橫條約 620）；
    /// 有快速鍵、找零／熟客這些幫手、上面留著選起來那一筆的小卡或面板的標題時再高一點。放不下時可以拉到全高
    private var keypadHeight: CGFloat {
        guard let r = keypad.request else { return 620 }
        let quick = r.spec.quickKeys.count
        let quickRows = quick == 0 ? 0 : (quick == 4 ? 1 : (quick + 2) / 3)
        var h: CGFloat = 620 + CGFloat(quickRows) * 52 + (quickRows > 0 ? 14 : 0)
        if r.spec.title == "收現金" || r.spec.title == "會員" || r.spec.kind == .phone || r.spec.kind == .taxId { h += 140 }
        if content.selection?.isItem == true || content.panel != nil { h += 84 }
        return h
    }
}

/// 下面那一塊放的東西
private enum PhoneDockSheet: Identifiable, Equatable {
    case keypad
    case panel(String)

    var id: String {
        switch self {
        case .keypad: "keypad"
        case .panel(let id): "panel-\(id)"
        }
    }
}

/// 選起來的一筆：種類、名字、說明、狀態、×（DockSelectionView，和 iPad 右欄同一個）、兩欄的動作鍵；主要動作是最下面的大鍵。
/// 卡片照內容的高度（太高才捲），不會撐到 maxHeight 把上面的清單擠掉；單子的一行用小卡（selection.compact）
private struct PhoneSelectionCard: View {
    let selection: DockSelection
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 放得下就照內容的高度；太高（動作很多）才變成可以捲的、最高 maxHeight
            if contentHeight > maxHeight {
                ScrollView {
                    measured
                }
                .scrollIndicators(.hidden)
                .frame(height: maxHeight)
            } else {
                measured
            }
            if let p = selection.primary {
                PhonePrimaryButton(action: p, accent: selection.accent)
                    .id(selection.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .fill(Theme.dock)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.16), radius: 20, y: -4)
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var measured: some View {
        DockSelectionView(selection: selection, compact: selection.compact)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
    }
}

/// 這一頁的動作：主要的大鍵浮在下面、其他收進「⋯」
private struct PhonePageBar: View {
    let selection: DockSelection

    var body: some View {
        HStack(spacing: 10) {
            if selection.primary == nil { Spacer(minLength: 0) }
            if !selection.actions.isEmpty {
                MoreMenu(actions: selection.actions.filter { !$0.isDestructive } + selection.actions.filter(\.isDestructive), size: .lg)
                    .background(Theme.dock, in: .rect(cornerRadius: Metric.radius, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
            if let p = selection.primary {
                PhonePrimaryButton(action: p, accent: selection.accent)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            // 底下的清單捲過去時字不會和大鍵疊在一起
            LinearGradient(colors: [Theme.page.opacity(0), Theme.page.opacity(0.92)], startPoint: .top, endPoint: .center)
                .allowsHitTesting(false)
        }
    }
}

/// 最下面那顆大鍵（和 iPad 右欄最下面的同一種）
struct PhonePrimaryButton: View {
    let action: POSAction
    var accent = true

    var body: some View {
        Button(action: action.perform) {
            HStack(spacing: 8) {
                if let icon = action.icon { HeroIcon(icon, size: 17) }
                Text(action.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.brand(action.isDestructive ? .danger : (accent ? .accent : .primary), size: .lg, fullWidth: true, arrow: true))
        .disabled(!action.isEnabled)
    }
}

// MARK: - 下面的分頁

/// 點餐、桌位、訂單、叫號（照這台看得到的頁）＋更多
private struct PhoneTabBar: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let tabs = model.phoneTabs
        let onMore = !tabs.contains(model.section)
        HStack(spacing: 0) {
            ForEach(tabs) { s in
                tab(icon: s.icon, label: s.label, selected: model.section == s, badge: badge(s)) {
                    model.go(s)
                }
            }
            tab(icon: "ellipsis-horizontal", label: "更多", selected: onMore, badge: 0) {
                model.go(model.phoneMoreSections.contains(.settings) ? .settings : (model.phoneMoreSections.first ?? .settings))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .background(Theme.pageAlt.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rule() }
    }

    private func tab(icon: String, label: String, selected: Bool, badge: Int, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HeroIcon(icon, size: 22)
                Text(label)
                    .font(.brand(11, selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 50)
            .overlay(alignment: .top) {
                // 選到的那一頁：品牌橘的短線
                Capsule()
                    .fill(selected ? Theme.accent : Color.clear)
                    .frame(width: 22, height: 3)
                    .offset(y: -6)
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.brand(10.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: .capsule)
                        .offset(x: -10, y: -2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .animation(Motion.fast, value: selected)
        .accessibilityLabel(badge > 0 ? "\(label)，\(badge)" : label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(_ s: AppSection) -> Int {
        switch s {
        // 待結帳（送到結帳櫃台、印了結帳單）的單
        case .orders: model.awaitingCheckoutCount
        case .kitchen: model.state.openTickets.reduce(0) { $0 + $1.lines.filter { $0.isActive && ($0.kitchen == .sent || $0.kitchen == .preparing) }.count }
        case .queue: model.queue.state?.waiting.count ?? 0
        default: 0
        }
    }
}

// MARK: - 上面的提示

/// 衝突、同步出問題、發票號碼快用完（這支手機有收款時）、別台剛做的事（「A2 在櫃台結好了」）
private struct PhoneBanners: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        let conflicts = model.state.unresolvedConflicts
        let numbersLeft = model.invoiceNumbersLeft
        let showInvoice = model.features.invoice && model.invoiceSettings.enabled && model.issuesInvoices && numbersLeft < 10
        let syncProblem = !model.isDemo && model.syncStatus.health == .attention && model.syncStatus.lastError != nil
        let offline = model.syncStatus.health == .offline && model.syncStatus.pending > 20
        let any = !conflicts.isEmpty || showInvoice || syncProblem || offline || model.remoteActivity != nil
        VStack(spacing: 6) {
            if let c = conflicts.last {
                Banner(text: c.message + (conflicts.count > 1 ? "（還有 \(conflicts.count - 1) 件）" : ""), tone: .danger)
            }
            if syncProblem, let e = model.syncStatus.lastError {
                Banner(text: e, tone: .danger)
            } else if offline {
                Banner(text: "離線中，\(model.syncStatus.pending) 筆存在這支手機，連上網路後自動補送", tone: .warning)
            }
            if showInvoice {
                Banner(text: numbersLeft == 0 ? "發票號碼用完了：結帳時會問要不要先結、之後補開" : "發票號碼只剩 \(numbersLeft) 張", tone: numbersLeft == 0 ? .danger : .warning)
            }
            if let activity = model.remoteActivity {
                Banner(text: activity, tone: .info)
                    .task(id: activity) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.remoteActivity == activity { model.remoteActivity = nil }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, any ? 6 : 0)
        .padding(.bottom, any ? 4 : 0)
        .animation(Motion.ease, value: model.remoteActivity)
    }
}

// MARK: - 收在「更多」裡的頁

/// 「‹ 更多」＋那一頁（會員）
struct PhoneSubpage<Content: View>: View {
    let back: String
    let onBack: @MainActor () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text(back)
                        .font(.brand(15.5, .medium))
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("回到\(back)")
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.page)
        // 從左邊邊往右滑＝回上一頁（和左上角的「‹ 更多」一樣）
        .swipeBack(back) { onBack() }
    }
}

/// 加進單子就震一下（手上拿著點，不用看畫面也知道點到了）。單獨一個看不到的小 view：只有它跟著 addTick 重畫
struct AddHaptic: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        Color.clear
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: model.addTick)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
