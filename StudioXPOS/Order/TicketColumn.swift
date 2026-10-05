import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 單子（工作區與右側鍵盤之間那一欄）：桌號、人數、點了什麼、金額。
///
/// 左邊選、右邊做（docs/DESIGN.md）：這一欄只有看與選——
///   - 沒點某一行：整張單的動作在右欄（大鍵：送單／結帳；動作鍵：找會員、折扣、備註、更多…、作廢）
///   - 點了某一行：右欄換成那一行（卡片＋動作鍵：用卡抵、設計師、換規格、備註、折扣、刪除），
///     右側鍵盤直接問它的數量（打數字＝改、−1／+1 一按就改、大鍵確認；0＝刪除）；再點一下取消
///   - 不用打數字的選擇（設計師、課程卡、規格、折扣的種類、用餐方式…）蓋住右欄（.dockPanel）
///   - 手勢：往左滑＝刪除（還沒送出的滑到底直接刪；送出去的只露出「作廢…」）；往右滑＝−1、+1（滑到底＝+1）
///   - 刪掉還沒送出的不留紀錄（lines.removed，下面可以「復原」）；送出去的作廢照樣記、印作廢單，但單子上不再列出來
///   - 頁首：標題（桌號／稱呼／單號）＋叫號的號碼、一行「阿珠・23:19」、用餐方式的分段控制（內用／外帶／外送，點一下就改）
///   - 頁首右上「選取」：一次勾好幾行（點一行＝勾／不勾，不能滑、不問數量）；右欄換成勾起來的這幾行一起的動作
///     （大鍵：刪除或作廢…；動作鍵：整筆折扣、備註、拆成新單、送廚房）。「完成」、×、換單＝不選了
/// 服飾多了整張單的銷售人員與換貨；美業、課程多了會員條（儲值金、課程卡）、每一行的設計師／教練與助理、用課程卡抵。
struct TicketColumn: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    /// 截圖（-preselect）時先選起第一行；看不到的那一份（直的 iPad、手機只為了交出整張單的動作）不要選
    var preselects = true
    /// 手機：「掃碼（會員・載具・折價券）」放進整張單的「⋯」。點餐頁下面那條（看不到的單子欄）不放：掃碼鍵在頁首（同一個動作只出現一次）
    var offersScan = true
    @State private var splitting: Ticket?
    /// 備註要寫在哪幾行（一行；或「選取」勾起來的好幾行，用同一個備註）
    @State private var noteFor: [TicketLine] = []
    @State private var noteText = ""
    @State private var ticketNote = false
    @State private var voidReasonFor: [TicketLine] = []
    @State private var voidingTicket = false
    /// 會員條打開了（看課程卡、備註、上次做了什麼）
    @State private var memberOpen = false
    /// 點了哪一行（右欄換成那一行的動作；再點一下取消）
    @State private var selectedLineId: String? = nil
    /// 蓋住右欄的選擇
    @State private var panel: TicketPanel? = nil
    /// 自訂品項（以前在點餐頁的「⋯」）
    @State private var askingCustom = false
    @State private var customName = ""
    /// 輸入折價券代碼（英數：用系統的文字框，右側鍵盤只有數字）
    @State private var askingCoupon = false
    @State private var couponText = ""
    /// 往左右滑開著的那一行（一次只開一行）
    /// 手機：按了「數量」才問（一選起來就升起整個鍵盤會把單子蓋掉；快速 −1／+1 用往右滑）
    @State private var phoneQuantity = false
    @State private var openSwipeId: String? = nil
    /// 頁首的「選取」：一次勾好幾行（右欄換成這幾行一起的動作）；不選某一行、不能滑、不問數量
    @State private var selecting = false
    /// 勾起來的行
    @State private var checked: Set<String> = []

    /// 蓋住右欄的選擇：這一行的（設計師、助理、課程卡、規格、折扣、座位）、整張單的（折扣、更多、銷售人員）、勾起來的幾行的（折扣）
    private enum TicketPanel: String, Identifiable {
        case performer, assistant, passes, variant, lineDiscount, lineCourse, ticketDiscount, ticketMore, salesperson, batchDiscount
        var id: String { rawValue }
        var isLine: Bool { [.performer, .assistant, .passes, .variant, .lineDiscount, .lineCourse].contains(self) }
    }

    // 一整串修飾太長，編譯器算不完型別：拆成四段（版面、跟著選取變的事、跳出來的視窗、要選原因的）
    var body: some View {
        confirmations(dialogs(lifecycle(layout)))
    }

    private var layout: some View {
        Group {
            if let t = model.checkoutTicket ?? model.selectedTicket {
                content(t)
            } else {
                empty
            }
        }
        .frame(maxHeight: .infinity)
        .background { ground.ignoresSafeArea(edges: model.isPhone ? .bottom : []) }
        .overlay(alignment: .leading) {
            if !model.isPhone { Rule(vertical: true) }
        }
        .dockSelection(dock)
        .dockPanel(item: $panel, title: { panelTitle($0) }, subtitle: { panelSubtitle($0) }) { p in
            panelContent(p)
        }
    }

    /// 換單、換行、加料的卡打開了：選取跟著變；選了一行就問它的數量。換單、結帳＝「選取」結束（勾的清掉）
    private func lifecycle<V: View>(_ v: V) -> some View {
        v
            .onChange(of: model.selectedTicketId) { _, _ in
                memberOpen = false
                selectedLineId = nil
                panel = nil
                endSelecting()
            }
            .onChange(of: model.checkoutTicketId) { _, _ in
                selectedLineId = nil
                panel = nil
                endSelecting()
            }
            .onChange(of: selectedLineId) { old, new in
                if panel?.isLine == true { panel = nil }
                openSwipeId = nil
                phoneQuantity = false
                // 不選這一行了（或換一行）：問它數量的鍵盤收起來；換一行的話馬上問新的那一行
                if old != nil, keypad.keepsSelection { keypad.cancel() }
            }
            // 加了新的一行：焦點到新加的那一行，原本選起來的就不選了；選起來的那一行不見了（刪掉、作廢、別台改了）也不選了。
            // 「選取」中勾起來的不見了（刪除、作廢、拆走）：拿掉；勾的全處理掉了＝選取結束
            .onChange(of: model.selectedTicket?.activeLines.count ?? 0) { old, new in
                pruneChecked()
                guard let id = selectedLineId else { return }
                let stillThere = model.selectedTicket?.activeLines.contains(where: { $0.id == id }) ?? false
                if new > old || !stillThere { selectedLineId = nil }
            }
            // 選了一行：右側鍵盤問它的數量（數量變了、跳視窗、別的題目來了：重新決定要不要問）
            .task(id: quantityAsk) { await askQuantity() }
            .onDisappear {
                if selectedLineId != nil, keypad.keepsSelection { keypad.cancel() }
            }
            // 規格、加料的卡打開了：右欄換成那張卡，這一行就不選了（「選取」也結束：右欄只對應一樣東西）
            .onChange(of: model.variantItem?.id) { _, id in
                if id != nil { selectedLineId = nil; endSelecting() }
            }
            .onChange(of: model.modifierItem?.id) { _, id in
                if id != nil { selectedLineId = nil; endSelecting() }
            }
            // 截圖：先選起第一行（只在 Debug、帶 -preselect）
            .task(id: model.selectedTicketId) {
                if preselects && LaunchArguments.preselect { preselectForScreenshot() }
            }
    }

    /// 拆單、自訂品項、折價券代碼、備註（相機掃碼在最外層：model.requestScan）
    private func dialogs<V: View>(_ v: V) -> some View {
        v
            .sheet(item: $splitting) { t in
                SplitSheet(ticket: t)
            }
            .alert("輸入折價券代碼", isPresented: $askingCoupon) {
                TextField("例如 YG-A3B2C1", text: $couponText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("套用") { applyTypedCoupon() }
                Button("取消", role: .cancel) { couponText = "" }
            } message: {
                Text("和網路商店同一份折價券；要連線才能確認")
            }
            .alert("自訂品項", isPresented: $askingCustom) {
                TextField("品名（例如：開瓶費）", text: $customName)
                Button("下一步：輸入金額") {
                    let name = customName.trimmingCharacters(in: .whitespaces)
                    customName = ""
                    guard !name.isEmpty else { return }
                    Task { await model.addCustom(name: name) }
                }
                Button("取消", role: .cancel) { customName = "" }
            }
            .alert("備註", isPresented: noteShown) {
                TextField("例如：不要香菜", text: $noteText)
                Button("好") {
                    let lines = noteFor
                    noteFor = []
                    if let t = model.selectedTicket { model.setNote(noteText, for: lines, in: t) }
                }
                Button("取消", role: .cancel) { noteFor = [] }
            } message: {
                if noteFor.count > 1 { Text("勾起來的 \(noteFor.count) 項都用這個備註") }
            }
            .alert("整張單的備註", isPresented: $ticketNote) {
                TextField("例如：有過敏、先上飲料", text: $noteText)
                Button("好") {
                    if let t = model.selectedTicket { model.setTicketNote(noteText, for: t) }
                }
                Button("取消", role: .cancel) {}
            }
    }

    /// 作廢的原因（一行、整張單）
    private func confirmations<V: View>(_ v: V) -> some View {
        v
            .confirmationDialog("為什麼不要了？", isPresented: voidReasonShown) {
                ForEach(["客人取消", "點錯", "出餐太慢", "餐點問題", "招待"], id: \.self) { reason in
                    Button(reason) {
                        let lines = voidReasonFor
                        voidReasonFor = []
                        if let t = model.selectedTicket { Task { await model.void(lines, in: t, reason: reason) } }
                    }
                }
                Button("取消", role: .cancel) { voidReasonFor = [] }
            }
            .confirmationDialog("作廢整張單？", isPresented: $voidingTicket) {
                ForEach(["客人離開", "開錯單", "測試"], id: \.self) { reason in
                    Button(reason, role: .destructive) {
                        if let t = model.selectedTicket { Task { await model.voidTicket(t, reason: reason) } }
                    }
                }
                Button("取消", role: .cancel) {}
            }
    }

    private var noteShown: Binding<Bool> {
        Binding(get: { !noteFor.isEmpty }, set: { if !$0 { noteFor = [] } })
    }

    private var voidReasonShown: Binding<Bool> {
        Binding(get: { !voidReasonFor.isEmpty }, set: { if !$0 { voidReasonFor = [] } })
    }

    /// 「套用」：打的代碼交給後台查（POSModel+Coupons）
    private func applyTypedCoupon() {
        let code = couponText.trimmingCharacters(in: .whitespacesAndNewlines)
        couponText = ""
        guard !code.isEmpty, let t = model.selectedTicket else { return }
        Task { await model.applyCoupon(code: code, to: t) }
    }

    /// 截圖用：點餐頁還沒有單 → 先打開一張有點東西的單；單子有東西就選起第一行（右欄是那一行的動作）
    private func preselectForScreenshot() {
        guard selectedLineId == nil, model.checkoutTicketId == nil else { return }
        guard let t = model.selectedTicket else {
            guard model.section == .order else { return }
            let open = model.state.openTickets.filter { !$0.activeLines.isEmpty }
            // 換了單之後這個 task（id: selectedTicketId）會再跑一次，那時再選第一行
            if let t = open.last(where: { !$0.tableIds.isEmpty && $0.billPrintedAt == nil }) ?? open.last {
                model.selectedTicketId = t.id
            }
            return
        }
        guard let first = t.activeLines.first else { return }
        selectedLineId = first.id
    }

    // MARK: 沒有單

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("單子")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Headline("Nothing *yet*", role: .h3)
                Text(emptyHint)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                Text(emptyActionsHint)
                    .textRole(.xs)
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
        }
        .padding(20)
    }

    private var emptyHint: String {
        if model.mode.usesTables && model.features.seating {
            return "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單；要帶位到「桌位」點空桌。"
        }
        if model.mode.showsOrderType {
            return "點左邊的品項就會開一張\(model.mode.defaultOrderType.label)單（\(model.mode.label)：\(model.mode.summary)）"
        }
        return "點左邊的品項就會開一張新單（\(model.mode.label)：\(model.mode.summary)）"
    }

    /// 右欄有什麼（點品項就會開單，所以沒有「開外帶單」這種鍵）
    private var emptyActionsHint: String {
        var parts = model.otherOrderTypes.map { "開\($0.label)單" }
        if model.mode.wantsCustomer { parts.insert("找會員開單", at: 0) }
        parts += ["自訂品項", "掃碼"]
        return parts.joined(separator: "、") + "在右邊"
    }


    /// 美業、課程：先找會員再點服務
    private func startWithMember() async {
        guard let t = model.ensureTicket() else { return }
        await model.attachMember(to: t)
    }


    // MARK: 單子

    private func content(_ t: Ticket) -> some View {
        let x = t.totals
        let editable = model.checkoutTicketId == nil
        // 「選取」中不能滑（點一行＝勾／不勾）
        let swipes = editable && !selecting
        return VStack(spacing: 0) {
            header(t)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Rule()
            if t.activeLines.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("還沒點東西")
                        .textRole(.h4)
                        .foregroundStyle(Theme.ink2)
                    Text("點左邊的品項加進來；先在右側鍵盤打數字＝一次加幾份")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 作廢的（送出去又不要的）不列：廚房、報表照樣有紀錄，單子上只看還要的
                        LazyVStack(spacing: 0) {
                            ForEach(t.activeLines) { line in
                                SwipeRow(id: line.id, openId: $openSwipeId,
                                         leading: swipes ? [minusKey(line), plusKey(line)] : [],
                                         trailing: swipes ? [deleteKey(line)] : [],
                                         fullLeading: swipes ? plusKey(line) : nil,
                                         fullTrailing: swipes && !line.isSent ? deleteKey(line) : nil,
                                         enabled: swipes) {
                                    LineRow(line: line, ticket: t, editable: editable,
                                            selected: swipes && selectedLineId == line.id,
                                            selecting: editable && selecting, checked: checked.contains(line.id),
                                            onSelect: { tapLine(line) })
                                        .background { lineBackdrop }
                                }
                                .id(line.id)
                                .transition(.opacity)
                                Rule(color: Theme.hair)
                            }
                        }
                        .animation(Motion.fast, value: t.activeLines.map(\.id))
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: t.activeLines.count) { old, new in
                        guard new > old, let last = t.activeLines.last else { return }
                        withAnimation(Motion.ease) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: selectedLineId) { _, id in
                        guard let id else { return }
                        withAnimation(Motion.ease) { proxy.scrollTo(id) }
                    }
                    // 下面多了卡片（手機）、鍵盤上面多了題目：清單變矮了，選起來的那一行照樣捲到看得見
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { _ in
                        guard let id = selectedLineId else { return }
                        withAnimation(Motion.ease) { proxy.scrollTo(id) }
                    })
                }
            }
            Rule()
            totals(t, x)
                .padding(18)
        }
        .animation(Motion.spring, value: selectedLineId)
        .animation(Motion.fast, value: selecting)
    }

    /// 單子欄的底（不透明）：iPad 是暖紙色上一層淡淡的右欄色；手機在 sheet 裡，和 sheet 同一個暖紙色
    private var ground: some View {
        ZStack {
            Theme.page
            if !model.isPhone { Theme.dock.opacity(0.55) }
        }
    }

    /// 一行的底（和單子欄同一個顏色、不透明：往左右滑時後面的鍵不會透出來）
    private var lineBackdrop: some View { ground }

    /// 點一行：「選取」中＝勾／不勾；不然＝選起來
    private func tapLine(_ line: TicketLine) {
        if selecting {
            toggleChecked(line)
        } else {
            select(line)
        }
    }

    /// 點一行：選起來（右欄換成那一行的動作，鍵盤問它的數量）；再點一次取消
    private func select(_ line: TicketLine) {
        guard model.checkoutTicketId == nil, line.isActive else { return }
        openSwipeId = nil
        if selectedLineId == line.id {
            selectedLineId = nil
        } else {
            selectedLineId = line.id
            // 左邊開著規格、加料的卡就收起來：右欄只對應一樣東西
            model.variantItem = nil
            model.modifierItem = nil
        }
        model.touch()
    }

    private func selectedLine(in t: Ticket) -> TicketLine? {
        guard let id = selectedLineId else { return nil }
        return t.lines.first { $0.id == id && $0.isActive }
    }

    /// 頁首（越矮越好，單子才看得到更多行）：
    ///   A036  (24 號)                     選取      ← 標題（桌號／稱呼／單號）＋叫號的號碼；右上「選取」（選取中：全選、完成）
    ///   阿珠・23:19          [內用｜外帶｜外送]      ← 誰開的、幾點；用餐方式（放不下就換到下一行）
    /// 下面才是（有的話）銷售人員、待結帳、換貨、會員條、整張單的備註
    private func header(_ t: Ticket) -> some View {
        let editable = model.checkoutTicketId == nil
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                titleRow(t, editable: editable)
                metaRow(t, editable: editable)
            }
            // 一排狀態（不是按鈕）：銷售人員、已印結帳單；要改在右欄
            if model.mode.staffPerTicket || t.billPrintedAt != nil {
                HStack(spacing: 8) {
                    if model.mode.staffPerTicket { salespersonTag(t) }
                    if t.billPrintedAt != nil { StatusBadge(billBadge(t), tone: .warning) }
                }
            }
            if let x = t.exchange {
                exchangeBanner(x)
            }
            if t.member != nil {
                TicketMemberStrip(ticket: t, open: $memberOpen)
            } else if model.mode.wantsCustomer && editable {
                // 美業、課程一定要有客人：提醒一下，「找會員」在右欄
                HStack(spacing: 10) {
                    HeroIcon("user-circle", size: 18)
                    Text("還沒有會員・\(memberHint)")
                        .font(.brand(13, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
            }
            if !t.note.isEmpty {
                Text("※ \(t.note)")
                    .font(.brand(13, .medium))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .animation(Motion.fast, value: memberOpen)
    }

    /// 第一行：標題＋叫號的號碼；右上「選取」（選取中：「全選／全不選」「完成」）。結帳中、還沒點東西：沒有「選取」
    private func titleRow(_ t: Ticket, editable: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(headerTitle(t))
                .font(.brand(22, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            if let q = t.queueNumber, q > 0 {
                queueBadge(q)
            }
            Spacer(minLength: 0)
            if editable && (selecting || !t.activeLines.isEmpty) {
                selectControls(t)
                    // 字貼齊右邊（和金額對齊）；按的範圍照樣有左右的留白
                    .padding(.trailing, -8)
            }
        }
    }

    /// 「選取」／選取中的「全選」「完成」：只有字的小鈕
    private func selectControls(_ t: Ticket) -> some View {
        HStack(spacing: 2) {
            if selecting {
                Button(allChecked(t) ? "全不選" : "全選") { toggleAll(t) }
                    .buttonStyle(HeaderTextButtonStyle(strong: false))
            }
            Button(selecting ? "完成" : "選取") {
                if selecting { endSelecting() } else { beginSelecting() }
            }
            .buttonStyle(HeaderTextButtonStyle())
            .accessibilityHint(selecting ? "不選了，回到一次點一行" : "一次勾好幾行：一起刪除、作廢、打折、寫備註、拆成新單")
        }
    }

    /// 第二行：「阿珠・23:19」；右邊是用餐方式（內用／外帶／外送）。放不下（桌號、人數讓這一行變長）就把用餐方式換到下一行，字不截斷
    @ViewBuilder
    private func metaRow(_ t: Ticket, editable: Bool) -> some View {
        let types = model.ticketOrderTypes
        if types.count > 1 {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    metaText(t)
                    Spacer(minLength: 0)
                    orderTypeSwitch(t, types: types, editable: editable)
                }
                VStack(alignment: .leading, spacing: 6) {
                    metaText(t)
                    orderTypeSwitch(t, types: types, editable: editable)
                }
            }
        } else {
            metaText(t)
        }
    }

    private func metaText(_ t: Ticket) -> some View {
        Text(metaLine(t))
            .font(.brand(12.5, .regular))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「阿珠・23:19」；標題不是單號（桌號、稱呼）時前面加單號，有人數加人數：「A036・4 位・阿珠・23:19」
    private func metaLine(_ t: Ticket) -> String {
        var parts: [String] = []
        if headerTitle(t) != t.number { parts.append(t.number) }
        if t.guests > 0 { parts.append("\(t.guests) 位") }
        parts.append(model.staffName(t.openedBy))
        parts.append(TaipeiTime.clock(t.openedAt))
        return parts.joined(separator: "・")
    }

    /// 單子的標題：內用有桌子＝桌號；有稱呼＝稱呼；美業、課程＝會員；不然＝單號。
    /// 用餐方式在旁邊的分段控制、叫號的號碼在旁邊的標籤，標題不再寫一次（以前是「外帶 A036」＋「●外帶」＋「24 號」）
    private func headerTitle(_ t: Ticket) -> String {
        if t.orderType == .dineIn && !t.tableIds.isEmpty { return model.floor.tableNames(t.tableIds) }
        if let name = t.customerName, !name.isEmpty { return name }
        if t.serviceMode?.showsOrderType == false, let m = t.member { return m.name ?? m.maskedPhone }
        return t.number
    }

    /// 叫號的號碼（結帳時取的、排隊叫到的）：「24 號」
    private func queueBadge(_ q: Int) -> some View {
        Text("\(q) 號")
            .font(.brand(15, .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.accentText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.accentSoft, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.35)) }
            .accessibilityLabel("叫號 \(q) 號")
    }

    /// 待結帳的標籤：印了結帳單、或送到結帳櫃台（櫃台看到的是「手機送來結帳」）
    private func billBadge(_ t: Ticket) -> String {
        guard let from = t.billSentFrom else { return "已印結帳單" }
        return model.role.hasDrawer ? "\(from)送來結帳" : "已送到結帳櫃台"
    }

    /// 這張單記人數：有內用的模式，或這張單本來就有桌子、人數（「更多…」的「人數」）
    private func tracksGuests(_ t: Ticket) -> Bool {
        model.mode.showsOrderType || !t.tableIds.isEmpty || t.guests > 0
    }

    // MARK: 用餐方式

    /// 用餐方式：內用／外帶／外送（分段控制）。點一下就改，服務費跟著換（model.setOrderType）。
    /// 結帳中只看不改：已經在收錢了，服務費一變應收就變；要改先按右欄的「回到點餐」
    private func orderTypeSwitch(_ t: Ticket, types: [OrderType], editable: Bool) -> some View {
        OrderTypeSwitch(types: types, selected: t.orderType, enabled: editable) { type in
            pickOrderType(type, for: t)
        }
    }

    /// 點了一段：內用改成外帶、外送而且單子在桌上＝先問（右欄的面板：「A2 的桌子會空出來」），好了才改、桌子空出來
    private func pickOrderType(_ type: OrderType, for t: Ticket) {
        guard model.checkoutTicketId == nil, type != t.orderType else { return }
        model.touch()
        guard type != .dineIn, !t.tableIds.isEmpty else {
            model.setOrderType(type, for: t)
            return
        }
        let tables = model.floor.tableNames(t.tableIds)
        let id = t.id
        // 這一欄自己的面板（更多…、折扣…）收起來：確認的面板才看得到
        panel = nil
        Task {
            let yes = await model.confirm(title: "改成\(type.label)？", message: "\(tables) 的桌子會空出來：這張單不再算在桌上，桌位圖上 \(tables) 變成空桌。",
                                          confirmLabel: "改成\(type.label)", confirmDetail: "\(tables) 空出來",
                                          keepLabel: "不改（留在 \(tables)）")
            // 問的時候單子可能被別台結帳、作廢，或這台已經進了結帳
            guard yes, model.checkoutTicketId == nil, let now = model.state.tickets[id], now.isOpen else { return }
            model.setOrderType(type, for: now)
        }
    }


    /// 「銷售 Cameron」（只顯示；改在右欄「銷售…」）
    private func salespersonTag(_ t: Ticket) -> some View {
        let s = model.staffMember(t.salespersonId)
        return HStack(spacing: 6) {
            if let s {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 20)
                Text("銷售 \(s.name)")
            } else {
                HeroIcon("user", size: 13)
                Text("還沒指定\(model.mode.staffTitle)")
            }
        }
        .font(.brand(12.5, .medium))
        .foregroundStyle(s == nil ? Theme.accentText : Theme.ink2)
        .lineLimit(1)
    }

    // MARK: 換貨

    /// 「換貨單・原單 A012 退回 2 件，抵 NT$1,280」
    private func exchangeBanner(_ x: ExchangeCredit) -> some View {
        let count = x.lines.reduce(0) { $0 + $1.quantity }
        let detail = "原單 \(x.number) 退回 \(count) 件，抵 \(x.amount.formatted)"
        return HStack(alignment: .top, spacing: 10) {
            HeroIcon("arrows-right-left", size: 16)
                .foregroundStyle(Theme.infoFG)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("換貨單")
                    .font(.brand(13.5, .semibold))
                    .foregroundStyle(Theme.infoFG)
                Text(detail)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Tone.info.background, in: .rect(cornerRadius: Metric.radius))
        .accessibilityElement(children: .combine)
    }


    /// 銷售人員的候選：上班中的排前面
    private var salespeople: [StaffMember] {
        let active = model.staff.filter(\.isActive)
        return active.filter { model.isClockedIn($0) } + active.filter { !model.isClockedIn($0) }
    }


    private var memberHint: String {
        model.mode == .fitness ? "在右邊「找會員」：堂數要記在會員身上" : "在右邊「找會員」：做完記在客人的紀錄上"
    }

    /// 還沒做的第 2、3 道
    private func laterCourses(_ t: Ticket) -> [Int] {
        Set(t.unsentLines.map(\.course)).filter { $0 >= 2 }.sorted()
    }


    // MARK: 金額

    private func totals(_ t: Ticket, _ x: TicketTotals) -> some View {
        let minutes = serviceMinutes(t)
        let redeemedCount = t.activeLines.filter { $0.redeem != nil }.reduce(0) { $0 + $1.quantity }
        let showsMinutes = minutes > 0 && (model.mode.staffPerLine || t.appointmentId != nil)
        // 手機選了一行：下面有那一行的卡片，金額只留總計，單子上才看得到好幾行
        let brief = model.isPhone && selectedLine(in: t) != nil
        return VStack(spacing: 7) {
            if !brief {
                ValueRow(label: "小計", value: x.subtotal.formatted)
                if redeemedCount > 0 {
                    ValueRow(label: "課程卡抵用 \(redeemedCount) 項", value: "不收費", tone: Theme.accentText)
                }
                orderDiscountRow(t, x)
                if x.serviceCharge.cents > 0 {
                    ValueRow(label: "服務費 \(percentText(bps: t.serviceChargeBps))", value: x.serviceCharge.formatted)
                }
                if x.tip.cents > 0 { ValueRow(label: "小費", value: x.tip.formatted) }
                if showsMinutes {
                    ServiceDurationBar(segments: durationSegments(t), total: minutes)
                        .padding(.vertical, 2)
                }
            }
            // 折價券還沒到最低消費（改了品項）：手機選了一行時也看得到
            if let d = t.discount, let short = model.couponShortfall(t) {
                CouponMinimumWarning(minimum: d.minimumOrder ?? .zero, short: short)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("總計")
                        .font(.brand(17, .semibold))
                    Text("含稅 \(x.tax.plain)・\(t.itemCount) 項")
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                MoneyText(money: x.amountDue, role: .number)
            }
            .padding(.top, brief ? 0 : 4)
            // 換貨單（還沒進結帳）：退回的抵多少、要補還是要退
            if !brief, let ex = t.exchange, t.exchangeApplied.cents == 0 {
                exchangePreview(ex, x)
            }
            if x.paid.cents > 0 {
                ValueRow(label: "已收", value: x.paid.formatted, tone: Theme.successFG)
                ValueRow(label: x.balance.isNegative ? "多收" : "尚欠", value: Money(cents: abs(x.balance.cents)).formatted, strong: true,
                         tone: x.balance.isNegative ? Theme.dangerFG : Theme.ink)
            }
        }
    }

    /// 整單折扣：折價券寫它的名字（「折價券 新會員 100 元  −NT$100」），其他的「折扣 9 折」
    @ViewBuilder
    private func orderDiscountRow(_ t: Ticket, _ x: TicketTotals) -> some View {
        if let d = t.discount, d.isCoupon {
            ValueRow(label: d.reason.isEmpty ? "折價券 \(d.couponCode ?? "")" : d.reason, value: "−" + x.orderDiscount.formatted, tone: Theme.accentText)
        } else if x.orderDiscount.cents > 0 {
            ValueRow(label: "折扣 \(t.discount?.label ?? "")", value: "−" + x.orderDiscount.formatted, tone: Theme.accentText)
        }
    }

    @ViewBuilder
    private func exchangePreview(_ ex: ExchangeCredit, _ x: TicketTotals) -> some View {
        let used = min(ex.amount, x.amountDue)
        ValueRow(label: "換貨抵用（原單 \(ex.number)）", value: "−" + used.formatted, tone: Theme.infoFG)
        if ex.amount > x.amountDue {
            ValueRow(label: "退差額（現金）", value: (ex.amount - x.amountDue).formatted, strong: true, tone: Theme.dangerFG)
        } else {
            ValueRow(label: "補差額", value: (x.amountDue - ex.amount).formatted, strong: true)
        }
    }

    /// 時間條的每一段：一個服務、多久、誰做（設計師的顏色）
    private func durationSegments(_ t: Ticket) -> [ServiceDurationBar.Segment] {
        t.activeLines.filter { $0.itemKind == .service && ($0.durationMinutes ?? 0) > 0 }.map { l in
            let who = model.staffMember(l.staffId)
            return ServiceDurationBar.Segment(id: l.id, name: l.name, minutes: (l.durationMinutes ?? 0) * l.quantity,
                                              color: who.map { Theme.swatch($0.swatch) } ?? Theme.faint, staffName: who?.name)
        }
    }

    /// 這張單的服務一共要多久（分鐘）
    private func serviceMinutes(_ t: Ticket) -> Int {
        t.activeLines.filter { $0.itemKind == .service }.reduce(0) { $0 + ($1.durationMinutes ?? 0) * $1.quantity }
    }

    /// 「45 分」「1 小時 30 分」「2 小時」
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) 分" }
        return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
    }


    // MARK: - 右欄：整張單

    /// 右欄要放什麼：結帳中不放（付款畫面自己放）；「選取」中放勾起來的幾行；選了某一行放那一行；不然放整張單（沒有單就是開單）
    private var dock: DockSelection? {
        guard model.checkoutTicketId == nil else { return nil }
        guard let t = model.selectedTicket else { return emptyPage }
        if selecting { return batchSelection(t) }
        if let line = selectedLine(in: t) { return lineSelection(line, in: t) }
        return ticketPage(t)
    }

    /// 還沒有單：點左邊的品項就會開一張預設的單，所以不放「開外帶單」這種大鍵（空的單子欄有提示）。
    /// 右欄只放點品項做不到的：找會員開單（美業、課程）、其他用餐方式（全外帶的店沒有）、自訂品項、掃條碼
    private var emptyPage: DockSelection {
        var actions: [POSAction] = []
        var primary: POSAction? = nil
        if model.mode.wantsCustomer {
            primary = POSAction("找會員開單", icon: "user-circle") { Task { await startWithMember() } }
        }
        for other in model.otherOrderTypes {
            actions.append(POSAction("開\(other.label)單", icon: "plus-circle") { model.openTicket(type: other) })
        }
        actions.append(POSAction("自訂品項…", icon: "pencil-square") { askingCustom = true })
        // 相機掃碼：商品一個接一個、會員卡、載具、折價券（iPad 也有相機；外接條碼機不用按，直接掃）
        actions.append(POSAction("掃碼…", icon: "qr-code") { model.requestScan(.any) })
        // 剛結帳的那一筆（點餐頁下面那條）：補印交易明細
        if let sale = model.lastSale, Date().timeIntervalSince(sale.closedAt) < 120 {
            actions.append(POSAction("印上一筆明細", icon: "printer") { model.printReceipt(sale) })
        }
        return .page("ticket-empty", primary: primary, accent: false, actions: actions)
    }

    /// 整張單：大鍵＝送單（餐廳有還沒送的）或結帳；動作鍵只放常用的，其他在「更多…」「折扣…」的面板
    private func ticketPage(_ t: Ticket) -> DockSelection {
        let unsent = t.unsentLines.filter { $0.course <= 1 }
        let canSend = sendsFromTicket && !unsent.isEmpty
        let checkout = checkoutAction(t)
        var actions: [POSAction] = []
        if canSend { actions.append(checkout) }
        actions += ticketActions(t)
        if canSend {
            let count = unsent.reduce(0) { $0 + $1.quantity }
            return .page("ticket-\(t.id)", primary: POSAction("送單 \(count)", icon: "fire") { model.send(t) }, accent: true, actions: actions)
        }
        return .page("ticket-\(t.id)", primary: checkout, accent: model.takesPayment, actions: actions)
    }

    /// 單子上有「送單」「送廚房」：餐廳先送廚房、吃完再結帳；櫃台、咖啡結帳時一起送（沒有「送單」）；美業沒有廚房，只有結帳
    private var sendsFromTicket: Bool {
        model.features.kitchen && model.mode.usesKitchen && !model.mode.payFirst
    }

    /// 結帳；不收錢的崗位（報到接待、前場的手機）：送到結帳櫃台（單子變成待結帳、櫃台跳出來），請客人過去結
    private func checkoutAction(_ t: Ticket) -> POSAction {
        let hasLines = !t.activeLines.isEmpty
        if model.takesPayment {
            return POSAction("結帳", icon: "banknotes", enabled: hasLines) { model.beginCheckout(t) }
        }
        let sent = t.billPrintedAt != nil && t.billSentFrom != nil
        return POSAction(sent ? "再送一次到櫃台" : "送到結帳櫃台", icon: "paper-airplane", enabled: hasLines) {
            model.sendToRegister(t)
        }
    }

    /// 整張單的動作鍵（右欄上面的空間有限：最多六個；不常用的在「更多…」）
    private func ticketActions(_ t: Ticket) -> [POSAction] {
        var out: [POSAction] = []
        if t.member == nil {
            out.append(POSAction("找會員", icon: "user-circle") { Task { await model.attachMember(to: t) } })
        }
        // 手機沒有條碼機：相機掃（「⋯」裡，沒有六個鍵的限制）；iPad 的在「更多…」
        if model.isPhone && offersScan {
            out.append(POSAction("掃碼（會員・載具・折價券）", icon: "qr-code") { model.requestScan(.any) })
        }
        if model.mode.staffPerTicket {
            let s = model.staffMember(t.salespersonId)
            out.append(POSAction(s.map { "銷售：\($0.name)" } ?? "指定\(model.mode.staffTitle)", icon: "user") { panel = .salesperson })
        }
        out.append(POSAction(discountActionTitle(t), icon: "tag") { panel = .ticketDiscount })
        out.append(POSAction("整張單的備註…", icon: "pencil-square") {
            noteText = t.note
            ticketNote = true
        })
        out.append(POSAction("更多…", icon: "ellipsis-horizontal") { panel = .ticketMore })
        out.append(POSAction("作廢整張單…", icon: "trash", destructive: true) { voidingTicket = true })
        return out
    }

    /// 「折扣・折價券…」「折扣（9 折）…」「折扣（折價券）…」
    private func discountActionTitle(_ t: Ticket) -> String {
        guard let d = t.discount else { return "折扣・折價券…" }
        return d.isCoupon ? "折扣（折價券）…" : "折扣（\(d.label)）…"
    }

    // MARK: - 右欄：選起來的一行

    /// 這一行：卡片＋動作鍵（課程卡、設計師、助理、換規格、備註、折扣、座位、刪除）。
    /// iPad 沒有「數量」鍵：選起來時右側鍵盤就在問它的數量，大鍵是鍵盤的確認（「數量 2」「改成 3」）
    private func lineSelection(_ line: TicketLine, in t: Ticket) -> DockSelection {
        let passes = line.redeem == nil ? model.redeemablePasses(for: line, in: t) : []
        let title = model.mode.staffTitle
        var actions: [POSAction] = []
        if line.redeem != nil {
            actions.append(POSAction("取消抵用", icon: "arrow-uturn-left") { model.unredeem(line, in: t) })
        } else if let only = passes.first, passes.count == 1 {
            actions.append(POSAction("用\(only.name)抵", icon: "ticket") { model.redeem(line, with: only, in: t) })
        } else if !passes.isEmpty {
            actions.append(POSAction("用卡抵…", icon: "ticket") { panel = .passes })
        }
        if canEditStaff(line) {
            actions.append(POSAction(line.staffId == nil ? "指定\(title)" : "換\(title)", icon: "user") { panel = .performer })
            actions.append(POSAction(line.assistantId == nil ? "加助理" : "換助理", icon: "users") { panel = .assistant })
        }
        if canChangeVariant(line) {
            actions.append(POSAction("換規格", icon: "swatch") { panel = .variant })
        }
        actions.append(POSAction("備註…", icon: "pencil-square") {
            noteText = line.note
            noteFor = [line]
        })
        actions.append(POSAction(line.discount == nil ? "折扣・改價…" : "折扣（\(line.discount?.label ?? "")）…", icon: "tag") { panel = .lineDiscount })
        if isClassic {
            actions.append(POSAction(line.isSent ? "座位…" : "座位・第幾道…", icon: "clock") { panel = .lineCourse })
        }
        if line.isSent {
            actions.append(POSAction("作廢…", icon: "x-circle", destructive: true) { delete(line, in: t) })
        } else {
            actions.append(POSAction("刪除", icon: "trash", destructive: true) { delete(line, in: t) })
        }
        // 手機：大鍵是「數量」（按了才升起鍵盤）；卡片用小的（單子的 sheet 裡，鍵盤從下面升起來，上面還看得到單子）
        let phonePrimary = model.isPhone ? POSAction("數量 \(line.quantity)", icon: "calculator") { phoneQuantity = true } : nil
        return DockSelection(id: "line-\(line.id)", kind: "這一行", title: line.displayName, detail: lineDetail(line),
                             badge: lineBadge(line), primary: phonePrimary, accent: false, actions: actions,
                             compact: model.isPhone, clear: { selectedLineId = nil })
    }

    // MARK: - 右欄：「選取」勾起來的幾行

    /// 勾起來的這幾行：卡片（選取・已選 3 項・合計）＋動作鍵（整筆折扣、備註、拆成新單、送廚房）。
    /// 大鍵：都還沒送出＝刪除（下面可以復原）；有送出去的＝作廢…（問原因、要主管）。× 或頁首的「完成」＝不選了
    private func batchSelection(_ t: Ticket) -> DockSelection {
        let lines = checkedLines(in: t)
        let hasLines = !lines.isEmpty
        var actions: [POSAction] = [
            POSAction("整筆折扣…", icon: "tag", enabled: hasLines) { panel = .batchDiscount },
            POSAction("備註…", icon: "pencil-square", enabled: hasLines) {
                noteText = sharedNote(lines)
                noteFor = lines
            },
            // 全部勾了就不是拆單（拆出來的和原本的一樣）
            POSAction("拆成新單", icon: "scissors", enabled: hasLines && lines.count < t.activeLines.count) {
                splitOff(lines, from: t)
            },
        ]
        let unsent = lines.filter { !$0.isSent }
        if sendsFromTicket && !unsent.isEmpty {
            let count = unsent.reduce(0) { $0 + $1.quantity }
            actions.append(POSAction("送廚房 \(count)", icon: "fire") {
                model.send(unsent, in: t)
                endSelecting()
            })
        }
        return DockSelection(id: "batch-\(t.id)", kind: "選取", title: "已選 \(lines.count) 項",
                             detail: hasLines ? batchDetail(lines) : "點單子上的品項勾起來；頁首的「全選」一次勾全部",
                             primary: batchPrimary(lines, in: t), accent: false, actions: actions,
                             compact: model.isPhone, clear: { endSelecting() })
    }

    /// 大鍵：都還沒送出＝「刪除 3 項」（lines.removed，下面跳「已刪除 3 項・復原」）；
    /// 有送出去的＝「作廢…」（和一行的作廢同一個流程：問原因、要主管、廚房印作廢單；一起勾的還沒送出的直接拿掉）
    private func batchPrimary(_ lines: [TicketLine], in t: Ticket) -> POSAction? {
        guard !lines.isEmpty else { return nil }
        let sentCount = lines.filter(\.isSent).count
        if sentCount == 0 {
            return POSAction("刪除 \(lines.count) 項", icon: "trash", destructive: true) {
                model.removeLines(lines, in: t)
            }
        }
        let title = sentCount == lines.count ? "作廢 \(lines.count) 項…" : "刪除・作廢 \(lines.count) 項…"
        return POSAction(title, icon: "x-circle", destructive: true) {
            voidReasonFor = lines
        }
    }

    /// 「合計 NT$420・2 項已送出」：勾起來的這幾行加起來（課程卡抵的不收錢、不算）
    private func batchDetail(_ lines: [TicketLine]) -> String {
        let total = Money.sum(lines.filter { $0.redeem == nil }.map { $0.gross - $0.lineDiscount })
        var parts = ["合計 \(total.formatted)"]
        let sentCount = lines.filter(\.isSent).count
        if sentCount > 0 { parts.append("\(sentCount) 項已送出") }
        return parts.joined(separator: "・")
    }

    /// 勾起來的行（照單子上的順序；已經不在單子上的不算）
    private func checkedLines(in t: Ticket) -> [TicketLine] {
        t.activeLines.filter { checked.contains($0.id) }
    }

    /// 勾起來的都是同一個備註就帶進來（改一個字比較快）；不一樣就空白
    private func sharedNote(_ lines: [TicketLine]) -> String {
        let notes = Set(lines.map(\.note))
        return notes.count == 1 ? (notes.first ?? "") : ""
    }

    /// 拆成新單：勾起來的整行搬到新的一張（和「拆單」同一個事件：model.split）。新單會選起來，「選取」跟著結束
    private func splitOff(_ lines: [TicketLine], from t: Ticket) {
        var moving: [String: Int] = [:]
        for l in lines { moving[l.id] = l.quantity }
        model.split(t, moving: moving)
    }

    /// 頁首的「選取」：開始勾。選起來的那一行、滑開的那一行、蓋著的面板、左邊的規格加料卡都收起來（右欄只對應一樣東西）
    private func beginSelecting() {
        selectedLineId = nil
        openSwipeId = nil
        panel = nil
        checked = []
        model.variantItem = nil
        model.modifierItem = nil
        selecting = true
        model.touch()
    }

    /// 「完成」、×、換單、結帳、打開規格加料卡：不選了（勾的清掉）
    private func endSelecting() {
        if panel == .batchDiscount { panel = nil }
        guard selecting || !checked.isEmpty else { return }
        selecting = false
        checked = []
    }

    private func toggleChecked(_ line: TicketLine) {
        guard line.isActive else { return }
        if checked.contains(line.id) {
            checked.remove(line.id)
        } else {
            checked.insert(line.id)
        }
        model.touch()
    }

    /// 「全選」：勾全部；全部都勾了是「全不選」
    private func toggleAll(_ t: Ticket) {
        let all = Set(t.activeLines.map(\.id))
        checked = allChecked(t) ? [] : all
        model.touch()
    }

    private func allChecked(_ t: Ticket) -> Bool {
        !t.activeLines.isEmpty && t.activeLines.allSatisfy { checked.contains($0.id) }
    }

    /// 單子的行變了：勾起來的不見了（刪除、作廢、拆走、別台改了）就拿掉；勾的全處理掉了、或單子空了＝「選取」結束
    private func pruneChecked() {
        guard selecting else { return }
        let active = Set(model.selectedTicket?.activeLines.map(\.id) ?? [])
        let kept = checked.intersection(active)
        if active.isEmpty || (!checked.isEmpty && kept.isEmpty) {
            endSelecting()
        } else if kept != checked {
            checked = kept
        }
    }

    // MARK: - 右側鍵盤：選起來那一行的數量

    /// 要不要問、問哪一行（變了就重新決定）
    private struct QuantityAsk: Equatable {
        var lineId: String?
        var quantity = 0
        var sent = false
        /// 跳視窗、面板蓋著：先不問
        var paused = false
        /// 別的題目（改價、PIN、座位…）在問：讓它先問
        var yielding = false
    }

    private var quantityAsk: QuantityAsk {
        guard let id = selectedLineId, model.checkoutTicketId == nil, !model.isPhone || phoneQuantity,
              let line = model.selectedTicket?.activeLines.first(where: { $0.id == id }) else { return QuantityAsk() }
        return QuantityAsk(lineId: id, quantity: line.quantity, sent: line.isSent, paused: quantityPaused, yielding: keypad.isAskingOther)
    }

    /// 跳視窗（備註、作廢的原因）、蓋住右欄的面板（包括「改成外帶？」的確認）、拆單、掃條碼：問數量的鍵盤先讓開，關掉再回來問
    private var quantityPaused: Bool {
        !noteFor.isEmpty || !voidReasonFor.isEmpty || panel != nil || ticketNote || voidingTicket
            || askingCustom || askingCoupon || model.scanRequest != nil || splitting != nil || model.confirmRequest != nil
    }

    /// 點了一行：右側鍵盤直接問它的數量（帶入現在的數量，打數字＝換掉；−1、+1、2 個、3 個一按就改；大鍵確認）。
    /// 改好了接著問同一行，直到不選這一行。0＝刪除（還沒送出的直接拿掉；送出去的要作廢）；沒改就按大鍵＝好了（不選了）。
    /// 別的題目（改價、座位、PIN）來了就讓它先問，問完再回來；按取消（Esc、手機往下滑）＝不選這一行了
    private func askQuantity() async {
        while !Task.isCancelled {
            guard let id = selectedLineId, model.checkoutTicketId == nil, !model.isPhone || phoneQuantity, let t = model.selectedTicket,
                  let line = t.activeLines.first(where: { $0.id == id }) else { return }
            if quantityPaused || keypad.isAskingOther {
                if keypad.keepsSelection { keypad.cancel() }
                return
            }
            let before = line.quantity
            let entry = await keypad.ask(quantitySpec(line), keepsSelection: true, validate: { e in
                quantityProblem(e.value ?? 0, line: line, in: t)
            }, confirmTitle: { e in
                TicketColumn.quantityLabel(e, line: line)
            })
            if Task.isCancelled { return }
            guard let entry else {
                // 被別的題目換掉：等它問完（yielding 變回來時重新問）。使用者按了取消（Esc、手機往下滑）：不選這一行了
                // 手機：鍵盤收起來、回到這一行的卡（還選著）
                if !keypad.isAsking && !quantityPaused && selectedLineId == id {
                    if model.isPhone { phoneQuantity = false } else { selectedLineId = nil }
                }
                return
            }
            guard let current = model.selectedTicket?.activeLines.first(where: { $0.id == id }) else { return }
            let q = entry.value ?? current.quantity
            if q == current.quantity {
                if model.isPhone { phoneQuantity = false } else { selectedLineId = nil }
                return
            }
            if q == 0 {
                delete(current, in: t)
                return
            }
            await model.setQuantity(current, to: q, in: t)
            // 改好了：數量變了會重新問（task 的 id 跟著變）；沒改成（主管沒授權、卡的次數不夠）就再問一次
            if model.selectedTicket?.activeLines.first(where: { $0.id == id })?.quantity != before { return }
        }
    }

    /// 數量的題目：現在的數量先帶入（打數字＝換掉）；快速鍵一按就改
    private func quantitySpec(_ line: TicketLine) -> KeypadSpec {
        let q = line.quantity
        return KeypadSpec(kind: .count, title: "數量",
                          subtitle: line.isSent ? "已經送廚房：減少要主管；打 0＝作廢" : "打數字＝改成幾個；打 0＝刪除",
                          initial: String(q),
                          quickKeys: [KeypadSpec.QuickKey("−1", digits: String(max(q - 1, 0)), commits: true),
                                      KeypadSpec.QuickKey("+1", digits: String(min(q + 1, 999)), commits: true),
                                      KeypadSpec.QuickKey("2 個", digits: "2", commits: true),
                                      KeypadSpec.QuickKey("3 個", digits: "3", commits: true)],
                          confirmLabel: "數量 \(q)", maxValue: 999)
    }

    /// 大鍵：沒改「數量 2」、改了「改成 3」、打 0「刪除」（送出去的「作廢…」）
    private static func quantityLabel(_ e: KeypadEntry, line: TicketLine) -> String {
        guard !e.isPristine, let v = e.value, v != line.quantity else { return "數量 \(line.quantity)" }
        if v == 0 { return line.isSent ? "作廢…" : "刪除" }
        return "改成 \(v)"
    }

    /// 用課程卡抵的：卡的次數不夠就不能加
    private func quantityProblem(_ q: Int, line: TicketLine, in t: Ticket) -> String? {
        guard q > line.quantity else { return nil }
        return model.redeemProblem(line, quantity: q, in: t)
    }

    /// 刪掉這一行：還沒送出的直接拿掉（不留紀錄，下面可以「復原」）；送出去的要作廢（問原因、要主管、廚房印作廢單）
    private func delete(_ line: TicketLine, in t: Ticket) {
        if line.isSent {
            voidReasonFor = [line]
        } else {
            if selectedLineId == line.id { selectedLineId = nil }
            model.removeLines([line], in: t)
        }
    }

    /// −1／+1（往右滑）：減到 0＝刪除
    private func step(_ line: TicketLine, by delta: Int) {
        guard let t = model.selectedTicket, let current = t.activeLines.first(where: { $0.id == line.id }) else { return }
        if current.quantity + delta < 1 {
            delete(current, in: t)
        } else {
            model.stepQuantity(current, in: t, by: delta)
        }
    }

    // MARK: - 往左右滑的鍵

    private func minusKey(_ line: TicketLine) -> SwipeAction {
        SwipeAction("−1", tint: Theme.key, foreground: Theme.ink, keepsOpen: true) { step(line, by: -1) }
    }

    private func plusKey(_ line: TicketLine) -> SwipeAction {
        SwipeAction("+1", tint: Theme.accent, foreground: Theme.onAccent, keepsOpen: true) { step(line, by: 1) }
    }

    /// 還沒送出的：刪除（滑到底直接刪）；送出去的：作廢…（問原因、要主管，滑到底也只是露出來）
    private func deleteKey(_ line: TicketLine) -> SwipeAction {
        SwipeAction(line.isSent ? "作廢…" : "刪除", icon: "trash", tint: Theme.dangerFG, foreground: Theme.page) {
            if let t = model.selectedTicket { delete(line, in: t) }
        }
    }

    /// 「×2・NT$240・半糖・少冰・Cameron」
    private func lineDetail(_ line: TicketLine) -> String {
        var parts = ["×\(line.quantity)"]
        parts.append(line.redeem != nil ? "卡抵" : (line.gross - line.lineDiscount).formatted)
        if !line.modifiers.isEmpty { parts.append(line.modifierText) }
        if line.itemKind == .service, let m = line.durationMinutes { parts.append(TicketColumn.duration(m * line.quantity)) }
        if let s = model.staffMember(line.staffId) { parts.append(s.name) }
        return parts.joined(separator: "・")
    }

    private func lineBadge(_ line: TicketLine) -> DockBadge? {
        if line.redeem != nil { return DockBadge("卡抵", tone: .gold) }
        if line.isSent { return DockBadge(line.kitchen.label, tone: .info) }
        if isClassic { return DockBadge("未送出", tone: .gold) }
        return nil
    }

    private func canEditStaff(_ line: TicketLine) -> Bool {
        model.mode.staffPerLine && line.itemKind == .service && line.isActive
    }

    private func canChangeVariant(_ line: TicketLine) -> Bool {
        guard line.isActive, !line.isSent, line.skuId != nil, let id = line.itemId else { return false }
        return model.catalog.item(id)?.hasVariants ?? false
    }

    /// 餐飲、零售（座位、第幾道只有這幾個模式用）
    private var isClassic: Bool { !model.mode.staffPerLine && !model.mode.staffPerTicket }

    // MARK: - 蓋住右欄的選擇

    private func panelTitle(_ p: TicketPanel) -> String {
        switch p {
        case .performer: "指定\(model.mode.staffTitle)"
        case .assistant: "助理"
        case .passes: "用課程卡抵"
        case .variant: "換規格"
        case .lineDiscount: "折扣・改價"
        case .lineCourse: "座位・第幾道"
        case .ticketDiscount: "整張單的折扣"
        case .ticketMore: "這張單"
        case .salesperson: "銷售人員"
        case .batchDiscount: "整筆折扣"
        }
    }

    private func panelSubtitle(_ p: TicketPanel) -> String? {
        if p.isLine { return model.selectedTicket.flatMap { selectedLine(in: $0) }?.displayName }
        guard let t = model.selectedTicket else { return nil }
        switch p {
        case .salesperson: return "整張單的業績算給誰"
        case .batchDiscount: return "已選 \(checkedLines(in: t).count) 項・每一項打一樣的折扣"
        default: return "\(t.number)・\(t.title(floor: model.floor))"
        }
    }

    @ViewBuilder
    private func panelContent(_ p: TicketPanel) -> some View {
        if let t = model.selectedTicket {
            VStack(alignment: .leading, spacing: 8) {
                if p == .batchDiscount {
                    batchDiscountPanel(in: t)
                } else if p.isLine {
                    if let line = selectedLine(in: t) {
                        linePanel(p, line: line, in: t)
                    }
                } else {
                    ticketPanel(p, in: t)
                }
            }
        }
    }

    /// 這一行的選擇
    @ViewBuilder
    private func linePanel(_ p: TicketPanel, line: TicketLine, in t: Ticket) -> some View {
        switch p {
        case .performer:
            staffChoices(model.bookableStaff, selected: line.staffId, none: "不指定") { id in
                model.setPerformer(line, staffId: id, in: t)
            }
        case .assistant:
            staffChoices(model.staff.filter { $0.isActive && $0.id != line.staffId }, selected: line.assistantId, none: "不用助理") { id in
                model.setAssistant(line, staffId: id, in: t)
            }
        case .passes:
            ForEach(model.redeemablePasses(for: line, in: t)) { pass in
                let left = model.visitsLeft(on: pass, excluding: line.id)
                DockChoice(title: pass.name, detail: pass.statusText(at: Date()),
                           trailing: left.map { $0 >= line.quantity ? "可抵 \($0) 次" : "剩 \(max($0, 0)) 次" } ?? "不限次數",
                           enabled: left.map { $0 >= line.quantity } ?? true) {
                    panel = nil
                    model.redeem(line, with: pass, in: t)
                }
            }
        case .variant:
            if let id = line.itemId, let item = model.catalog.item(id) {
                VariantMatrix(item: item, selectedId: line.skuId, compact: true) { v in
                    panel = nil
                    model.changeVariant(line, to: v, in: t)
                }
                Text("小字是這家店的庫存；價格不一樣的會照新規格的價格")
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 6)
            }
        case .lineDiscount:
            DockChoice(title: "打折（%）", detail: "在右邊打要折掉的 %") {
                panel = nil
                Task { await model.discount(line, in: t, kind: .percent) }
            }
            DockChoice(title: "折價（元）", detail: "在右邊打折掉多少錢") {
                panel = nil
                Task { await model.discount(line, in: t, kind: .amount) }
            }
            if line.discount != nil {
                DockChoice(title: "取消折扣", trailing: line.discount?.label) {
                    panel = nil
                    model.clearDiscount(line, in: t)
                }
            }
            DockChoice(title: "改價", detail: "改單價（要領班以上）", trailing: line.unitPrice.formatted) {
                panel = nil
                Task { await model.changePrice(line, in: t) }
            }
        case .lineCourse:
            DockChoice(title: "座位", detail: "第幾位客人（分開結帳用）", trailing: line.seat.map { "座 \($0)" }) {
                panel = nil
                Task { await model.setSeat(line, in: t) }
            }
            if !line.isSent {
                DockChoice(title: "馬上做", selected: line.course <= 1) {
                    panel = nil
                    model.setCourse(0, for: line, in: t)
                }
                DockChoice(title: "第 2 道", detail: "等「催菜」再做", selected: line.course == 2) {
                    panel = nil
                    model.setCourse(2, for: line, in: t)
                }
                DockChoice(title: "第 3 道", detail: "等「催菜」再做", selected: line.course == 3) {
                    panel = nil
                    model.setCourse(3, for: line, in: t)
                }
            }
        case .ticketDiscount, .ticketMore, .salesperson, .batchDiscount:
            EmptyView()
        }
    }

    /// 勾起來的這幾行一起打折：鍵盤問一次、授權一次（照折得最多的那一行算），每一行打一樣的折扣（model.discount(lines…)）
    @ViewBuilder
    private func batchDiscountPanel(in t: Ticket) -> some View {
        let lines = checkedLines(in: t)
        DockChoice(title: "打折（%）", detail: "每一項打一樣的折，在右邊打要折掉的 %", enabled: !lines.isEmpty) {
            panel = nil
            Task { await model.discount(lines, in: t, kind: .percent) }
        }
        DockChoice(title: "折價（元）", detail: "每一項折一樣多，在右邊打折掉多少錢", enabled: !lines.isEmpty) {
            panel = nil
            Task { await model.discount(lines, in: t, kind: .amount) }
        }
        if lines.contains(where: { $0.discount != nil }) {
            DockChoice(title: "取消折扣", detail: "勾起來的都回到原價") {
                panel = nil
                model.clearDiscount(lines, in: t)
            }
        }
    }

    /// 整張單的選擇
    @ViewBuilder
    private func ticketPanel(_ p: TicketPanel, in t: Ticket) -> some View {
        switch p {
        case .ticketDiscount:
            DockChoice(title: "整單打折（%）", detail: "在右邊打要折掉的 %") {
                panel = nil
                Task { await model.discountTicket(t, kind: .percent) }
            }
            DockChoice(title: "整單折價（元）", detail: "在右邊打折掉多少錢") {
                panel = nil
                Task { await model.discountTicket(t, kind: .amount) }
            }
            couponChoices(t)
            if t.serviceChargeBps > 0 {
                DockChoice(title: "免收服務費", detail: "要領班以上", trailing: percentText(bps: t.serviceChargeBps)) {
                    panel = nil
                    Task { await model.waiveServiceCharge(t) }
                }
            }
            if model.store.tipsEnabled {
                DockChoice(title: "小費", detail: "不開發票", trailing: t.tip.cents > 0 ? t.tip.formatted : nil) {
                    panel = nil
                    Task { await model.setTip(t) }
                }
            }
        case .ticketMore:
            // 用餐方式在單子的頁首（內用／外帶／外送的分段控制），這裡不再放一份
            if tracksGuests(t) {
                DockChoice(title: "人數", detail: "在右邊打幾位", trailing: t.guests > 0 ? "\(t.guests) 位" : nil) {
                    panel = nil
                    Task { await model.setGuests(t) }
                }
            }
            Eyebrow("單子").padding(.top, 8)
            if t.member != nil {
                DockChoice(title: "換會員", detail: "在右邊打電話") {
                    panel = nil
                    Task { await model.attachMember(to: t) }
                }
                DockChoice(title: "移除會員", detail: "用他的課程卡抵的會一起取消") {
                    panel = nil
                    model.detachMember(from: t)
                }
            }
            DockChoice(title: "自訂品項", detail: "菜單上沒有的（開瓶費、運費）") {
                panel = nil
                askingCustom = true
            }
            // 手機的「掃碼」在「⋯」裡（同一個動作只出現一次）
            if !model.isPhone {
                DockChoice(title: "掃碼", detail: "用相機掃商品、會員卡、載具、折價券") {
                    panel = nil
                    model.requestScan(.any)
                }
            }
            ForEach(laterCourses(t), id: \.self) { c in
                DockChoice(title: "催菜：第 \(c) 道", detail: "開始做第 \(c) 道") {
                    panel = nil
                    model.fire(course: c, of: t)
                }
            }
            DockChoice(title: "拆單", detail: "選品項搬到新的一張", enabled: t.itemCount > 1) {
                panel = nil
                splitting = t
            }
            if model.visibleSections.contains(.floor) {
                DockChoice(title: "換桌／併桌", detail: "到桌位圖") {
                    panel = nil
                    model.go(.floor)
                }
            }
            if model.canPrintBill {
                DockChoice(title: "印結帳單", detail: t.billPrintedAt.map { (t.billSentFrom == nil ? "已印過 " : "已送到結帳櫃台 ") + TaipeiTime.clock($0) }) {
                    panel = nil
                    model.printBill(t)
                }
            }
        case .salesperson:
            staffChoices(salespeople, selected: t.salespersonId, none: "不指定（算給開單的人）") { id in
                model.setSalesperson(id, for: t)
            }
        case .performer, .assistant, .passes, .variant, .lineDiscount, .lineCourse, .batchDiscount:
            EmptyView()
        }
    }

    /// 整單折扣面板裡的折價券：掃、打代碼（英數，用系統的文字框）；已經有整單折扣的可以拿掉
    @ViewBuilder
    private func couponChoices(_ t: Ticket) -> some View {
        DockChoice(title: "掃折價券", detail: "用相機掃折價券的 QR Code、條碼") {
            panel = nil
            model.requestScan(.coupon)
        }
        DockChoice(title: "輸入折價券代碼", detail: "英文、數字，例如 YG-A3B2C1") {
            panel = nil
            couponText = ""
            askingCoupon = true
        }
        if let d = t.discount {
            DockChoice(title: d.isCoupon ? "拿掉折價券" : "取消整單折扣", detail: d.isCoupon ? d.reason : nil,
                       trailing: d.isCoupon ? d.couponCode : d.label) {
                panel = nil
                model.clearTicketDiscount(t)
            }
        }
    }

    /// 選人：「不指定」＋每一位（職稱、上班中）
    @ViewBuilder
    private func staffChoices(_ list: [StaffMember], selected: String?, none: String, pick: @escaping (String?) -> Void) -> some View {
        DockChoice(title: none, selected: selected == nil) {
            panel = nil
            pick(nil)
        }
        ForEach(list) { s in
            let working = model.isClockedIn(s)
            let info = [s.title, working ? "上班中" : nil].compactMap { $0 }.joined(separator: "・")
            DockChoice(title: s.name, detail: info.isEmpty ? nil : info,
                       selected: s.id == selected) {
                panel = nil
                pick(s.id)
            }
        }
    }
}

// MARK: - 頁首的小元件

/// 單子頁首的用餐方式：小的分段控制（選到的那一段墨色實心，和其他頁的切換同一種）。
/// 不能改（結帳中）：選到的照樣看得出來，其他的淡掉
private struct OrderTypeSwitch: View {
    let types: [OrderType]
    let selected: OrderType
    var enabled = true
    let pick: (OrderType) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(types, id: \.self) { type in
                Button {
                    pick(type)
                } label: {
                    // 選到的變粗也不變寬：三段的位置不會跟著動
                    SteadyText(type.label, size: 13.5, on: type == selected)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                }
                .buttonStyle(OrderTypeSegmentStyle(selected: type == selected))
                .accessibilityAddTraits(type == selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("用餐方式")
        .accessibilityHint(enabled ? "" : "結帳中不能改；要改先回到點餐")
    }
}

private struct OrderTypeSegmentStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Theme.page : (isEnabled ? Theme.ink2 : Theme.faint))
            .background(selected ? Theme.ink : (configuration.isPressed ? Theme.press : Color.clear),
                        in: .rect(cornerRadius: Metric.radiusSm, style: .continuous))
            .contentShape(.rect)
            .animation(Motion.fast, value: selected)
    }
}

/// 單子頁首只有字的小鈕（選取、完成、全選）：品牌橘的字（strong）或墨色的字；按下去底色深一點
private struct HeaderTextButtonStyle: ButtonStyle {
    var strong = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(14.5, strong ? .semibold : .medium))
            .foregroundStyle(strong ? Theme.accentText : Theme.ink2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .background(configuration.isPressed ? Theme.press : Color.clear, in: .rect(cornerRadius: Metric.radiusSm))
            .contentShape(.rect)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - 一行

/// 單子上的一行：只顯示（數量、名字、規格、時間、設計師、卡抵、狀態），不放按鈕。
/// 點一下選起來（品牌橘的框），右欄換成這一行的動作、鍵盤問它的數量；再點一下取消。左右滑在 TicketColumn（SwipeRow）。
/// 「選取」中：左邊多一個勾選的圓圈，點一下＝勾／不勾（勾了是淡淡的品牌橘底）。
/// 作廢的行不會出現在這裡（單子欄只列還要的）
struct LineRow: View {
    @Environment(POSModel.self) private var model
    let line: TicketLine
    let ticket: Ticket
    let editable: Bool
    var selected = false
    /// 頁首按了「選取」：一次勾好幾行
    var selecting = false
    var checked = false
    var onSelect: () -> Void = {}

    private var item: MenuItem? { line.itemId.flatMap { model.catalog.item($0) } }

    /// 美業、課程的服務：每一行有設計師／教練（已經指定了的，換到其他模式也看得到）
    private var showsStaff: Bool {
        line.isActive && ((model.mode.staffPerLine && line.itemKind == .service) || line.staffId != nil)
    }

    /// 餐飲、零售（「還沒送出」的點只有這幾個模式用）
    private var isClassic: Bool { !model.mode.staffPerLine && !model.mode.staffPerTicket }

    var body: some View {
        let passes = editable && line.isActive && line.redeem == nil ? model.redeemablePasses(for: line, in: ticket) : []
        Button(action: onSelect) {
            summary(passes)
        }
        .buttonStyle(.row)
        .background { rowBackground }
        .overlay {
            if selected {
                Rectangle()
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected || (selecting && checked) ? .isSelected : [])
        .animation(Motion.spring, value: line.redeem)
        .animation(Motion.fast, value: selected)
        .animation(Motion.fast, value: checked)
    }

    private var hint: String {
        guard editable && line.isActive else { return "" }
        if selecting { return checked ? "點一下取消勾選" : "點一下勾起來" }
        return selected ? "再點一下取消選取" : "點一下，右邊的鍵盤改這一行的數量；左右滑可以加減、刪除"
    }

    // MARK: 這一行（只顯示）

    private func summary(_ passes: [MemberPass]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if selecting {
                checkCircle
                    .padding(.trailing, -2)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            quantityBox

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.name)
                        .font(.brand(15.5, .medium))
                        .multilineTextAlignment(.leading)
                    if !line.isSent && line.isActive && isClassic {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .accessibilityLabel("還沒送出")
                    }
                }
                .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
                metaRow
                if !line.modifiers.isEmpty {
                    Text(line.modifierText)
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                if !line.note.isEmpty {
                    Text("※ \(line.note)")
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.accentText)
                        .multilineTextAlignment(.leading)
                }
                kindRow
                if showsStaff {
                    staffRow
                        .padding(.top, 3)
                }
                redeemStatus(passes)
                HStack(spacing: 6) {
                    if let d = line.discount, line.isActive { StatusBadge(d.label, tone: .gold) }
                    if line.course >= 2 { StatusBadge("第 \(line.course) 道", tone: .info) }
                    if let s = line.seat { StatusBadge("座 \(s)", tone: .neutral) }
                    if line.isSent && line.isActive { StatusBadge(line.kitchen.label, tone: kitchenTone) }
                }
            }
            Spacer(minLength: 6)
            priceColumn
        }
        .padding(.horizontal, 18)
        // 緊一點，單子看得到更多行；最矮也有 52（數量方塊 34＋上下 9），手指照樣點得到
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .contentShape(.rect)
    }

    /// 「選取」中：勾選的圓圈（勾了＝品牌橘實心＋白色的勾）；和數量方塊一樣高、置中
    private var checkCircle: some View {
        ZStack {
            Circle()
                .fill(checked ? Theme.accent : Theme.surface)
            Circle()
                .strokeBorder(checked ? Theme.accent : Theme.faint, lineWidth: 1.5)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
            }
        }
        .frame(width: 24, height: 24)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selecting && checked {
            // 勾起來的：淡淡的品牌橘底（右欄的「已選 3 項」就是這幾行）
            Theme.accentSoft
        } else if selected {
            // 選起來的：亮一階的底、左邊一條品牌橘、外框（右欄對應的就是這一行）
            (line.redeem != nil ? Theme.accentSoft : Theme.surface)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 4) }
        } else if line.redeem != nil && line.isActive {
            // 用課程卡抵的行：淡淡的品牌橘底、左邊一條橘線，一眼看得出不收錢
            Theme.accentSoft.opacity(0.7)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
    }

    private var quantityBox: some View {
        Text("\(line.quantity)")
            .font(.brand(17, .semibold))
            .monospacedDigit()
            .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
            .frame(width: 34, height: 34)
            .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusSm))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm)
                    .strokeBorder(selected ? Theme.ink : Theme.line, lineWidth: selected ? 1.5 : 1)
            }
            .accessibilityLabel("數量 \(line.quantity)")
    }

    private var priceColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if line.redeem != nil && line.isActive {
                // 用課程卡抵：不收錢，原價劃掉給客人看
                Text("卡抵")
                    .font(.brand(14.5, .semibold))
                    .foregroundStyle(Theme.accentText)
                Text(listValue.short)
                    .font(.brand(12, .regular))
                    .monospacedDigit()
                    .strikethrough()
                    .foregroundStyle(Theme.faint)
            } else {
                Text((line.gross - line.lineDiscount).short)
                    .font(.brand(15.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(line.isActive ? Theme.ink : Theme.faint)
            }
        }
    }

    /// 原價（用卡抵之前）
    private var listValue: Money {
        (line.unitPrice + Money.sum(line.modifiers.map(\.priceDelta))) * line.quantity
    }

    private var kitchenTone: Tone {
        switch line.kitchen {
        case .new: .neutral
        case .sent: .info
        case .preparing: .warning
        case .ready: .active
        case .served: .neutral
        }
    }

    // MARK: 規格、時間

    @ViewBuilder
    private var metaRow: some View {
        let minutes: Int? = line.itemKind == .service ? line.durationMinutes : nil
        if line.variantName != nil || minutes != nil {
            HStack(spacing: 8) {
                if let v = line.variantName {
                    HStack(spacing: 5) {
                        if let item, let first = item.variant(line.skuId).flatMap({ VariantPanel.colorValue(of: $0, in: item) }) {
                            ColorSwatchDot(color: VariantPanel.swatchFill(for: first), size: 10)
                        }
                        Text(v)
                    }
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(line.isActive ? Theme.ink2 : Theme.faint)
                }
                if let m = minutes {
                    HStack(spacing: 4) {
                        HeroIcon("clock", size: 11)
                        Text(TicketColumn.duration(m * line.quantity))
                            .monospacedDigit()
                    }
                    .font(.brand(12, .medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Theme.press, in: .capsule)
                    .overlay { Capsule().strokeBorder(Theme.hair) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("服務時間 \(TicketColumn.duration(m * line.quantity))")
                }
            }
        }
    }

    // MARK: 課程卡、儲值

    @ViewBuilder
    private var kindRow: some View {
        if line.itemKind == .pass || line.itemKind == .storedValue {
            let isPass = line.itemKind == .pass
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusBadge(isPass ? "課程卡" : "儲值", tone: isPass ? .info : .gold)
                if let detail = kindDetail {
                    Text(detail)
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
    }

    /// 課程卡：「10 次・180 天內・續約：接在 11/3 後」；儲值：「儲值金 +11,000」
    private var kindDetail: String? {
        switch line.itemKind {
        case .pass:
            var parts: [String] = []
            if let spec = line.pass { parts.append(spec.summary) }
            if let start = line.passStartsAt { parts.append("續約：接在 \(Self.monthDay(start.addingTimeInterval(-1))) 後") }
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        case .storedValue:
            guard let credit = line.credit else { return nil }
            return "儲值金 +\((credit * line.quantity).plain)"
        case .goods, .service:
            return nil
        }
    }

    private static func monthDay(_ d: Date) -> String {
        let c = TaipeiTime.components(d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    // MARK: 設計師／教練、助理（只顯示；選起來才改）

    private var staffRow: some View {
        HStack(spacing: 6) {
            staffTag(line.staffId, placeholder: "未指定\(model.mode.staffTitle)", prefix: nil, prominent: true)
            if let a = line.assistantId {
                staffTag(a, placeholder: "", prefix: "助理", prominent: false)
            }
        }
    }

    private func staffTag(_ id: String?, placeholder: String, prefix: String?, prominent: Bool) -> some View {
        let s = model.staffMember(id)
        let title: String = s.map { member in (prefix.map { "\($0) " } ?? "") + member.name } ?? placeholder
        let tint: Color = s == nil ? (prominent ? Theme.accentText : Theme.muted) : Theme.ink
        let border: Color = s == nil && prominent ? Theme.accent.opacity(0.45) : Theme.line
        let dash: [CGFloat] = s == nil ? [3, 2] : []
        return HStack(spacing: 5) {
            if let s {
                StaffAvatar(name: s.name, swatch: s.swatch, size: 18)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.brand(12.5, .medium))
        .padding(.leading, s == nil ? 9 : 3)
        .padding(.trailing, 9)
        .frame(height: 26)
        .foregroundStyle(tint)
        .overlay { Capsule().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dash)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    // MARK: 課程卡抵用（狀態）

    @ViewBuilder
    private func redeemStatus(_ passes: [MemberPass]) -> some View {
        if let r = line.redeem, line.isActive {
            HStack(alignment: .center, spacing: 6) {
                HeroIcon("ticket", size: 14)
                Text("卡抵・\(r.name)")
                    .font(.brand(12.5, .semibold))
                    .lineLimit(1)
                if let left = redeemLeft(r) {
                    Text(left)
                        .font(.brand(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(Theme.accent, in: .capsule)
                }
            }
            .foregroundStyle(Theme.accentText)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(redeemText(r))
        } else if !passes.isEmpty && !selected {
            // 提示：這一行可以用客人的卡抵（點一下這一行就有「用卡抵」）
            HStack(spacing: 5) {
                HeroIcon("ticket", size: 12)
                Text(passes.count == 1 ? "可用\(passes[0].name)抵" : "可用課程卡抵（\(passes.count) 張）")
                    .lineLimit(1)
            }
            .font(.brand(12, .medium))
            .foregroundStyle(Theme.accentText)
            .padding(.top, 2)
        }
    }

    /// 「卡抵・剪髮 10 次卡（剩 7 次）」：剩的次數已經扣掉還沒結帳的單（包括這一行）
    private func redeemText(_ r: PassRedemption) -> String {
        guard let left = redeemLeft(r) else { return "卡抵・\(r.name)" }
        return "卡抵・\(r.name)（\(left)）"
    }

    /// 「剩 7 次」（次數卡）、「到 2026/11/3」（期間會籍）；查不到帳戶是 nil
    private func redeemLeft(_ r: PassRedemption) -> String? {
        guard let pass = model.account(for: ticket.member)?.passes.first(where: { $0.id == r.passId }) else { return nil }
        if let left = model.visitsLeft(on: pass) { return "剩 \(max(left, 0)) 次" }
        return pass.statusText(at: Date())
    }
}

// MARK: - 會員條

/// 單子上的會員：名字、電話、等級；查得到帳戶就有儲值金與課程卡。點一下展開看每一張卡、備註、上次做了什麼
struct TicketMemberStrip: View {
    @Environment(POSModel.self) private var model
    let ticket: Ticket
    @Binding var open: Bool
    @State private var looking = false

    var body: some View {
        if let ref = ticket.member {
            let info = model.member(for: ref)
            let account = model.account(for: ref)
            let usableCount = account?.usablePasses(at: Date()).count ?? 0
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(Motion.fast) { open.toggle() }
                    model.touch()
                } label: {
                    summary(ref, account: account, passCount: usableCount)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "收起來" : "看課程卡與備註")
                if open {
                    Rule(color: Theme.accent.opacity(0.2))
                    detail(ref, info: info, account: account)
                        .transition(.opacity)
                }
            }
            .background(Theme.accentSoft, in: .rect(cornerRadius: Metric.radius))
            .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.accent.opacity(0.22)) }
            .task(id: ref.id) { await lookUp(ref, force: false) }
        }
    }

    private func summary(_ ref: MemberRef, account: MemberAccount?, passCount: Int) -> some View {
        let name = ref.name ?? ref.maskedPhone
        let sub = [ref.name != nil ? ref.maskedPhone : nil, ref.id == nil ? "離線先記電話" : nil].compactMap { $0 }.joined(separator: "・")
        return HStack(alignment: .center, spacing: 10) {
            Text(String(name.prefix(1)))
                .font(.brand(15, .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.brand(15, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let tier = ref.tierName, !tier.isEmpty {
                        Text(tier)
                            .font(.brand(10.5, .semibold))
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay { RoundedRectangle(cornerRadius: Metric.chip).strokeBorder(Theme.accent.opacity(0.5)) }
                    }
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.brand(12, .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                if let account {
                    HStack(spacing: 6) {
                        pill(icon: "banknotes", text: "儲值 \(account.wallet.formatted)", strong: account.wallet.cents > 0)
                        pill(icon: "ticket", text: passCount > 0 ? "\(passCount) 張卡" : "沒有卡", strong: passCount > 0)
                    }
                } else if looking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("查儲值金、課程卡…")
                            .font(.brand(11.5, .medium))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer(minLength: 6)
            HeroIcon("chevron-down", size: 11)
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }

    /// 會員條上的小膠囊（儲值金、幾張卡）
    private func pill(icon: String, text: String, strong: Bool) -> some View {
        HStack(spacing: 4) {
            HeroIcon(icon, size: 11)
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.brand(11.5, .semibold))
        .foregroundStyle(strong ? Theme.ink : Theme.muted)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Theme.surface, in: .capsule)
        .overlay { Capsule().strokeBorder(strong ? Theme.accent.opacity(0.35) : Theme.line) }
    }

    private func detail(_ ref: MemberRef, info: Member?, account: MemberAccount?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account {
                let passes = sortedPasses(account)
                if passes.isEmpty {
                    Text("沒有課程卡、會籍")
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(passes) { p in
                        let usable = p.isUsable(at: Date())
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            HeroIcon("ticket", size: 12)
                            Text(p.name)
                                .font(.brand(13, .medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(p.statusText(at: Date()))
                                .font(.brand(12, .regular))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .foregroundStyle(usable ? Theme.ink : Theme.faint)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if model.features.accounts && ref.id != nil {
                HStack(spacing: 8) {
                    Text(looking ? "查儲值金與課程卡…" : "查不到儲值金與課程卡（離線？）")
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 6)
                    if !looking {
                        Button("再查一次") { Task { await lookUp(ref, force: true) } }
                            .buttonStyle(.brand(.quiet, size: .sm))
                    }
                }
            }
            if let note = info?.note, !note.isEmpty {
                Text("※ \(note)")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let visit = info?.recentVisits?.first {
                Text(lastVisit(visit))
                    .font(.brand(12, .regular))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            if account == nil && info?.note == nil && info?.recentVisits?.first == nil && !(model.features.accounts && ref.id != nil) {
                Text(ref.maskedPhone)
                    .font(.brand(12.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 能用的排前面、快到期的排前面（最多 8 張）
    private func sortedPasses(_ account: MemberAccount) -> [MemberPass] {
        let now = Date()
        let sorted = account.passes.sorted { a, b in
            let ua = a.isUsable(at: now) ? 0 : 1
            let ub = b.isUsable(at: now) ? 0 : 1
            if ua != ub { return ua < ub }
            return (a.expiresAt ?? .distantFuture) < (b.expiresAt ?? .distantFuture)
        }
        return Array(sorted.prefix(8))
    }

    /// 「上次 2026/10/2・剪髮、染髮・Cameron」
    private func lastVisit(_ v: MemberVisit) -> String {
        var parts = ["上次 \(v.at.dayText)"]
        if !v.items.isEmpty { parts.append(v.items.joined(separator: "、")) }
        if !v.staffNames.isEmpty { parts.append(v.staffNames.joined(separator: "、")) }
        return parts.joined(separator: "・")
    }

    /// 還沒查過這位會員（例如從預約、報到帶進來的）就跟後台查一次：儲值金、課程卡、備註
    private func lookUp(_ ref: MemberRef, force: Bool) async {
        guard ref.id != nil, model.features.members || model.features.accounts, !looking else { return }
        guard force || model.member(for: ref) == nil else { return }
        looking = true
        await model.refreshMember(ref)
        looking = false
    }
}

// MARK: - 服務時間條

/// 美業、課程：這張單的服務一共多久——一條分段的時間條（每一段是一個服務，顏色是做的人），旁邊是總時間與大約幾點做完
struct ServiceDurationBar: View {
    struct Segment: Identifiable {
        var id: String
        var name: String
        var minutes: Int
        var color: Color
        var staffName: String?
    }

    let segments: [Segment]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    HeroIcon("clock", size: 13)
                    Text("服務時間")
                }
                .font(.brand(14, .medium))
                .foregroundStyle(Theme.ink2)
                Spacer(minLength: 8)
                Text(TicketColumn.duration(total))
                    .font(.brand(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            GeometryReader { geo in
                let gap: CGFloat = 3
                let usable = max(geo.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
                HStack(spacing: gap) {
                    ForEach(segments) { s in
                        Capsule()
                            .fill(s.color)
                            .frame(width: max(usable * CGFloat(s.minutes) / CGFloat(max(total, 1)), 6))
                    }
                }
            }
            .frame(height: 8)
            .background(Theme.press, in: .capsule)
            Text("現在開始，大約 \(TaipeiTime.clock(Date().addingTimeInterval(TimeInterval(total * 60)))) 做完")
                .font(.brand(11.5, .regular))
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let parts: [String] = segments.map { s in
            let who = s.staffName.map { "（\($0)）" } ?? ""
            return "\(s.name) \(s.minutes) 分\(who)"
        }
        return "服務時間 \(TicketColumn.duration(total))：\(parts.joined(separator: "、"))"
    }
}

// MARK: - 拆單

/// 拆單：選要搬到新單的品項與數量
struct SplitSheet: View {
    @Environment(POSModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    @State private var moving: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("拆單・\(ticket.number)")
                    Headline("Split the *check*", role: .h3)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.brand(.ghost, size: .sm))
            }
            .padding(24)
            Rule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ticket.activeLines) { line in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.displayName).font(.brand(16, .medium))
                                if !line.modifiers.isEmpty {
                                    Text(line.modifierText).font(.brand(12.5, .regular)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            Text("共 \(line.quantity)")
                                .font(.brand(13, .regular))
                                .foregroundStyle(Theme.muted)
                            Stepper(value: Binding(get: { moving[line.id] ?? 0 }, set: { moving[line.id] = min(max($0, 0), line.quantity) }), in: 0...line.quantity) {
                                Text("搬 \(moving[line.id] ?? 0)")
                                    .font(.brand(16, .semibold))
                                    .monospacedDigit()
                            }
                            .fixedSize()
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        Rule(color: Theme.hair)
                    }
                }
            }
            Rule()
            HStack {
                Button("全部選") { for l in ticket.activeLines { moving[l.id] = l.quantity } }
                    .buttonStyle(.brand(.quiet, size: .md))
                Spacer()
                Button("拆出新的一張") {
                    model.split(ticket, moving: moving)
                    dismiss()
                }
                .buttonStyle(.brand(.accent, size: .lg, arrow: true))
                .disabled(!canSplit)
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.sheet)
    }

    /// 至少搬一項，而且不能全部搬走（全部搬走就不是拆單了）
    private var canSplit: Bool {
        let total = moving.values.reduce(0, +)
        let all = ticket.activeLines.reduce(0) { $0 + $1.quantity }
        return total > 0 && total < all
    }
}

/// 單子上的提醒：折價券還沒到最低消費（改了品項），結帳前會拿掉
struct CouponMinimumWarning: View {
    let minimum: Money
    let short: Money

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HeroIcon("exclamation-triangle", size: 15)
                .padding(.top, 1)
            Text("未達最低消費 \(minimum.formatted)（還差 \(short.formatted)），結帳前會拿掉折價券")
                .font(.brand(12.5, .medium))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.warningFG)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Tone.warning.background, in: .rect(cornerRadius: Metric.radius))
        .accessibilityElement(children: .combine)
    }
}
