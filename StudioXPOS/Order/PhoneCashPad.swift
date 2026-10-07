import POSCore
import SwiftUI

/// 手機的現金模式：點餐頁下面常駐的鍵盤（不用另外叫出來，像 iPad 右邊一直都在的那一個）。
///
///   打金額 →「收現金 NT$120」：加一筆「其他」、整張單收現金結帳（POSModel.commitTyped → cashCheckout）
///   沒打數字、單子上有東西 →「收現金 NT$480」：收整張單
///   先掃載具：發票開到載具（說明那一行會寫）
/// 上面的菜單照樣可以點：點了加到單子，按「收現金」一起收。
/// 上面那一行往下滑＝收起來（只留打了多少與「收現金」，畫面讓給菜單）；往上滑、點一下＝打開。收著還是開著記在這支手機
struct PhoneCashPad: View {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    /// 「看單子」：打開單子的 sheet
    let openTicket: () -> Void

    static let collapsedKey = "phoneCashPadCollapsed"
    /// 數字鍵收起來了（bool(forKey:)：截圖的 -phoneCashPadCollapsed YES 也讀得到）
    @State private var collapsed = UserDefaults.standard.bool(forKey: PhoneCashPad.collapsedKey)
    /// 開著時往下拉了多少（整塊跟著手指往下）
    @State private var dragY: CGFloat = 0

    var body: some View {
        // 正在問別的數字（會員電話…）時用的是升起來的那一個鍵盤，這裡當作沒打
        let digits = keypad.isAsking ? "" : keypad.idle.digits
        VStack(spacing: 10) {
            header(digits)
            if !collapsed {
                keys
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                Button {
                    keypad.clearIdle()
                } label: {
                    Text("C")
                        .font(.brand(20, .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 64, height: BrandButtonStyle.Size.lg.height)
                }
                .buttonStyle(KeyStyle())
                .disabled(digits.isEmpty)
                .accessibilityLabel("清除")
                Button {
                    confirm(digits)
                } label: {
                    Text(confirmTitle(digits))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.accent, size: .lg, fullWidth: true))
                .disabled(!canConfirm(digits))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(Theme.dock)
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: collapsed ? 0 : max(dragY, 0))
        .sensoryFeedback(.selection, trigger: keypad.keyTick)
        .sensoryFeedback(.impact(weight: .light), trigger: collapsed)
        .onChange(of: collapsed) { _, c in
            UserDefaults.standard.set(c, forKey: Self.collapsedKey)
        }
    }

    // MARK: 收起來、打開

    /// 拖曳的橫條＋打了多少：往下滑收起來、往上滑（或點一下）打開
    private func header(_ digits: String) -> some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(Theme.faint)
                .frame(width: 36, height: 5)
            display(digits)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            if collapsed { setCollapsed(false) }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if !collapsed { dragY = v.translation.height }
                }
                .onEnded { v in
                    let dy = v.translation.height
                    let fling = v.predictedEndTranslation.height
                    withAnimation(Motion.spring) {
                        dragY = 0
                        if !collapsed, dy > 50 || fling > 160 {
                            collapsed = true
                        } else if collapsed, dy < -24 || fling < -120 {
                            collapsed = false
                        }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(collapsed ? "打開數字鍵" : "收起數字鍵")) { setCollapsed(!collapsed) }
    }

    private func setCollapsed(_ c: Bool) {
        withAnimation(Motion.spring) { collapsed = c }
        model.touch()
    }

    // MARK: 上面：打了多少、按下去會怎樣

    private var ticket: Ticket? {
        model.selectedTicket.flatMap { $0.activeLines.isEmpty ? nil : $0 }
    }

    private func display(_ digits: String) -> some View {
        let (title, hint) = describe(digits)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brand(30, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(digits.isEmpty ? Theme.ink2 : Theme.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(hint)
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if let t = ticket {
                Button(action: openTicket) {
                    HStack(spacing: 4) {
                        Text("單子 \(t.itemCount) 項")
                        Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.brand(14, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.surface, in: .capsule)
                    .overlay { Capsule().strokeBorder(Theme.line) }
                }
                .buttonStyle(PressScale(scale: 0.96))
                .accessibilityLabel("看單子，\(t.itemCount) 項")
            }
        }
        .padding(.horizontal, 4)
        .animation(Motion.fast, value: digits)
    }

    private func describe(_ digits: String) -> (String, String) {
        if !digits.isEmpty { return model.describeTyped(digits) }
        let carrier = model.pendingCarrier.flatMap { $0.isFresh ? $0.carrier.id : nil }
        if collapsed {
            if let t = ticket { return (t.totals.balance.formatted, "按「收現金」結帳・往上滑打開數字鍵") }
            if let c = carrier { return ("NT$0", "往上滑打開數字鍵打金額・發票開到載具 \(c)") }
            return ("NT$0", "點上面的品項，或往上滑打開數字鍵打金額")
        }
        if let t = ticket { return (t.totals.balance.formatted, "單上的品項：按「收現金」結帳；也可以再打金額一起收") }
        if let c = carrier { return ("NT$0", "打金額按「收現金」・發票開到載具 \(c)") }
        return ("NT$0", "打金額，按「收現金」就結帳；先掃載具就開到載具")
    }

    // MARK: 鍵

    private var keys: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { col in
                        key(.digit(row * 3 + col))
                    }
                }
            }
            GridRow {
                key(.doubleZero)
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
                case .digit(let n): Text("\(n)").font(.brand(26, .regular))
                case .doubleZero: Text("00").font(.brand(22, .regular))
                case .clear: Text("C").font(.brand(20, .medium))
                case .backspace: Image(systemName: "delete.left").font(.system(size: 20, weight: .regular))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
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

    // MARK: 大鍵

    private func confirmTitle(_ digits: String) -> String {
        if !digits.isEmpty { return model.typedConfirmTitle(digits) }
        if let t = ticket { return "收現金 \(t.totals.balance.formatted)" }
        return "收現金"
    }

    private func canConfirm(_ digits: String) -> Bool {
        !digits.isEmpty || ticket != nil
    }

    private func confirm(_ digits: String) {
        model.touch()
        if !digits.isEmpty {
            if let code = keypad.takeCode() { model.commitTyped(code) }
        } else if let t = ticket {
            model.beginCheckout(t)
        }
    }
}
