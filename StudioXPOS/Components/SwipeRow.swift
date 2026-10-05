import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 一列可以左右滑（單子上的一行；不是 List，所以自己做）：
///
///   往左滑 ←：右邊露出 trailing 的鍵（紅色「刪除」）；滑到底＝fullTrailing（沒有就只露出鍵）
///   往右滑 →：左邊露出 leading 的鍵（−1、+1）；滑到底＝fullLeading
///   露出來的鍵 keepsOpen（−1、+1）：可以連按，這一列開著不收，內容（數量）照樣看得到、跟著變
///
/// - 一次只開一列：外面的清單給一個 `openId`，開了這一列，別列自己收起來
/// - 不搶直的捲動、不搶 sheet 往下滑關掉：用 UIKit 的 pan（HorizontalPan），橫的速度明顯大過直的才開始；
///   捲動與 sheet 的拖曳等這一個先放棄才開始（直的一動就放棄，所以捲起來不會慢）
/// - 超過可以滑的範圍會越拉越緊（rubber band）；過了「滑到底」的那條線震一下，放開就做
/// - 開著的時候點這一列＝收起來（不會順便選起來）
/// - VoiceOver：每個鍵也是這一列的「動作」
///
/// content 要有不透明的底（鍵畫在它後面）
struct SwipeRow<Content: View>: View {
    let id: String
    @Binding var openId: String?
    var leading: [SwipeAction] = []
    var trailing: [SwipeAction] = []
    /// 往右滑到底
    var fullLeading: SwipeAction? = nil
    /// 往左滑到底（nil＝只露出鍵；例如已經送廚房的要作廢、要主管，不能一滑就做）
    var fullTrailing: SwipeAction? = nil
    var enabled = true
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var start: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var dragging = false
    /// 過了「滑到底」的線（放開就做）
    @State private var armed = false
    /// 按了露出來的鍵（輕輕震一下）
    @State private var tapTick = 0

    /// 一顆鍵的寬
    private let keyWidth: CGFloat = 76

    private var leadingWidth: CGFloat { CGFloat(leading.count) * keyWidth }
    private var trailingWidth: CGFloat { CGFloat(trailing.count) * keyWidth }

    /// 滑到底的線：露出的鍵再過去一段、至少一半的寬
    private func fullThreshold(_ reveal: CGFloat) -> CGFloat {
        max(reveal + 72, width * 0.55)
    }

    var body: some View {
        content
            .overlay {
                // 開著：點這一列（跟著滑開的內容）＝收起來；露出來的鍵不蓋住
                if offset != 0 && !dragging {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset)
            // 鍵畫在這一列原本的位置後面、和這一列一樣高（內容滑開才露出來）
            .background { keys }
            .clipped()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .gesture(HorizontalPan(
            isEnabled: enabled && !(leading.isEmpty && trailing.isEmpty),
            // 斜斜的捲動不打開這一列（橫的要是直的 1.8 倍：大約 30 度以內）
            ratio: 1.8,
            onBegan: {
                start = offset
                dragging = true
                if openId != id { openId = id }
            },
            onChanged: { dx in drag(to: start + dx) },
            onEnded: { dx, vx in end(at: start + dx, velocity: vx) },
            onCancelled: {
                dragging = false
                armed = false
                close()
            }
        ))
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
        .sensoryFeedback(.selection, trigger: tapTick)
        .onChange(of: openId) { _, now in
            if now != id && offset != 0 && !dragging { close() }
        }
        .onChange(of: enabled) { _, on in
            if !on { close() }
        }
        .accessibilityActions {
            ForEach(leading + trailing) { a in
                Button(a.title) { a.perform() }
            }
        }
    }

    // MARK: 後面的鍵

    private var keys: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                side(armed ? fullLeading.map { [$0] } ?? leading : leading)
                    .frame(width: offset)
            }
            Spacer(minLength: 0)
            if offset < 0 {
                side(armed ? fullTrailing.map { [$0] } ?? trailing : trailing)
                    .frame(width: -offset)
            }
        }
        .accessibilityHidden(true)
    }

    private func side(_ actions: [SwipeAction]) -> some View {
        HStack(spacing: 0) {
            ForEach(actions) { a in
                Button {
                    tapTick += 1
                    if !a.keepsOpen { close() }
                    a.perform()
                } label: {
                    VStack(spacing: 4) {
                        if let icon = a.icon { HeroIcon(icon, size: 18) }
                        Text(a.title)
                            .font(.brand(13.5, .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(a.foreground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(a.tint)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .clipped()
    }

    // MARK: 拖、放

    private func drag(to raw: CGFloat) {
        let x = limited(raw)
        offset = x
        let now = (x > 0 && fullLeading != nil && x > fullThreshold(leadingWidth))
            || (x < 0 && fullTrailing != nil && -x > fullThreshold(trailingWidth))
        if now != armed {
            withAnimation(Motion.fast) { armed = now }
        }
    }

    /// 這一邊沒有鍵：只能拉一點點；有鍵但不能滑到底：過了鍵的寬越拉越緊；能滑到底：拉到整列的寬再越拉越緊
    private func limited(_ raw: CGFloat) -> CGFloat {
        if raw > 0 {
            let limit: CGFloat = leading.isEmpty ? 0 : (fullLeading == nil ? leadingWidth : max(width, leadingWidth))
            return rubber(raw, limit: limit)
        } else {
            let limit: CGFloat = trailing.isEmpty ? 0 : (fullTrailing == nil ? trailingWidth : max(width, trailingWidth))
            return -rubber(-raw, limit: limit)
        }
    }

    private func rubber(_ x: CGFloat, limit: CGFloat) -> CGFloat {
        guard x > limit else { return x }
        let over = x - limit
        // 超過的部分越拉越緊（最多再多 60 點）
        return limit + 60 * (1 - 1 / (over / 120 + 1))
    }

    private func end(at raw: CGFloat, velocity: CGFloat) {
        dragging = false
        let x = limited(raw)
        let wasArmed = armed
        armed = false
        if wasArmed, x > 0, let full = fullLeading {
            // 往右滑到底（+1）：彈回來、做
            withAnimation(Motion.spring) { offset = 0 }
            openId = nil
            full.perform()
            return
        }
        if wasArmed, x < 0, let full = fullTrailing {
            // 往左滑到底（刪除）：整列滑出去、再做
            withAnimation(.easeOut(duration: 0.18)) { offset = -max(width, trailingWidth) }
            openId = nil
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                full.perform()
                withAnimation(Motion.fast) { offset = 0 }
            }
            return
        }
        // 放開：照位置與速度決定開哪一邊或收起來
        let projected = x + velocity * 0.12
        if projected > leadingWidth / 2, !leading.isEmpty {
            open(leadingWidth)
        } else if projected < -trailingWidth / 2, !trailing.isEmpty {
            open(-trailingWidth)
        } else {
            close()
        }
    }

    private func open(_ x: CGFloat) {
        withAnimation(Motion.spring) { offset = x }
        openId = id
    }

    private func close() {
        withAnimation(Motion.spring) { offset = 0 }
        if openId == id { openId = nil }
    }
}

/// 滑出來的一顆鍵
struct SwipeAction: Identifiable {
    var id: String { title }
    var title: String
    var icon: String?
    /// 鍵的底色（Theme 的色票：淺色、深色各一個）
    var tint: Color
    var foreground: Color
    /// 按了這一列照樣開著（−1、+1 可以連按）；false＝按了就收起來（刪除）
    var keepsOpen: Bool
    var perform: @MainActor () -> Void

    init(_ title: String, icon: String? = nil, tint: Color, foreground: Color, keepsOpen: Bool = false,
         perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.foreground = foreground
        self.keepsOpen = keepsOpen
        self.perform = perform
    }
}
