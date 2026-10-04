import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右側固定鍵盤（畫面最右邊那一欄）：左邊選、右邊做。
///
///   ┌────────────────────┐
///   │ 桌位            ×  │  選起來的那一筆（.dockSelection）：卡片＋動作鍵
///   │ A2・4 位・32 分     │  沒選東西：這一刻最需要的資訊（DockContext：熱賣、桌況、接下來的預約…）
///   │ [換桌]   [併桌]    │
///   │ 收現金          ×  │  題目：要打數字時才出現，緊貼在鍵的上面
///   │      NT$ 1,500     │  大字（PIN 是圓點、統編四碼一組）＋規則（對了打勾、錯了紅字搖一下）
///   │ [剛好][1,300][1,500]│  快速鍵
///   │  1    2    3       │
///   │  4    5    6       │  鍵位永遠一樣、位置永遠不動
///   │  7    8    9       │
///   │  00   0    ⌫       │
///   │ [      收款      ] │  最下面那顆大鍵＝下一步：問數字時確認；選了東西時是它的主要動作
///   └────────────────────┘
///
/// 不用打數字的選擇（.dockPanel）蓋住整欄；要打數字時讓開，打完再回來。
struct KeypadDock: View {
    @Environment(KeypadController.self) private var keypad
    /// 待機時的兩個動作（點餐畫面：「品號」查品項；其他畫面沒有）
    var idleActions: IdleActions? = nil
    /// 畫面交上來的：選起來的那一筆、蓋住整欄的面板（MainShell 收集）
    var content = DockContent()
    /// 題目右上的「取消」。鎖定、配對畫面的鍵盤一直在等 PIN／配對碼，取消沒有意義
    var showsCancel = true
    /// 最上面固定的一塊（DockPinned：外帶的叫號）。只有收銀台的右欄放
    var showsPinned = false

    struct IdleActions {
        var lookup: (String) -> Void
    }

    @State private var shake: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            column
            if let panel = content.panel, !keypad.isAsking {
                DockPanelChrome(item: panel)
                    .id(panel.id)
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
        .animation(Motion.fast, value: showsQuestion)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsPinned {
                DockPinned()
            }
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
        .padding(20)
        .frame(maxHeight: .infinity)
        .background(Theme.dock.ignoresSafeArea())
        .overlay(alignment: .leading) { Rule(vertical: true) }
    }

    // MARK: 上面：選起來的那一筆／正在打數字時的幫手／待機的資訊

    @ViewBuilder
    private var top: some View {
        if !keypad.isAsking, let s = content.selection, s.isItem {
            ScrollView {
                DockSelectionView(selection: s, takesEscape: content.panel == nil)
            }
            .scrollIndicators(.hidden)
        } else if !keypad.isAsking, let s = content.selection, !s.actions.isEmpty {
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

    /// 題目與大字：問數字時、點餐畫面待機（數量・品號）、或待機時打了數字才出現
    private var showsQuestion: Bool {
        keypad.isAsking || idleActions != nil || !keypad.idle.digits.isEmpty
    }

    // MARK: 題目

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(keypad.request?.spec.title ?? "數量・品號", color: keypad.isAsking ? Theme.ink2 : Theme.muted)
                Text(keypad.request?.spec.subtitle ?? idleHint)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if keypad.isAsking && showsCancel {
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

    private var idleHint: String {
        idleActions == nil ? "要輸入數字時會出現在這裡" : "先打數量再點品項；或打品號按「品號」"
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
                        if !keypad.isAsking {
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
        if !keypad.isAsking { return e.digits.isEmpty ? "1" : e.display }
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
        } else if !keypad.isAsking, keypad.multiplier != nil {
            Text("點品項＝加 \(keypad.multiplier ?? 1) 份")
                .font(.brand(13.5, .medium))
                .foregroundStyle(Theme.accentText)
        }
    }

    // MARK: 快速鍵

    @ViewBuilder
    private var quickKeys: some View {
        if let quick = keypad.request?.spec.quickKeys, !quick.isEmpty {
            // 一般的 Grid（不用 LazyVGrid）：手機的鍵盤在 sheet 裡，懶載入的量測可能跑在主執行緒以外（見 DockActionKeys）
            let perRow = min(quick.count, 3)
            let rows = stride(from: 0, to: quick.count, by: perRow).map { Array(quick[$0 ..< min($0 + perRow, quick.count)]) }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r]) { q in
                            quickKey(q)
                        }
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    private func quickKey(_ q: KeypadSpec.QuickKey) -> some View {
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
        .buttonStyle(QuickKeyStyle(prominent: q.commits))
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
            .frame(maxWidth: .infinity, minHeight: Metric.keyHeight)
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(label(k))
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
            Button {
                keypad.commit()
            } label: {
                Text(r.spec.confirmLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.accent, size: .lg, fullWidth: true, arrow: true))
            .opacity(r.entry.canCommit ? 1 : 0.55)
            .keyboardShortcut(.defaultAction)
        } else if let s = content.selection, let p = s.primary, s.isItem || idleActions == nil || keypad.idle.digits.isEmpty {
            // 選起來的一筆：打了數字也還是它的主要動作（規格卡打的數字＝數量）；頁面動作在打了品號時讓給「品號」
            Button(action: p.perform) {
                HStack(spacing: 8) {
                    if let icon = p.icon { HeroIcon(icon, size: 17) }
                    Text(p.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(p.isDestructive ? .danger : (s.accent ? .accent : .primary), size: .lg, fullWidth: true, arrow: true))
            .disabled(!p.isEnabled)
            .id(s.id)
        } else if let idleActions {
            HStack(spacing: 8) {
                Button("清除") { keypad.clearIdle() }
                    .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
                Button {
                    if let code = keypad.takeCode() { idleActions.lookup(code) }
                } label: {
                    Text("品號").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
                .disabled(keypad.idle.digits.isEmpty)
            }
        } else if !keypad.idle.digits.isEmpty {
            Button("清除") { keypad.clearIdle() }
                .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
        } else {
            // 鍵的位置不動：大鍵那一格空著也留著
            Color.clear.frame(height: BrandButtonStyle.Size.lg.height)
        }
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
