import POSCore
import SwiftUI
import UIKit

/// 手機的現金模式：點餐頁下面一張卡（不用另外叫出來，像 iPad 右邊一直都在的那一個）。
///
///   打金額 →「收現金 NT$120」：加一筆「其他」、整張單收現金結帳（POSModel.commitTyped → cashCheckout）
///   沒打數字、單子上有東西 →「收現金 NT$480」：收整張單
///   先掃載具：發票開到載具（說明那一行會寫）
/// 上面的菜單照樣可以點：點了加到單子，按「收現金」一起收。
///
/// 拖起來和系統的 sheet 一樣：卡跟著手指走、拉過頭有阻尼，放開照速度彈到兩個高度裡近的那一個——
///   開著：打了多少、「收現金」、數字鍵
///   收起來：只留打了多少與「收現金」（數字鍵滑到下面，畫面讓給菜單）
/// 只動位置不動版面（菜單不用每一格重排），收著還是開著記在這支手機。
/// 不用系統的 sheet：它會蓋住下面的分頁，單子、加料、掃碼、印交易明細這些也都得改從它上面出
struct PhoneCashPad: View {
    @Environment(POSModel.self) private var model
    /// 「看單子」：打開單子的 sheet
    let openTicket: () -> Void
    /// 這張卡開著的高度（菜單捲到底要讓出來的；收起來也一樣讓，捲動的位置不會跳）
    @Binding var height: CGFloat

    static let collapsedKey = "phoneCashPadCollapsed"
    /// 數字鍵收起來了（bool(forKey:)：截圖的 -phoneCashPadCollapsed YES 也讀得到）
    @State private var collapsed = UserDefaults.standard.bool(forKey: PhoneCashPad.collapsedKey)
    /// 拖著的時候卡往下移了多少（0＝開著、travel＝收起來，超出去的有阻尼）；沒在拖＝nil
    @State private var dragOffset: CGFloat?
    /// 收起來要往下移多少：數字鍵那一塊
    @State private var travel: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            if model.selectedTicket == nil, let sale = model.lastSale, Date().timeIntervalSince(sale.closedAt) < 120 {
                LastSaleStrip(sale: sale)
            }
            // equatable：拖的時候（dragOffset 每一格都變）卡的內容不重算
            PhoneCashCard(collapsed: collapsed, openTicket: openTicket, setCollapsed: { settle(collapsed: $0) }, travel: $travel)
                .equatable()
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height = $0 })
        // 只有這裡跟著手指變：卡的內容不重畫
        .offset(y: dragOffset ?? (collapsed ? travel : 0))
        .gesture(VerticalPan(onChanged: drag, onEnded: release))
        // 往下移出去的數字鍵不畫到下面的分頁上
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .clipped()
        .onChange(of: collapsed) { _, c in
            UserDefaults.standard.set(c, forKey: Self.collapsedKey)
        }
    }

    // MARK: 拖

    private func drag(_ dy: CGFloat) {
        let raw = (collapsed ? travel : 0) + dy
        if raw < 0 {
            dragOffset = -Self.rubber(-raw)
        } else if raw > travel {
            dragOffset = travel + Self.rubber(raw - travel)
        } else {
            dragOffset = raw
        }
    }

    /// 放開：甩得夠快照方向，不然看停下來的地方（加上一點慣性）比較靠近哪一個高度
    private func release(_ dy: CGFloat, _ velocity: CGFloat) {
        let current = dragOffset ?? (collapsed ? travel : 0)
        let toCollapsed: Bool
        if velocity > 500 {
            toCollapsed = true
        } else if velocity < -500 {
            toCollapsed = false
        } else {
            toCollapsed = current + velocity * 0.15 > travel / 2
        }
        settle(collapsed: toCollapsed, from: current, velocity: velocity)
    }

    /// 彈到那個高度：接著手指的速度（不會放開時頓一下）
    private func settle(collapsed c: Bool, from current: CGFloat? = nil, velocity: CGFloat = 0) {
        let start = current ?? (collapsed ? travel : 0)
        let distance = (c ? travel : 0) - start
        let relative = abs(distance) > 1 ? min(max(Double(velocity / distance), -30), 30) : 0
        withAnimation(.interpolatingSpring(duration: 0.42, bounce: 0.06, initialVelocity: relative)) {
            collapsed = c
            dragOffset = nil
        }
        model.touch()
    }

    /// 拉過頭的阻尼（和捲動拉到底一樣：越拉越緊）
    private static func rubber(_ x: CGFloat, limit: CGFloat = 80) -> CGFloat {
        (1 - 1 / (x / limit * 0.55 + 1)) * limit
    }
}

/// 卡本身：上面一條橫條、打了多少、「收現金」，下面數字鍵（收起來時移到畫面外，按不到、VoiceOver 也跳過）
private struct PhoneCashCard: View, Equatable {
    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    let collapsed: Bool
    let openTicket: () -> Void
    let setCollapsed: (Bool) -> Void
    @Binding var travel: CGFloat

    private static let spacing: CGFloat = 10

    /// 只看收起來沒有（打的數字、單子這些從 environment 來，變了照樣重畫；閉包、binding 指的都是同一份狀態）
    nonisolated static func == (a: PhoneCashCard, b: PhoneCashCard) -> Bool {
        a.collapsed == b.collapsed
    }

    var body: some View {
        // 正在問別的數字（會員電話…）時用的是升起來的那一個鍵盤，這裡當作沒打
        let digits = keypad.isAsking ? "" : keypad.idle.digits
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
        VStack(spacing: Self.spacing) {
            header(digits)
            confirmRow(digits)
            keys
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { travel = $0 + Self.spacing })
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, Self.spacing)
        .background {
            // 往下多畫一截：往上拉過頭時底下不會露出縫
            shape
                .fill(Theme.dock)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -2)
                .padding(.bottom, -240)
        }
        .sensoryFeedback(.selection, trigger: keypad.keyTick)
    }

    // MARK: 上面：橫條、打了多少

    /// 收起來時點一下＝打開
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
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(collapsed ? "打開數字鍵" : "收起數字鍵")) { setCollapsed(!collapsed) }
    }

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

    // MARK: 大鍵（在數字鍵上面：收起來也按得到）

    private func confirmRow(_ digits: String) -> some View {
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

    // MARK: 數字鍵

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
}

/// 卡上的上下拖（UIKit 的 pan，和系統 sheet 一樣：直的比橫的多才接；接了以後按到一半的鍵取消，不會順便按下去）
private struct VerticalPan: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // 用視窗的座標：卡自己在動，用卡的座標量會越拉越偏
        let dy = recognizer.translation(in: nil).y
        switch recognizer.state {
        case .began, .changed:
            onChanged(dy)
        case .ended:
            onEnded(dy, recognizer.velocity(in: nil).y)
        case .cancelled, .failed:
            onEnded(dy, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: nil)
            let v = pan.velocity(in: nil)
            let d = hypot(t.x, t.y) >= 6 ? t : v
            return abs(d.y) > abs(d.x)
        }
    }
}
