import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 桌位：後台排好的桌位圖（0–100 的格子，縮放到畫面）。每一桌照座位數畫椅子，桌況用顏色＋字標示。
///
///   ┌ Floor plan ──────────────────────── 空桌 6  用餐中 4  待清桌 1  [編輯] ┐
///   │ ● 空桌 ● 已預約 ● 已入座 ● 用餐中 ● 待結帳 ● 待清桌 ● 要注意           │
///   │ ┌──────────────────────────────────────────────────────────────────┐ │
///   │ │   ▭ ▭        ▭ ▭•                         ┌ A2  用餐中 ─────────┐  │ │
///   │ │  ▯ A1 ▯     ▯ A2 ▯  ← 用餐中＝實心橘       │ 服務人員  人數      │  │ │
///   │ │   ▭ ▭        ▭ ▭                          │ 金額      開桌      │  │ │
///   │ │                                           │ ・2 份餐好了        │  │ │
///   │ │                                           └─────────────────────┘  │ │
///   │ ├──────────────────────────────────────────────────────────────────┤ │
///   │ │  1F 3/11   2F 1/6   戶外 0/3                     下一組 18:30 …   │ │
///   └──────────────────────────────────────────────────────────────────────┘
///
/// 左邊選、右邊做：點一桌＝選起來（桌子旁邊的卡片只給看：服務人員、人數、金額、要注意的事），
/// 這一桌的動作都在右欄（.dockSelection）：大鍵看桌況是入座（鍵盤問人數）、點餐／加點、結帳或清桌，
/// 其他（換桌、併桌、印結帳單、改人數、訂位入座…）是上面的動作鍵。再點一次同一桌＝取消選取。
/// 店長在右欄按「編輯桌位」可以直接在 iPad 上拖拉排桌，存回後台。
struct FloorView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var areaId: String?
    @State private var selectedTableId: String?
    /// 同一桌有好幾張單（拆過單）時，卡片上看的是哪一張
    @State private var cardTicketId: String?
    /// 卡片量出來的大小（放在桌子旁邊、不超出桌位圖）
    @State private var cardSize = CGSize(width: 296, height: 330)
    /// 正在帶位的桌子（右側鍵盤正在問人數）
    @State private var seatingTableId: String?
    /// 換桌、併桌：選好單子，等著點目的地
    @State private var pick: FloorPick?

    // MARK: 編輯（只改本機的一份，按「儲存」才送後台）

    @State private var editing = false
    @State private var draft: [FloorArea] = []
    @State private var draggingId: String?
    @State private var dragOffset: CGSize = .zero
    @State private var saving = false

    private static let cardWidth: CGFloat = 296

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if areas.isEmpty {
                emptyFloor
            } else {
                if editing {
                    Text("拖拉桌子調整位置，放開會對齊格線；點桌子改桌號、座位、形狀與大小。")
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                } else {
                    legend
                }
                HStack(alignment: .top, spacing: 16) {
                    canvasPanel
                    if editing {
                        inspector
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dockSelection(dockItem)
        // 結帳櫃台：手機送來結帳的單（沒選桌子、沒在排桌位時在右欄）
        .checkoutHandoffDock(enabled: !editing)
        .onAppear {
            restoreArea()
            // 截圖：先選一桌用餐中的
            if LaunchArguments.preselect, let t = currentArea?.tables.first(where: { !model.state.openTickets(at: $0.id).isEmpty }) { selectedTableId = t.id }
        }
    }

    // MARK: - 資料

    private var areas: [FloorArea] { editing ? draft : model.floor.areas }

    private var currentArea: FloorArea? {
        areas.first { $0.id == areaId } ?? areas.first
    }

    private var canEdit: Bool { model.currentStaff?.can(.editFloor) == true }

    private var anim: Animation? { reduceMotion ? nil : Motion.ease }

    private func info(_ t: DiningTable, soon: Set<String>, now: Date) -> FloorTableInfo {
        FloorTableInfo.make(t, model: model, soon: soon, now: now)
    }

    /// 回到桌位時：停在右邊那張單所在的區域
    private func restoreArea() {
        if let t = model.selectedTicket, let tableId = t.tableIds.first,
           let area = model.floor.areas.first(where: { a in a.tables.contains { $0.id == tableId } }) {
            areaId = area.id
        }
        if areaId == nil { areaId = model.floor.areas.first?.id }
    }

    private var nextReservation: Reservation? {
        let from = Date().addingTimeInterval(-15 * 60)
        return model.reservations
            .filter { $0.kind == .reservation && $0.status.isActive && $0.startsAt > from }
            .min { $0.startsAt < $1.startsAt }
    }

    // MARK: - 上面

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            PageTitle(title: editing ? "Edit the *floor*" : "Floor *plan*", subtitle: editing ? "排桌位" : "桌位")
            Spacer(minLength: 12)
            // 頁首只放標題與數字；編輯、儲存、新增桌子在右欄
            if !editing && !areas.isEmpty {
                counts
            }
        }
    }

    private var counts: some View {
        let soon = model.reservedSoon
        let statuses = model.floor.allTables.map { model.state.status(of: $0.id, reservedSoon: soon) }
        let free = statuses.filter { $0 == .available }.count
        let dining = statuses.filter { $0 == .seated || $0 == .ordering || $0 == .billing }.count
        let dirty = statuses.filter { $0 == .needsCleaning }.count
        return HStack(alignment: .bottom, spacing: 22) {
            FloorCount(label: TableStatus.available.label, value: free, color: Theme.table(.available))
            FloorCount(label: TableStatus.ordering.label, value: dining, color: Theme.table(.ordering))
            FloorCount(label: TableStatus.needsCleaning.label, value: dirty, color: Theme.table(.needsCleaning))
        }
    }

    private static let legendOrder: [TableStatus] = [.available, .reserved, .seated, .ordering, .billing, .needsCleaning]

    private var legend: some View {
        FlowLayout(spacing: 16, rowSpacing: 8) {
            ForEach(Self.legendOrder, id: \.self) { s in
                HStack(spacing: 6) {
                    FloorLegendSwatch(status: s)
                    Text(s.label)
                        .font(.brand(12.5, .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 6) {
                FloorAttentionDot(size: 7)
                Text("要注意：餐好了、待付款、超時、訂位快到")
                    .font(.brand(12.5, .medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 桌位圖＋下方的區域分頁

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            canvas
            Rule()
            areaStrip
        }
        .background(Theme.pageAlt.opacity(0.55), in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(editing ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let inset: CGFloat = 20
            let size = CGSize(width: max(geo.size.width - inset * 2, 1), height: max(geo.size.height - inset * 2, 1))
            // 每 30 秒重畫一次：用餐分鐘數、快到的訂位、超時
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                canvasLayer(size: size, now: ctx.date)
                    .padding(inset)
            }
        }
        .overlay {
            if (currentArea?.tables ?? []).isEmpty {
                EmptyState(
                    icon: "squares-2x2",
                    title: "這個區域還沒有桌子",
                    message: editing ? "按右邊的「新增桌子」開始排" : (canEdit ? "按右邊的「編輯桌位」新增桌子" : "請店長到後台「門市 POS → 桌位」排桌子")
                )
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { pickBanner }
    }

    private func canvasLayer(size: CGSize, now: Date) -> some View {
        let soon = model.reservedSoon
        let infos = (currentArea?.tables ?? []).map { info($0, soon: soon, now: now) }
        let unitX = size.width / 100
        let unitY = size.height / 100
        let selected = infos.first { $0.id == selectedTableId }
        return ZStack(alignment: .topLeading) {
            FloorDotGrid(strong: editing)
                .contentShape(.rect)
                .onTapGesture { backgroundTapped() }
            ForEach(infos) { i in
                placed(i, unitX: unitX, unitY: unitY, now: now)
            }
            if !editing, pick == nil, let s = selected {
                card(for: s, rect: footprint(s.table, unitX: unitX, unitY: unitY), canvas: size, now: now)
                    .id(s.id)
                    .zIndex(10)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 一桌在圖上佔的地方（桌子＋椅子）：格子座標 × 每格的點數
    private func footprint(_ t: DiningTable, unitX: CGFloat, unitY: CGFloat) -> CGRect {
        let r = CGRect(x: CGFloat(t.x) * unitX, y: CGFloat(t.y) * unitY,
                       width: max(CGFloat(t.width) * unitX, 36), height: max(CGFloat(t.height) * unitY, 36))
        // 格子的橫、直各自照畫面縮放：圓桌要一直是圓的（直的 iPad 上不然會被拉成細長的橢圓）
        guard t.shape == .round, t.width == t.height else { return r }
        let side = min(r.width, r.height)
        return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
    }

    @ViewBuilder
    private func placed(_ i: FloorTableInfo, unitX: CGFloat, unitY: CGFloat, now: Date) -> some View {
        let t = i.table
        let rect = footprint(t, unitX: unitX, unitY: unitY)
        let dragging = draggingId == t.id
        let tile = FloorTableTile(
            info: i,
            size: rect.size,
            now: now,
            selected: selectedTableId == t.id || seatingTableId == t.id || isPickSource(t.id),
            editing: editing,
            target: pick.map { eligible(i, for: $0) }
        )
        Group {
            if editing {
                tile
                    .onTapGesture { selectInEditor(t.id) }
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { v in
                                if draggingId != t.id {
                                    draggingId = t.id
                                    selectedTableId = t.id
                                }
                                dragOffset = v.translation
                            }
                            .onEnded { v in
                                finishDrag(t, translation: v.translation, unitX: unitX, unitY: unitY)
                            }
                    )
                    .accessibilityAddTraits(.isButton)
            } else {
                Button {
                    tap(i)
                } label: {
                    tile
                }
                .buttonStyle(PressScale(scale: 0.97))
            }
        }
        .offset(dragging ? dragOffset : .zero)
        .position(x: rect.midX, y: rect.midY)
        .zIndex(dragging ? 2 : (selectedTableId == t.id ? 1 : 0))
    }

    // MARK: 下方的區域分頁

    private var areaStrip: some View {
        HStack(spacing: 2) {
            ForEach(areas) { a in
                areaTab(a)
            }
            Spacer(minLength: 12)
            if !editing {
                stripHint
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
    }

    private func areaTab(_ a: FloorArea) -> some View {
        let selected = a.id == currentArea?.id
        let busy = a.tables.filter { !model.state.openTickets(at: $0.id).isEmpty }.count
        return Button {
            withAnimation(anim) {
                areaId = a.id
                selectedTableId = nil
                cardTicketId = nil
            }
        } label: {
            HStack(spacing: 7) {
                Text(a.name.isEmpty ? "未命名" : a.name)
                    .font(.brand(15, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                if !editing {
                    Text("\(busy)/\(a.tables.count)")
                        .font(.brand(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                // 選到的那一區：品牌橘的底線
                Capsule()
                    .fill(selected ? Theme.accent : Color.clear)
                    .frame(height: 2)
                    .offset(y: 7)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityLabel("\(a.name)，\(busy) 桌用餐中，共 \(a.tables.count) 桌")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var stripHint: some View {
        if let next = nextReservation {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.table(.reserved))
                    .frame(width: 6, height: 6)
                Text("下一組訂位 \(next.startsAt.clockText)・\(next.name) \(next.partySize) 位")
                    .font(.brand(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        } else {
            Text("點一桌選起來，動作在右邊")
                .font(.brand(12.5, .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }

    // MARK: 換桌、併桌的提示

    @ViewBuilder
    private var pickBanner: some View {
        if let p = pick {
            let name = model.state.tickets[p.ticketId].map { $0.title(floor: model.floor) } ?? "這張單"
            HStack(spacing: 12) {
                LiveDot(color: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pickTitle(p, name: name))
                        .font(.brand(15.5, .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pickDetail(p))
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.dock, in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func pickTitle(_ p: FloorPick, name: String) -> String {
        switch p {
        case .move: "換桌：\(name) 要換到哪一桌？"
        case .merge: "併桌：\(name) 要併到哪一桌？"
        }
    }

    private func pickDetail(_ p: FloorPick) -> String {
        switch p {
        case .move: "點一張空桌（別的區域也可以，先切換下面的分頁）"
        case .merge: "點一桌正在用餐的，兩張單會合成一張"
        }
    }

    // MARK: - 點桌子

    private func tap(_ i: FloorTableInfo) {
        model.touch()
        if let pick {
            finishPick(pick, at: i)
            return
        }
        let t = i.table
        if selectedTableId == t.id {
            // 再點一次＝取消選取
            deselect()
            return
        }
        if seatingTableId != nil {
            // 正在問別桌的人數：換一桌就不問了
            model.keypad.cancel()
            seatingTableId = nil
        }
        withAnimation(anim) {
            selectedTableId = t.id
            // 單子欄正在看這桌的某一張：卡片也看那一張
            let ids = i.tickets.map(\.id)
            cardTicketId = model.selectedTicketId.flatMap { ids.contains($0) ? $0 : nil }
            // 單子欄收起來：右欄換成這一桌的動作，桌位圖保持全寬、卡片才放得下
            model.selectedTicketId = nil
        }
    }

    private func deselect() {
        if seatingTableId != nil {
            model.keypad.cancel()
            seatingTableId = nil
        }
        withAnimation(anim) {
            selectedTableId = nil
            cardTicketId = nil
        }
    }

    private func backgroundTapped() {
        guard pick == nil else { return }
        deselect()
    }

    /// 帶位：右側鍵盤問人數 → 開單 → 跳到點餐（取消就停在這裡）
    private func seat(_ t: DiningTable) {
        withAnimation(anim) {
            selectedTableId = t.id
            seatingTableId = t.id
            cardTicketId = nil
            model.selectedTicketId = nil
        }
        Task {
            await model.seat(table: t)
            if seatingTableId == t.id { seatingTableId = nil }
        }
    }

    /// 訂位的客人到了：用訂位入座（帶名字、人數，訂位改成已入座）
    private func seatReservation(_ r: Reservation, at t: DiningTable) {
        // 訂位排了好幾桌（大團體）：還空著的都一起帶
        var ids = r.tableIds.filter { id in
            let s = model.tableStatus(id)
            return s == .available || s == .reserved
        }
        if !ids.contains(t.id) { ids = [t.id] }
        Task { await model.seat(r, at: ids) }
    }

    private func clean(_ t: DiningTable, thenSeat: Bool) {
        model.clean(table: t)
        if thenSeat {
            seat(t)
        } else {
            model.show("\(t.name) 清好了")
            withAnimation(anim) { selectedTableId = nil }
        }
    }

    /// 這台有點餐頁（報到接待沒有：只把單子打開在旁邊）
    private var canOrderHere: Bool { model.visibleSections.contains(.order) }

    private func order(_ ticket: Ticket) {
        // 單子欄打開後右欄換成那張單的動作：這裡的選取就收起來
        withAnimation(anim) {
            selectedTableId = nil
            cardTicketId = nil
        }
        model.selectedTicketId = ticket.id
        if canOrderHere { model.go(.order) }
    }

    // MARK: 換桌、併桌

    private func startPick(_ p: FloorPick) {
        model.keypad.cancel()
        withAnimation(anim) { pick = p }
    }

    private func isPickSource(_ tableId: String) -> Bool {
        guard let pick, let source = model.state.tickets[pick.ticketId] else { return false }
        return source.tableIds.contains(tableId)
    }

    private func eligible(_ i: FloorTableInfo, for p: FloorPick) -> Bool {
        i.accepts(p, in: model.state)
    }

    private func finishPick(_ p: FloorPick, at i: FloorTableInfo) {
        guard let source = model.state.tickets[p.ticketId], source.isOpen else {
            withAnimation(anim) { pick = nil }
            return
        }
        guard eligible(i, for: p) else {
            switch p {
            case .move: model.show("請點一張空桌", tone: .warning)
            case .merge: model.show("請點一桌正在用餐的", tone: .warning)
            }
            return
        }
        var keep = source.id
        switch p {
        case .move:
            model.move(source, to: [i.table.id])
        case .merge:
            guard let target = i.tickets.first(where: { $0.id != source.id }) else { return }
            model.merge(source, into: target)
            keep = target.id
        }
        // merge 會把單子欄切到併進去的那張；卡片取代單子欄，所以關掉
        model.selectedTicketId = nil
        withAnimation(anim) {
            pick = nil
            selectedTableId = i.table.id
            cardTicketId = keep
        }
    }

    // MARK: - 右欄：選起來的桌子與它的動作

    private var dockItem: DockSelection? {
        if editing { return editDock }
        if let p = pick { return pickDock(p) }
        guard let id = selectedTableId, let t = currentArea?.tables.first(where: { $0.id == id }) else { return pageDock }
        return tableDock(info(t, soon: model.reservedSoon, now: Date()))
    }

    /// 沒選桌子：這一頁的動作（排隊等內用：排隊取號、叫號入座；排了幾組在右欄最上面那一行）
    private var pageDock: DockSelection? {
        var actions: [POSAction] = []
        if model.queueForDineIn {
            let can = model.queueCanAct
            actions.append(POSAction("排隊取號", icon: "ticket", enabled: can && !model.queueCooling(.take)) {
                Task { await model.askTakeDineIn() }
            })
            actions.append(POSAction(model.queueSeatNextTitle, icon: "users",
                                     enabled: can && model.queue.state?.waiting.isEmpty == false && !model.queueCooling(.next)) {
                Task { await model.callToSeat() }
            })
        }
        if model.visibleSections.contains(.reservations) {
            actions.append(POSAction("訂位與候位", icon: "calendar-days") { model.go(.reservations) })
        }
        if canEdit {
            actions.append(POSAction(areas.isEmpty ? "開始排桌位" : "編輯桌位", icon: "pencil-square") { beginEditing() })
        }
        return actions.isEmpty ? nil : DockSelection.page("floor", actions: actions)
    }

    /// 選起來的一桌：動作和手機的桌位清單同一份（TableDock）
    private func tableDock(_ i: FloorTableInfo) -> DockSelection {
        TableDock(model: model, cardTicketId: cardTicketId,
                  seat: { seat($0) },
                  seatReservation: { seatReservation($0, at: $1) },
                  clean: { clean($0, thenSeat: $1) },
                  order: { order($0) },
                  startPick: { startPick($0) },
                  deselect: { deselect() })
            .selection(i)
    }

    /// 換桌、併桌：等著點目的地
    private func pickDock(_ p: FloorPick) -> DockSelection {
        let name = model.state.tickets[p.ticketId].map { $0.title(floor: model.floor) } ?? "這張單"
        let kind: String
        switch p {
        case .move: kind = "換桌"
        case .merge: kind = "併桌"
        }
        return DockSelection(id: "pick-\(p.ticketId)", kind: kind, title: name, detail: pickDetail(p),
                             actions: [POSAction("取消\(kind)", icon: "x-mark") { cancelPick() }],
                             clear: { cancelPick() })
    }

    private func cancelPick() {
        withAnimation(anim) { pick = nil }
    }

    /// 排桌位：儲存是大鍵；選了桌子多一個「刪除這張桌子」
    private var editDock: DockSelection {
        let saveAction = POSAction(saving ? "儲存中…" : "儲存桌位", icon: "check", enabled: !saving) { save() }
        let addTableAction = POSAction("新增桌子", icon: "plus", enabled: currentArea != nil) { addTable() }
        if let id = selectedTableId, let t = draftTable(id) {
            let busy = !model.state.openTickets(at: t.id).isEmpty
            return DockSelection(id: "edit-\(t.id)", kind: "桌子", title: t.name.isEmpty ? "未命名" : t.name,
                                 detail: "\(t.seats) 人・\(Self.shapeLabel(t.shape))" + (busy ? "・還有沒結帳的單，不能刪" : ""),
                                 primary: saveAction,
                                 actions: [
                                     addTableAction,
                                     POSAction("刪除這張桌子", icon: "trash", destructive: true, enabled: !busy) { deleteTable(t.id) },
                                 ],
                                 clear: { withAnimation(anim) { selectedTableId = nil } })
        }
        var actions = [addTableAction, POSAction("新增區域", icon: "squares-2x2") { addArea() }]
        if let a = currentArea, a.tables.isEmpty {
            actions.append(POSAction("刪除這個區域", icon: "trash", destructive: true) { deleteArea(a.id) })
        }
        actions.append(POSAction("不存了，離開", icon: "x-mark", destructive: true) { cancelEditing() })
        return DockSelection.page("floor-edit", primary: saveAction, accent: true, actions: actions)
    }

    // MARK: - 桌子旁邊的卡片（只給看）

    private func card(for i: FloorTableInfo, rect: CGRect, canvas: CGSize, now: Date) -> some View {
        let p = cardPosition(for: rect, canvas: canvas)
        return cardBody(i, now: now)
            .frame(width: Self.cardWidth)
            .background(Theme.dock, in: .rect(cornerRadius: Metric.radiusLg))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
            .onGeometryChange(for: CGSize.self, of: { proxy in proxy.size }, action: { newSize in cardSize = newSize })
            .position(p)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// 放在桌子右邊（放不下就左邊、再不行就上下），不超出桌位圖（可以吃進 12 點的留白）
    private func cardPosition(for rect: CGRect, canvas: CGSize) -> CGPoint {
        let w = cardSize.width
        let h = cardSize.height
        let gap: CGFloat = 14
        let slack: CGFloat = 12
        let minX = w / 2 - slack
        let maxX = max(canvas.width - w / 2 + slack, minX)
        let minY = h / 2 - slack
        let maxY = max(canvas.height - h / 2 + slack, minY)
        if rect.maxX + gap + w <= canvas.width + slack {
            return CGPoint(x: rect.maxX + gap + w / 2, y: min(max(rect.midY, minY), maxY))
        }
        if rect.minX - gap - w >= -slack {
            return CGPoint(x: rect.minX - gap - w / 2, y: min(max(rect.midY, minY), maxY))
        }
        let x = min(max(rect.midX, minX), maxX)
        if rect.maxY + gap + h <= canvas.height + slack {
            return CGPoint(x: x, y: rect.maxY + gap + h / 2)
        }
        if rect.minY - gap - h >= -slack {
            return CGPoint(x: x, y: rect.minY - gap - h / 2)
        }
        return CGPoint(x: x, y: min(max(rect.midY, minY), maxY))
    }

    private func cardBody(_ i: FloorTableInfo, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(i)
            switch i.status {
            case .seated, .ordering, .billing:
                occupiedCard(i, now: now)
            case .reserved:
                reservedCard(i)
            case .needsCleaning:
                cleaningCard(i)
            case .available:
                availableCard(i)
            }
        }
        .padding(16)
    }

    private func cardHeader(_ i: FloorTableInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(i.table.name)
                .font(.brand(22, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            FloorStatusTag(status: i.status)
            if i.tickets.count > 1 {
                Text("\(i.tickets.count) 張單")
                    .textRole(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private func occupiedCard(_ i: FloorTableInfo, now: Date) -> some View {
        if let ticket = i.tickets.first(where: { $0.id == cardTicketId }) ?? i.tickets.first {
            if i.tickets.count > 1 {
                // 拆過單：同一桌有好幾張，先選要看哪一張
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(i.tickets) { tk in
                            ticketChip(tk, selected: tk.id == ticket.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            occupiedInfo(ticket, now: now)
            if !i.attention.isEmpty {
                attentionList(i.attention)
            }
            if !model.takesPayment {
                // 不收錢的崗位（報到接待、前場的手機）：結帳在結帳櫃台
                Text("\(ticket.number)・\(ticket.totals.amountDue.formatted) " + (ticket.billSentFrom != nil ? "已送到結帳櫃台" : "已同步到結帳櫃台"))
                    .font(.brand(13, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.infoFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func occupiedInfo(_ ticket: Ticket, now: Date) -> some View {
        let minutes = max(0, Int(now.timeIntervalSince(ticket.openedAt) / 60))
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                FloorInfoCell(label: "服務人員") {
                    Text(model.staffName(ticket.openedBy))
                        .font(.brand(16, .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                FloorInfoCell(label: "人數") {
                    Text("\(ticket.guests) 位")
                        .font(.brand(16, .medium))
                        .monospacedDigit()
                }
            }
            GridRow {
                FloorInfoCell(label: "金額") {
                    MoneyText(money: ticket.totals.amountDue, role: .h4)
                }
                FloorInfoCell(label: "開桌") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TaipeiTime.clock(ticket.openedAt))
                            .font(.brand(16, .medium))
                            .monospacedDigit()
                        Text("用餐 \(minutes) 分鐘")
                            .textRole(.xs)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private func attentionList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { a in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                    Text(a)
                        .font(.brand(13, .medium))
                        .foregroundStyle(Theme.accentText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func reservedCard(_ i: FloorTableInfo) -> some View {
        if let r = i.reservation {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    FloorInfoCell(label: "訂位") {
                        Text(r.name)
                            .font(.brand(16, .medium))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    FloorInfoCell(label: "人數") {
                        Text("\(r.partySize) 位")
                            .font(.brand(16, .medium))
                            .monospacedDigit()
                    }
                }
                GridRow {
                    FloorInfoCell(label: "時間") {
                        Text(r.startsAt.clockText)
                            .font(.brand(16, .medium))
                            .monospacedDigit()
                    }
                    FloorInfoCell(label: "電話") {
                        Text(r.phone.isEmpty ? "—" : MemberRef(phone: r.phone).maskedPhone)
                            .font(.brand(16, .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            if !r.note.isEmpty {
                Text("※ \(r.note)")
                    .textRole(.small)
                    .foregroundStyle(Theme.warningFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("\(i.table.seats) 人桌・訂位的資料還沒抓到")
                .textRole(.small)
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
        }
        seatingHint(i)
    }

    /// 右欄的鍵盤正在問這一桌的人數
    @ViewBuilder
    private func seatingHint(_ i: FloorTableInfo) -> some View {
        if seatingTableId == i.table.id && model.keypad.isAsking {
            HStack(spacing: 10) {
                LiveDot(color: Theme.accent)
                Text("在右邊鍵盤輸入人數 →")
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func cleaningCard(_ i: FloorTableInfo) -> some View {
        Text("結完帳了，桌面整理好就改回空桌。")
            .textRole(.small)
            .foregroundStyle(Theme.ink2)
            .fixedSize(horizontal: false, vertical: true)
        seatingHint(i)
    }

    @ViewBuilder
    private func availableCard(_ i: FloorTableInfo) -> some View {
        Text("\(i.table.seats) 人桌")
            .textRole(.small)
            .monospacedDigit()
            .foregroundStyle(Theme.ink2)
        if let r = i.reservation {
            Text("\(r.startsAt.clockText) \(r.name) \(r.partySize) 位訂了這桌")
                .textRole(.small)
                .foregroundStyle(Theme.table(.reserved))
        }
        seatingHint(i)
    }

    private func ticketChip(_ tk: Ticket, selected: Bool) -> some View {
        Button {
            withAnimation(anim) { cardTicketId = tk.id }
        } label: {
            VStack(spacing: 2) {
                Text(tk.number)
                    .font(.brand(14, .semibold))
                Text(tk.totals.amountDue.short)
                    .font(.brand(11.5, .medium))
                    .foregroundStyle(selected ? Theme.page.opacity(0.7) : Theme.muted)
            }
            .monospacedDigit()
            .foregroundStyle(selected ? Theme.page : Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(selected ? Theme.ink : Color.clear, in: .rect(cornerRadius: Metric.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScale(scale: 0.96))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 沒有桌位圖

    private var emptyFloor: some View {
        VStack(spacing: 16) {
            EmptyState(
                icon: "table-cells",
                title: "還沒有桌位圖",
                message: canEdit
                    ? "到後台「門市 POS → 桌位」排好桌子，這裡會自動出現；也可以按右邊的「編輯桌位」直接在 iPad 上排。"
                    : "請店長到後台「門市 POS → 桌位」排好桌子，這裡會自動出現。"
            )
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 編輯

    private func beginEditing() {
        model.keypad.cancel()
        var areas = model.floor.areas
        if areas.isEmpty {
            areas = [FloorArea(id: model.newID(), name: "1F", sortOrder: 1)]
        }
        draft = areas
        pick = nil
        seatingTableId = nil
        selectedTableId = nil
        cardTicketId = nil
        model.selectedTicketId = nil
        if !areas.contains(where: { $0.id == areaId }) { areaId = areas.first?.id }
        withAnimation(anim) { editing = true }
    }

    private func cancelEditing() {
        model.keypad.cancel()
        withAnimation(anim) {
            editing = false
            draft = []
            selectedTableId = nil
            draggingId = nil
            dragOffset = .zero
        }
        if !model.floor.areas.contains(where: { $0.id == areaId }) { areaId = model.floor.areas.first?.id }
    }

    private func selectInEditor(_ id: String) {
        withAnimation(anim) { selectedTableId = id }
    }

    private func draftTable(_ id: String) -> DiningTable? {
        for a in draft {
            if let t = a.tables.first(where: { $0.id == id }) { return t }
        }
        return nil
    }

    private func updateDraft(_ id: String, _ change: (inout DiningTable) -> Void) {
        var areas = draft
        for a in areas.indices {
            if let i = areas[a].tables.firstIndex(where: { $0.id == id }) {
                change(&areas[a].tables[i])
                draft = areas
                return
            }
        }
    }

    private func updateArea(_ id: String, _ change: (inout FloorArea) -> Void) {
        var areas = draft
        guard let i = areas.firstIndex(where: { $0.id == id }) else { return }
        change(&areas[i])
        draft = areas
    }

    /// 放開時對齊整數格子、不超出 0–100
    private func finishDrag(_ t: DiningTable, translation: CGSize, unitX: CGFloat, unitY: CGFloat) {
        let dx = Double(translation.width / max(unitX, 0.01))
        let dy = Double(translation.height / max(unitY, 0.01))
        withAnimation(reduceMotion ? nil : Motion.fast) {
            updateDraft(t.id) { d in
                d.x = min(max((d.x + dx).rounded(), 0), max(100 - d.width, 0))
                d.y = min(max((d.y + dy).rounded(), 0), max(100 - d.height, 0))
            }
            draggingId = nil
            dragOffset = .zero
        }
    }

    private func addTable() {
        guard let area = currentArea else { return }
        let w = 14.0, h = 18.0
        let spot = freeSpot(in: area, width: w, height: h)
        let t = DiningTable(id: model.newID(), areaId: area.id, name: nextTableName(in: area), seats: 4, shape: .square,
                            x: spot.x, y: spot.y, width: w, height: h)
        withAnimation(anim) {
            updateArea(area.id) { $0.tables.append(t) }
            selectedTableId = t.id
        }
    }

    /// 新桌子放在第一個不會疊到別桌的地方
    private func freeSpot(in area: FloorArea, width: Double, height: Double) -> (x: Double, y: Double) {
        let taken = area.tables.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).insetBy(dx: -2, dy: -2) }
        for y in stride(from: 4.0, through: 100 - height, by: 4) {
            for x in stride(from: 4.0, through: 100 - width, by: 4) {
                let r = CGRect(x: x, y: y, width: width, height: height)
                if !taken.contains(where: { $0.intersects(r) }) { return (x, y) }
            }
        }
        return (43, 41)
    }

    /// 接著同一區最後一桌的字頭編號（A6 → A7、吧台4 → 吧台5）
    private func nextTableName(in area: FloorArea) -> String {
        let names = Set(draft.flatMap(\.tables).map(\.name))
        let prefix = String((area.tables.last?.name ?? "").prefix(while: { !$0.isNumber }))
        let used = area.tables.compactMap { t -> Int? in
            guard t.name.hasPrefix(prefix) else { return nil }
            return Int(t.name.dropFirst(prefix.count))
        }
        var n = (used.max() ?? area.tables.count) + 1
        while names.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    private func deleteTable(_ id: String) {
        guard model.state.openTickets(at: id).isEmpty else { return }
        var areas = draft
        for a in areas.indices {
            areas[a].tables.removeAll { $0.id == id }
        }
        withAnimation(anim) {
            draft = areas
            selectedTableId = nil
        }
    }

    private func addArea() {
        let area = FloorArea(id: model.newID(), name: "新區域", sortOrder: (draft.map(\.sortOrder).max() ?? 0) + 1)
        withAnimation(anim) {
            draft.append(area)
            areaId = area.id
            selectedTableId = nil
        }
    }

    private func deleteArea(_ id: String) {
        withAnimation(anim) {
            draft.removeAll { $0.id == id }
            areaId = draft.first?.id
            selectedTableId = nil
        }
    }

    private func askSeats(_ t: DiningTable) {
        Task {
            let spec = KeypadSpec(
                kind: .count, title: "座位數", subtitle: t.name, initial: String(t.seats),
                quickKeys: [2, 4, 6, 8].map { KeypadSpec.QuickKey("\($0) 人", digits: String($0)) },
                confirmLabel: "設定", maxValue: 99, minValue: 1
            )
            guard let n = await model.keypad.askNumber(spec) else { return }
            withAnimation(anim) { updateDraft(t.id) { $0.seats = n } }
        }
    }

    private func resize(_ id: String, width dw: Double = 0, height dh: Double = 0) {
        withAnimation(reduceMotion ? nil : Motion.fast) {
            updateDraft(id) { t in
                t.width = min(max(t.width + dw, 4), 60)
                t.height = min(max(t.height + dh, 4), 60)
                t.x = min(t.x, max(100 - t.width, 0))
                t.y = min(t.y, max(100 - t.height, 0))
            }
        }
    }

    private func tableNameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { draftTable(id)?.name ?? "" },
            set: { value in updateDraft(id) { $0.name = value } }
        )
    }

    private func areaNameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { draft.first(where: { $0.id == id })?.name ?? "" },
            set: { value in updateArea(id) { $0.name = value } }
        )
    }

    // MARK: 儲存

    private func save() {
        guard !saving else { return }
        let areas = normalizedDraft()
        if let issue = problem(in: areas) {
            model.alert = POSModel.AlertInfo(title: "還不能儲存", message: issue)
            return
        }
        model.keypad.cancel()
        saving = true
        Task {
            defer { saving = false }
            guard let auth = await model.authorize(.editFloor, detail: "儲存桌位圖") else { return }
            guard let api = model.api, let me = model.currentStaff else {
                model.alert = POSModel.AlertInfo(title: "存不了", message: "這台還沒連上後台，請稍後再試。")
                return
            }
            let update = FloorUpdate(areas: areas, staffId: auth.authorizerId ?? me.id)
            do {
                let response = try await api.saveFloor(update)
                model.floor = response.floor
                withAnimation(anim) {
                    editing = false
                    draft = []
                    selectedTableId = nil
                }
                if !response.floor.areas.contains(where: { $0.id == areaId }) { areaId = response.floor.areas.first?.id }
                model.show("桌位圖已儲存，其他 iPad 會跟著更新")
            } catch let e as APIError {
                model.alert = POSModel.AlertInfo(title: "存不了", message: e.userMessage)
            } catch {
                model.alert = POSModel.AlertInfo(title: "存不了", message: error.localizedDescription)
            }
        }
    }

    /// 區域照畫面順序編號、桌子的區域對好、名字去掉前後空白
    private func normalizedDraft() -> [FloorArea] {
        var out: [FloorArea] = []
        for (index, source) in draft.enumerated() {
            var area = source
            let areaId = area.id
            area.name = area.name.trimmingCharacters(in: .whitespacesAndNewlines)
            area.sortOrder = index + 1
            var tables: [DiningTable] = []
            for t in source.tables {
                var fixed = t
                fixed.areaId = areaId
                fixed.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
                tables.append(fixed)
            }
            area.tables = tables
            out.append(area)
        }
        return out
    }

    private func problem(in areas: [FloorArea]) -> String? {
        if areas.contains(where: { $0.name.isEmpty }) { return "有區域沒有名字。" }
        let names = areas.flatMap(\.tables).map(\.name)
        if names.contains(where: { $0.isEmpty }) { return "有桌子沒有桌號。" }
        var seen = Set<String>()
        for n in names {
            if seen.contains(n) { return "桌號「\(n)」重複了，每一桌要不一樣（廚房單、帳單上看的是桌號）。" }
            seen.insert(n)
        }
        return nil
    }

    // MARK: 編輯的側欄

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let id = selectedTableId, let t = draftTable(id) {
                    tableInspector(t)
                } else if let a = currentArea {
                    areaInspector(a)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .frame(width: 292)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func tableInspector(_ t: DiningTable) -> some View {
        HStack {
            Eyebrow("桌子")
            Spacer()
            Button {
                withAnimation(anim) { selectedTableId = nil }
            } label: {
                HeroIcon("x-mark", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle(size: 30))
            .accessibilityLabel("回到區域設定")
        }

        FloorField(label: "桌號") {
            TextField("A1", text: tableNameBinding(t.id))
                .font(.brand(18, .medium))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }

        FloorField(label: "座位") {
            Button {
                askSeats(t)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(t.seats)")
                        .font(.brand(24, .medium))
                        .monospacedDigit()
                    Text("人")
                        .font(.brand(15, .medium))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 8)
                    Text("右邊鍵盤輸入")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                .contentShape(.rect)
            }
            .buttonStyle(PressScale(scale: 0.98))
        }

        FloorField(label: "形狀") {
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(TableShape.allCases, id: \.self) { s in
                    OptionChip(title: Self.shapeLabel(s), selected: t.shape == s) {
                        withAnimation(anim) { updateDraft(t.id) { $0.shape = s } }
                    }
                }
            }
        }

        FloorField(label: "大小（格）") {
            HStack(spacing: 8) {
                FloorStepper(label: "寬", value: Int(t.width), minus: { resize(t.id, width: -2) }, plus: { resize(t.id, width: 2) })
                FloorStepper(label: "高", value: Int(t.height), minus: { resize(t.id, height: -2) }, plus: { resize(t.id, height: 2) })
            }
        }

        Text("位置 X \(Int(t.x))・Y \(Int(t.y))（拖拉桌子移動）")
            .textRole(.xs)
            .monospacedDigit()
            .foregroundStyle(Theme.muted)

        if !model.state.openTickets(at: t.id).isEmpty {
            Text("這桌還有沒結帳的單，先結帳或換桌才能刪。")
                .textRole(.xs)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func areaInspector(_ a: FloorArea) -> some View {
        Eyebrow("區域")

        FloorField(label: "名稱") {
            TextField("1F、2F、戶外", text: areaNameBinding(a.id))
                .font(.brand(18, .medium))
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
        }

        Text("\(a.tables.count) 張桌子・\(a.tables.reduce(0) { $0 + $1.seats }) 個座位")
            .textRole(.small)
            .monospacedDigit()
            .foregroundStyle(Theme.ink2)

        Rule()

        Text("新增桌子、新增區域、儲存都在右邊。改完按「儲存」，其他 iPad 會跟著更新。")
            .textRole(.small)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func shapeLabel(_ s: TableShape) -> String {
        switch s {
        case .square: "方桌"
        case .round: "圓桌"
        case .rect: "長桌"
        case .booth: "卡座"
        case .bar: "吧台"
        }
    }
}

// MARK: - 一桌：桌面＋椅子

// 資料（FloorPick、FloorTableInfo）與選起來之後的動作（TableDock）在 TableDock.swift，和手機的桌位清單共用

/// 一張椅子：中心點、轉幾度（弧度）、長、厚
private struct FloorChair {
    var center: CGPoint
    var angle: Double
    var length: CGFloat
    var depth: CGFloat
}

/// 桌子在格子裡的樣子：桌面放中間、椅子照座位數排在四邊（長邊多坐）、圓桌繞一圈、吧台排在一邊
private struct FloorChairLayout {
    var table: CGRect
    var chairs: [FloorChair]
    /// 「要注意」的橘點放哪（桌面右上角）
    var dot: CGPoint

    static func make(shape: TableShape, seats: Int, size: CGSize) -> FloorChairLayout {
        let depth: CGFloat = min(size.width, size.height) < 56 ? 5 : 6
        let gap: CGFloat = 4
        let edge = depth + gap
        // 座位數很大時（宴會桌）不要畫成一圈毛邊
        let n = min(max(seats, 0), 16)
        switch shape {
        case .bar:
            if size.width >= size.height {
                let t = CGRect(x: 0, y: 0, width: size.width, height: max(size.height - edge, 12))
                let chairs = row(n, start: CGPoint(x: t.minX, y: t.maxY + gap + depth / 2), length: t.width, horizontal: true, depth: depth)
                return FloorChairLayout(table: t, chairs: chairs, dot: CGPoint(x: t.maxX - 4, y: t.minY + 2))
            } else {
                let t = CGRect(x: 0, y: 0, width: max(size.width - edge, 12), height: size.height)
                let chairs = row(n, start: CGPoint(x: t.maxX + gap + depth / 2, y: t.minY), length: t.height, horizontal: false, depth: depth)
                return FloorChairLayout(table: t, chairs: chairs, dot: CGPoint(x: t.maxX - 2, y: t.minY + 4))
            }
        case .round:
            let t = CGRect(x: edge, y: edge, width: max(size.width - edge * 2, 12), height: max(size.height - edge * 2, 12))
            let dot = CGPoint(x: t.midX + t.width / 2 * 0.7071, y: t.midY - t.height / 2 * 0.7071)
            return FloorChairLayout(table: t, chairs: around(n, ellipse: t, gap: gap, depth: depth), dot: dot)
        case .square, .rect, .booth:
            let t = CGRect(x: edge, y: edge, width: max(size.width - edge * 2, 12), height: max(size.height - edge * 2, 12))
            return FloorChairLayout(table: t, chairs: sides(n, rect: t, gap: gap, depth: depth), dot: CGPoint(x: t.maxX - 2, y: t.minY + 2))
        }
    }

    /// 一排椅子平均分在一段邊上
    static func row(_ n: Int, start: CGPoint, length: CGFloat, horizontal: Bool, depth: CGFloat) -> [FloorChair] {
        guard n > 0, length > 0 else { return [] }
        let spacing = length / CGFloat(n)
        let len = min(18, max(spacing - 4, 6))
        return (0..<n).map { i -> FloorChair in
            let offset = spacing * (CGFloat(i) + 0.5)
            let center = horizontal ? CGPoint(x: start.x + offset, y: start.y) : CGPoint(x: start.x, y: start.y + offset)
            return FloorChair(center: center, angle: horizontal ? 0 : Double.pi / 2, length: len, depth: depth)
        }
    }

    /// 方桌、長桌：一張一張分給「每張椅子分到最寬」的那一邊，長邊自然坐比較多（順序：上、下、左、右）
    static func sides(_ n: Int, rect: CGRect, gap: CGFloat, depth: CGFloat) -> [FloorChair] {
        guard n > 0 else { return [] }
        let lengths: [CGFloat] = [rect.width, rect.width, rect.height, rect.height]
        var counts = [0, 0, 0, 0]
        for _ in 0..<n {
            var best = 0
            var bestRoom: CGFloat = -1
            for s in 0..<4 {
                let room = lengths[s] / CGFloat(counts[s] + 1)
                if room > bestRoom + 0.5 {
                    best = s
                    bestRoom = room
                }
            }
            counts[best] += 1
        }
        let off = gap + depth / 2
        var out: [FloorChair] = []
        out += row(counts[0], start: CGPoint(x: rect.minX, y: rect.minY - off), length: rect.width, horizontal: true, depth: depth)
        out += row(counts[1], start: CGPoint(x: rect.minX, y: rect.maxY + off), length: rect.width, horizontal: true, depth: depth)
        out += row(counts[2], start: CGPoint(x: rect.minX - off, y: rect.minY), length: rect.height, horizontal: false, depth: depth)
        out += row(counts[3], start: CGPoint(x: rect.maxX + off, y: rect.minY), length: rect.height, horizontal: false, depth: depth)
        return out
    }

    /// 圓桌：從正上方開始繞一圈
    static func around(_ n: Int, ellipse r: CGRect, gap: CGFloat, depth: CGFloat) -> [FloorChair] {
        guard n > 0 else { return [] }
        let rx = r.width / 2 + gap + depth / 2
        let ry = r.height / 2 + gap + depth / 2
        let radius = Double((rx * rx + ry * ry) / 2).squareRoot()
        let circumference = CGFloat(2 * Double.pi * radius)
        let len = min(18, max(circumference / CGFloat(n) - 4, 6))
        return (0..<n).map { i -> FloorChair in
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            let center = CGPoint(x: r.midX + rx * CGFloat(cos(a)), y: r.midY + ry * CGFloat(sin(a)))
            return FloorChair(center: center, angle: a + Double.pi / 2, length: len, depth: depth)
        }
    }
}

/// 圖上的一桌：用餐中＝實心的桌況色（一眼看得到）、空桌＝紙色＋細線；椅子照座位數，有人坐的那幾張塗滿
private struct FloorTableTile: View {
    let info: FloorTableInfo
    /// 桌子＋椅子佔的大小
    let size: CGSize
    let now: Date
    let selected: Bool
    let editing: Bool
    /// 換桌、併桌時：true＝可以點（橘色虛線圈）、false＝不行（淡掉）、nil＝沒在選
    let target: Bool?

    var body: some View {
        let layout = FloorChairLayout.make(shape: info.table.shape, seats: info.table.seats, size: size)
        let shape = Self.shape(info.table.shape)
        let rect = layout.table
        ZStack(alignment: .topLeading) {
            ForEach(layout.chairs.indices, id: \.self) { i in
                chair(layout.chairs[i], index: i)
            }
            tableTop(shape)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if selected {
                ring(shape, rect: rect, color: Theme.ink, dashed: false)
            }
            if target == true {
                ring(shape, rect: rect, color: Theme.accent, dashed: true)
            }
            if !editing && !info.attention.isEmpty {
                FloorAttentionDot(size: 8)
                    .position(layout.dot)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(target == false ? 0.3 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    static func shape(_ s: TableShape) -> AnyShape {
        switch s {
        case .round: AnyShape(Ellipse())
        case .bar: AnyShape(Capsule())
        case .booth: AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .square, .rect: AnyShape(RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous))
        }
    }

    // MARK: 顏色

    /// 有人坐（已入座、用餐中、待結帳）：實心
    private var solid: Bool {
        guard !editing else { return false }
        switch info.status {
        case .seated, .ordering, .billing: return true
        case .available, .reserved, .needsCleaning: return false
        }
    }

    private var statusColor: Color { Theme.table(info.status) }

    /// 實心桌面上的字：橘底用白字（和品牌橘按鈕一樣）；藍、黃底用頁面色（亮色模式是淺字、暗色模式是深字，兩邊都讀得清楚）
    private var onSolid: Color {
        info.status == .ordering ? Theme.onAccent : Theme.page
    }

    private var tint: Color {
        if editing { return Color.clear }
        switch info.status {
        case .available: return Color.clear
        case .seated, .ordering, .billing: return statusColor
        case .reserved, .needsCleaning: return statusColor.opacity(0.16)
        }
    }

    // MARK: 桌面

    private func tableTop(_ shape: AnyShape) -> some View {
        let reserved = !editing && info.status == .reserved
        let strokeColor: Color = solid ? Color.clear : ((editing || info.status == .available) ? Theme.line : statusColor)
        let lineWidth: CGFloat = (editing || info.status == .available) ? 1 : 1.5
        return ZStack {
            shape.fill(Theme.surface)
            shape.fill(tint)
            // 已預約：虛線（桌子還空著，但先留著）
            shape.stroke(strokeColor, style: StrokeStyle(lineWidth: lineWidth, dash: reserved ? [4, 3] : []))
            label
                .padding(4)
        }
    }

    private func ring(_ shape: AnyShape, rect: CGRect, color: Color, dashed: Bool) -> some View {
        shape
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : []))
            .frame(width: rect.width + 6, height: rect.height + 6)
            .position(x: rect.midX, y: rect.midY)
    }

    private var nameSize: CGFloat {
        let m = min(layoutTableSize.width, layoutTableSize.height)
        if m >= 64 { return 19 }
        if m >= 40 { return 16 }
        return 13
    }

    private var layoutTableSize: CGSize {
        FloorChairLayout.make(shape: info.table.shape, seats: info.table.seats, size: size).table.size
    }

    private var label: some View {
        let showsDetail = layoutTableSize.height >= 40 && layoutTableSize.width >= 40
        return VStack(spacing: 1) {
            Text(info.table.name)
                .font(.brand(nameSize, .semibold))
                .monospacedDigit()
                .foregroundStyle(solid ? onSolid : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if showsDetail, let d = detail {
                Text(d.text)
                    .font(.brand(nameSize >= 19 ? 13 : 11.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(d.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private var minutes: Int? {
        info.openedAt.map { max(0, Int(now.timeIntervalSince($0) / 60)) }
    }

    private var detail: (text: String, color: Color)? {
        if editing { return ("\(info.table.seats) 人", Theme.muted) }
        switch info.status {
        case .available:
            if let r = info.reservation { return ("\(r.startsAt.clockText) 訂", Theme.table(.reserved)) }
            return nil
        case .reserved:
            if let r = info.reservation { return (r.startsAt.clockText, statusColor) }
            return (TableStatus.reserved.label, statusColor)
        case .seated, .ordering, .billing:
            return ("\(minutes ?? 0) 分", onSolid.opacity(0.82))
        case .needsCleaning:
            return (TableStatus.needsCleaning.label, statusColor)
        }
    }

    // MARK: 椅子

    private func chair(_ c: FloorChair, index: Int) -> some View {
        // 有人坐的椅子塗滿（幾位客人就塗幾張），其他是淡淡的桌況色
        let taken = solid && index < info.guests
        let fill: Color
        let stroke: Color
        if editing || info.status == .available {
            fill = Theme.surface
            stroke = Theme.line
        } else if taken {
            fill = statusColor
            stroke = Color.clear
        } else {
            fill = statusColor.opacity(0.18)
            stroke = statusColor.opacity(0.45)
        }
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .frame(width: c.length, height: c.depth)
            .rotationEffect(.radians(c.angle))
            .position(c.center)
    }

    private var accessibilityText: String {
        var parts = [info.table.name, editing ? "\(info.table.seats) 人桌" : info.status.label]
        if info.isOccupied && !editing {
            parts.append("\(info.guests) 位")
            parts.append("用餐 \(minutes ?? 0) 分鐘")
        } else if let r = info.reservation, !editing {
            parts.append("\(r.startsAt.clockText) \(r.name) 訂位")
        }
        if !editing { parts += info.attention }
        return parts.joined(separator: "，")
    }
}

// MARK: - 小元件

/// 「要注意」的橘點：外圈一圈頁面色，放在橘色桌面上也看得到
private struct FloorAttentionDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .padding(2)
            .background(Theme.page, in: .circle)
            .accessibilityHidden(true)
    }
}

/// 圖例的小色塊（和桌面同一個畫法：實心、淡底、細線）
private struct FloorLegendSwatch: View {
    let status: TableStatus

    var body: some View {
        let color = Theme.table(status)
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(Theme.surface)
            switch status {
            case .available:
                shape.strokeBorder(Theme.line, lineWidth: 1)
            case .seated, .ordering, .billing:
                shape.fill(color)
            case .reserved:
                shape.fill(color.opacity(0.16))
                shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            case .needsCleaning:
                shape.fill(color.opacity(0.16))
                shape.strokeBorder(color, lineWidth: 1)
            }
        }
        .frame(width: 12, height: 10)
    }
}

/// 桌位圖的底：每 5 格一個淡淡的點（編輯時深一點，看得出對齊的格線）
private struct FloorDotGrid: View {
    var strong = false

    var body: some View {
        let color = strong ? Theme.line : Theme.hair
        Canvas { context, size in
            let dx = size.width / 20
            let dy = size.height / 20
            guard dx > 2, dy > 2 else { return }
            var path = Path()
            var y: CGFloat = 0
            while y <= size.height + 0.5 {
                var x: CGFloat = 0
                while x <= size.width + 0.5 {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += dx
                }
                y += dy
            }
            context.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// 上面的數字（空桌 6）
private struct FloorCount: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.brand(26, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: Double(value)))
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .textRole(.xs)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) 桌")
    }
}

/// 桌況的小標籤（顏色＋字）
struct FloorStatusTag: View {
    let status: TableStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.table(status))
                .frame(width: 6, height: 6)
            Text(status.label)
        }
        .font(.brand(12, .medium))
        .foregroundStyle(Theme.table(status))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.table(status).opacity(0.12), in: .rect(cornerRadius: Metric.chip))
    }
}

/// 卡片上的一格資訊：小字標題＋值
private struct FloorInfoCell<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .textRole(.label)
                .foregroundStyle(Theme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片下面一排小動作：圖示在上、字在下

/// 編輯側欄的一欄：小字標題＋內容
private struct FloorField<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .textRole(.label)
                .foregroundStyle(Theme.muted)
            content
        }
    }
}

/// 寬、高：−／＋ 一次 2 格
private struct FloorStepper: View {
    let label: String
    let value: Int
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: minus) {
                HeroIcon("minus", size: 14)
                    .frame(width: 36, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(label)減少")
            Text("\(label) \(value)")
                .font(.brand(14, .medium))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            Button(action: plus) {
                HeroIcon("plus", size: 14)
                    .frame(width: 36, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(label)增加")
        }
        .buttonStyle(PressScale(scale: 0.94))
        .foregroundStyle(Theme.ink)
        .background(Theme.page, in: .rect(cornerRadius: Metric.radius))
        .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
    }
}
