import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側固定鍵盤（畫面最右邊那一欄）：左邊選、右邊做。
///
///   ┌────────────────────┐
///   │ 這一行          ×  │  選起來的那一筆（.dockSelection）：卡片＋動作鍵。問數字時也留著
///   │ 拿鐵・×2・NT$240    │  （單子的一行：鍵盤直接問它的數量；改價、座位這類題目：上面留一張小卡）
///   │ [備註…] [折扣…]    │  沒選東西：這一刻最需要的資訊（DockContext：桌況、接下來的預約…；點餐頁是空的）
///   │ 數量            ×  │  題目：要打數字時才出現，緊貼在鍵的上面
///   │      2             │  大字（PIN 是圓點、統編四碼一組）＋規則（對了打勾、錯了紅字搖一下）
///   │ [−1][+1][ 2 ][ 3 ] │  快速鍵
///   │  1    2    3       │
///   │  4    5    6       │  鍵位永遠一樣、位置永遠不動（上面那一塊怎麼變，鍵都貼在最下面）
///   │  7    8    9       │
///   │  C    0    ⌫       │
///   │ [      改成 3     ] │  最下面那顆大鍵＝下一步：問數字時確認；選了東西時是它的主要動作
///   └────────────────────┘
///
/// 不用打數字的選擇（.dockPanel）蓋住整欄；面板裡的選擇要打數字時面板淡出、上面留一條面板的標題，打完再淡回來。
struct KeypadDock: View {
    @Environment(KeypadController.self) private var keypad
    /// 待機打了數字時的大鍵（點餐畫面：品號加品項、沒有這個品號就是多少錢；其他畫面沒有）
    var idleActions: IdleActions? = nil
    /// 畫面交上來的：選起來的那一筆、蓋住整欄的面板（MainShell 收集）
    var content = DockContent()
    /// 題目右上的「取消」。鎖定畫面的鍵盤一直在等 PIN，取消沒有意義
    var showsCancel = true
    /// 最上面固定的一塊（DockPinned：外帶的叫號）。只有收銀台的右欄放
    var showsPinned = false
    /// 手機：在下面升起來的 sheet 裡（沒有左邊那條分隔線；選起來的那一筆用小卡；面板由 sheet 自己換，不在這裡蓋）
    var inSheet = false
    /// 待機打的數字是什麼（「會員 0912-345-678」「品號 2001 → 鴨胸」）：收銀台的右欄給（POSModel.describeTyped），停一下就自動做
    var describeIdle: ((String) -> (title: String, hint: String))? = nil

    struct IdleActions {
        /// 按下大鍵：打的數字交出去（POSModel.commitTyped）
        var commit: (String) -> Void
        /// 大鍵上的字（「加入 鴨胸」「加 NT$120」）
        var title: (String) -> String
    }

    @State private var shake: CGFloat = 0
    /// 這一欄有多高：高的螢幕（13 吋）數字鍵大一點，空間不浪費。只跟螢幕有關、不跟上面的內容變（鍵的位置不會跳）
    @State private var columnHeight: CGFloat = 0

    var body: some View {
        ZStack {
            column
            if let panel = content.panel, !inSheet {
                // 面板裡的選擇要打數字：面板淡出（不滑走）、鍵盤上面留一條面板的標題；問完再淡回來
                DockPanelChrome(item: panel)
                    .id(panel.id)
                    .opacity(panelCovers ? 1 : 0)
                    .allowsHitTesting(panelCovers)
                    .disabled(!panelCovers)
                    .accessibilityHidden(!panelCovers)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sensoryFeedback(.selection, trigger: keypad.keyTick)
        .sensoryFeedback(.error, trigger: keypad.errorTick)
        .sensoryFeedback(.success, trigger: keypad.successTick)
        .onChange(of: keypad.errorTick) { _, _ in
            withAnimation(.spring(response: 0.18, dampingFraction: 0.25)) { shake = 1 }
            Task {
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(Motion.fast) { shake = 0 }
            }
        }
        .animation(Motion.fast, value: keypad.request?.id)
        .animation(Motion.fast, value: content.selection?.id)
        .animation(Motion.spring, value: content.panel?.id)
        .animation(Motion.fast, value: panelCovers)
        .animation(Motion.fast, value: showsQuestion)
    }

    /// 面板蓋住整欄：沒在問數字、或問的只是選起來那一行的數量
    private var panelCovers: Bool { !keypad.isAskingOther }

    /// 選起來的「一筆」（不是這一頁的動作）
    private var itemSelection: DockSelection? {
        guard let s = content.selection, s.isItem else { return nil }
        return s
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPinned {
                DockPinned()
            }
            // 上面這一塊佔掉剩下的高度：題目、快速鍵出現或消失時，鍵與大鍵都貼在最下面不動
            top
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            if showsQuestion {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 14)
                    display
                }
                .padding(.top, 16)
                .transition(.opacity)
            }
            quickKeys
            keys
                .padding(.top, 12)
            bottomKey
                .padding(.top, 12)
        }
        .padding(.horizontal, 20)
        .padding(.top, inSheet ? 22 : 20)
        .padding(.bottom, inSheet ? 8 : 20)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { columnHeight = $0 })
        .background(Theme.dock.ignoresSafeArea())
        .overlay(alignment: .leading) {
            if !inSheet { Rule(vertical: true) }
        }
    }

    // MARK: 上面：選起來的那一筆／正在打數字時的幫手／待機的資訊

    @ViewBuilder
    private var top: some View {
        if let r = keypad.request {
            if r.keepsSelection, let s = itemSelection {
                // 選起來的那一行：卡片與動作鍵照樣在，鍵盤問的是它的數量（手機的 sheet 放不下大卡片，用小的）
                selection(s, compact: inSheet)
            } else {
                // 別的題目（改價、座位、退款金額…）：上面留一張小卡或面板的標題，知道這個數字是給誰的；下面是幫手（找零、熟客）
                VStack(alignment: .leading, spacing: 14) {
                    if let s = itemSelection { DockSelectionHeader(selection: s) }
                    if let p = content.panel { DockPanelStrip(item: p) }
                    DockContext()
                }
            }
        } else if let s = itemSelection {
            selection(s, compact: false)
        } else if let s = content.selection, !s.actions.isEmpty {
            // 這一頁沒選東西時的動作（新增訂位…）在上面，下面照樣是這一刻的資訊。動作鍵太多就捲，不壓到數字鍵
            let rows = CGFloat((s.actions.count + 1) / 2)
            VStack(alignment: .leading, spacing: 18) {
                ScrollView {
                    DockActionKeys(actions: s.actions)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: rows * 52 + (rows - 1) * 8)
                .layoutPriority(1)
                DockContext()
            }
        } else {
            DockContext()
        }
    }

    private func selection(_ s: DockSelection, compact: Bool) -> some View {
        ScrollView {
            DockSelectionView(selection: s, takesEscape: content.panel == nil, compact: compact)
        }
        .scrollIndicators(.hidden)
    }

    /// 題目與大字：問數字時、或待機時打了數字才出現（沒打的時候，鍵盤上面就只有這一頁的動作）
    private var showsQuestion: Bool {
        keypad.isAsking || !keypad.idle.digits.isEmpty
    }

    // MARK: 題目

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(questionTitle, color: keypad.isAsking ? Theme.ink2 : Theme.accentText)
                if let hint = questionHint {
                    Text(hint)
                        .textRole(.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // 選起來那一行的數量：取消＝卡片右上的 ×（不選這一行了），這裡不再放一個
            if let r = keypad.request, showsCancel, !r.keepsSelection {
                Button {
                    keypad.cancel()
                } label: {
                    HeroIcon("x-mark", size: 16)
                }
                .buttonStyle(SquareIconButtonStyle(size: 34))
                .accessibilityLabel("取消")
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    /// 題目：問的題目；待機時打了數字是「下一個品項 × 3」（三碼以內）或「品號 4710…」
    private var questionTitle: String {
        if let r = keypad.request { return r.spec.title }
        if let d = describeIdle, !keypad.idle.digits.isEmpty { return d(keypad.idle.digits).title }
        guard idleActions != nil else { return "數量・品號" }
        if let m = keypad.multiplier { return "下一個品項 × \(m)" }
        return "品號 \(keypad.idle.digits)"
    }

    private var questionHint: String? {
        if let r = keypad.request { return r.spec.subtitle }
        if let d = describeIdle, !keypad.idle.digits.isEmpty { return d(keypad.idle.digits).hint }
        guard idleActions != nil else { return "要輸入數字時會出現在這裡" }
        if let m = keypad.multiplier { return "點品項＝加 \(m) 份；或按「\(idleActions?.title(keypad.idle.digits) ?? "品號")」" }
        return "按「品號」加入這個品號的品項"
    }

    // MARK: 大字

    @ViewBuilder
    private var display: some View {
        let entry = keypad.request?.entry ?? keypad.idle
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let dots = entry.pinDots {
                    HStack(spacing: 16) {
                        ForEach(0..<dots.total, id: \.self) { i in
                            Circle()
                                .fill(i < dots.filled ? Theme.ink : Color.clear)
                                .overlay { Circle().strokeBorder(Theme.ink.opacity(i < dots.filled ? 0 : 0.35), lineWidth: 1.5) }
                                .frame(width: 16, height: 16)
                                .scaleEffect(i == dots.filled - 1 ? 1.15 : 1)
                                .animation(Motion.spring, value: dots.filled)
                        }
                    }
                    .frame(height: 56)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if keypad.isAsking, entry.spec.kind == .money {
                            Text("NT$")
                                .font(.brand(20, .medium))
                                .foregroundStyle(Theme.muted)
                        }
                        if !keypad.isAsking, keypad.multiplier != nil {
                            Text("×")
                                .font(.brand(28, .regular))
                                .foregroundStyle(Theme.muted)
                        }
                        Text(displayText(entry))
                            .textRole(.till)
                            .foregroundStyle(entry.isPristine ? Theme.ink2 : Theme.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                    }
                    .frame(height: 56, alignment: .bottomLeading)
                    .padding(.horizontal, entry.isPristine ? 6 : 0)
                    .background(entry.isPristine ? Theme.accentSoft : .clear, in: .rect(cornerRadius: Metric.radiusSm))
                }
            }
            .offset(x: shake * 10)

            status(entry)
                .frame(height: 20, alignment: .leading)
        }
        .animation(Motion.fast, value: entry.digits)
    }

    private func displayText(_ e: KeypadEntry) -> String {
        if !keypad.isAsking { return e.display }
        if e.digits.isEmpty {
            switch e.spec.kind {
            case .taxId: return "____ ____"
            case .phone: return "09__ ___ ___"
            case .code, .loveCode: return "—"
            default: return e.display
            }
        }
        return e.display
    }

    @ViewBuilder
    private func status(_ e: KeypadEntry) -> some View {
        if let error = keypad.request?.error {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.dangerFG)
        } else if e.isVerified {
            Label("統一編號正確", systemImage: "checkmark.circle.fill")
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.successFG)
        } else if keypad.isAsking, !e.isIncomplete, !e.digits.isEmpty, let p = e.problem {
            Text(p)
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.warningFG)
        }
    }

    // MARK: 快速鍵

    @ViewBuilder
    private var quickKeys: some View {
        if let quick = keypad.request?.spec.quickKeys, !quick.isEmpty {
            // 一般的 Grid（不用 LazyVGrid）：手機的鍵盤在 sheet 裡，懶載入的量測可能跑在主執行緒以外（見 DockActionKeys）
            // 四個（數量的 −1、+1、2、3）排一排；其他一排三個
            let perRow = quick.count == 4 ? 4 : min(quick.count, 3)
            let quiet = keypad.keepsSelection
            let rows = stride(from: 0, to: quick.count, by: perRow).map { Array(quick[$0 ..< min($0 + perRow, quick.count)]) }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r]) { q in
                            quickKey(q, quiet: quiet)
                        }
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    /// quiet：一按就確認的快速鍵平常是墨色實心（「剛好」）；數量的 −1、+1 每一顆都一按就改，用一般的框
    private func quickKey(_ q: KeypadSpec.QuickKey, quiet: Bool) -> some View {
        Button {
            keypad.apply(q)
        } label: {
            Text(q.label)
                .font(.brand(15, .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(QuickKeyStyle(prominent: q.commits && !quiet))
        .accessibilityLabel(q.commits ? "\(q.label)，馬上改" : q.label)
    }

    // MARK: 鍵

    private var keys: some View {
        let entry = keypad.request?.entry ?? keypad.idle
        let bottomLeft: KeypadKey = entry.spec.hasDoubleZero ? .doubleZero : .clear
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { col in
                        key(.digit(row * 3 + col))
                    }
                }
            }
            GridRow {
                key(bottomLeft)
                key(.digit(0))
                key(.backspace)
            }
        }
    }

    private func key(_ k: KeypadKey) -> some View {
        Button {
            keypad.press(k)
        } label: {
            Group {
                switch k {
                case .digit(let n): Text("\(n)").font(.brand(28, .regular))
                case .doubleZero: Text("00").font(.brand(24, .regular))
                case .clear: Text("C").font(.brand(22, .medium)).foregroundStyle(Theme.muted)
                case .backspace: Image(systemName: "delete.left").font(.system(size: 22, weight: .regular))
                }
            }
            .frame(maxWidth: .infinity, minHeight: keyHeight)
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(label(k))
    }

    /// 數字鍵的高度：一般 68；一欄超過 900 點（13 吋橫放、直放）時多出來的分一點給鍵，最高 88。手機的 sheet 照舊
    private var keyHeight: CGFloat {
        guard !inSheet, columnHeight > 900 else { return Metric.keyHeight }
        return min(Metric.keyHeight + (columnHeight - 900) / 6, 88)
    }

    private func label(_ k: KeypadKey) -> String {
        switch k {
        case .digit(let n): "\(n)"
        case .doubleZero: "兩個零"
        case .clear: "清除"
        case .backspace: "刪除"
        }
    }

    // MARK: 最下面那顆大鍵：下一步

    @ViewBuilder
    private var bottomKey: some View {
        if let r = keypad.request {
            // 選起來那一行的數量：沒改是墨色「數量 2」（按了＝好了），打了新的數字變成橘色「改成 3」
            Button {
                keypad.commit()
            } label: {
                Text(r.confirmLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            // 還不能按（電話沒打完…）：細框，不用半透明的橘（看起來像壞掉）
            .buttonStyle(.brand(!r.entry.canCommit ? .ghost : (r.keepsSelection && r.entry.isPristine ? .primary : .accent),
                                size: .lg, fullWidth: true, arrow: true))
            .keyboardShortcut(.defaultAction)
        } else if let s = itemSelection {
            // 選起來的一筆：打了數字也還是它的主要動作（規格卡打的數字＝數量）；沒有主要動作（單子的一行）就空著
            if let p = s.primary {
                primaryKey(p, accent: s.accent, id: s.id)
            } else {
                placeholder
            }
        } else if let s = content.selection, let p = s.primary, idleActions == nil || keypad.idle.digits.isEmpty {
            // 這一頁的動作：打了品號時讓給「品號」
            primaryKey(p, accent: s.accent, id: s.id)
        } else if !keypad.idle.digits.isEmpty {
            if let idleActions {
                HStack(spacing: 8) {
                    Button("清除") { keypad.clearIdle() }
                        .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
                    Button {
                        if let code = keypad.takeCode() { idleActions.commit(code) }
                    } label: {
                        Text(idleActions.title(keypad.idle.digits))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
                }
            } else {
                Button("清除") { keypad.clearIdle() }
                    .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
            }
        } else {
            placeholder
        }
    }

    private func primaryKey(_ p: POSAction, accent: Bool, id: String) -> some View {
        Button(action: p.perform) {
            HStack(spacing: 8) {
                if let icon = p.icon { HeroIcon(icon, size: 17) }
                Text(p.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        // 不能按的大鍵（還沒點錢的「交班並列印」、示範店的「立即同步」）：細框＋淡，不是半透明的實心
        .buttonStyle(.brand(!p.isEnabled ? .ghost : (p.isDestructive ? .danger : (accent ? .accent : .primary)), size: .lg, fullWidth: true, arrow: true))
        .disabled(!p.isEnabled)
        .id(id)
    }

    /// 鍵的位置不動：大鍵那一格空著也留著
    private var placeholder: some View {
        Color.clear.frame(height: BrandButtonStyle.Size.lg.height)
    }
}

/// 鍵：方角 10、按下時品牌橘填滿（和品牌按鈕同一個手感）
struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(pressed ? Theme.onAccent : Theme.ink)
            .background(pressed ? Theme.accent : Theme.key, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
            .scaleEffect(pressed ? 0.96 : 1)
            .contentShape(.rect)
            .hoverEffect(.highlight)
            .animation(pressed ? nil : Motion.fast, value: pressed)
    }
}

struct QuickKeyStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(prominent ? Theme.page : Theme.ink)
            .background(prominent ? Theme.ink : (pressed ? Theme.press : Color.clear), in: .rect(cornerRadius: Metric.radiusSm))
            .overlay {
                RoundedRectangle(cornerRadius: Metric.radiusSm).strokeBorder(prominent ? Color.clear : Theme.line, lineWidth: 1)
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(Motion.fast, value: pressed)
    }
}
