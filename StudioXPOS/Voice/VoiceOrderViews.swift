import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 按住（UIKit 的長按）：按住 0.35 秒算開始，手指離開（或被系統取消）算放開。
/// 開始了以後手指移動也照樣算按住；還沒開始就移動（往上滑打開單子）就不是按住
struct HoldGesture: UIGestureRecognizerRepresentable {
    var isEnabled = true
    var minimumDuration: Double = 0.35
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = minimumDuration
        g.allowableMovement = 14
        g.delegate = context.coordinator
        g.isEnabled = isEnabled
        return g
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: onBegan()
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }

    /// 和那條的點一下、往上滑一起認（點一下太短不會變成按住；按住了那一下的點、滑由那條自己不理）
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// 下面那條單子上面：正在聽的這一段（字一邊出來）、還在整理的、整理好加了什麼。點一下收起來
struct VoiceOrderPanel: View {
    let voice: VoiceOrdering

    var body: some View {
        VStack(spacing: 6) {
            if let problem = voice.problem {
                row(icon: "exclamation-triangle", tint: Theme.warningFG, title: problem, detail: nil, busy: false)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(Motion.fast) { voice.dismissProblem() } }
            }
            ForEach(voice.segments) { segment in
                segmentRow(segment)
                    .contentShape(.rect)
                    .onTapGesture {
                        guard segment.state != .listening else { return }
                        withAnimation(Motion.fast) { voice.dismiss(segment.id) }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .animation(Motion.fast, value: voice.segments)
        .animation(Motion.fast, value: voice.problem)
    }

    @ViewBuilder
    private func segmentRow(_ s: VoiceOrdering.Segment) -> some View {
        switch s.state {
        case .listening:
            row(icon: "microphone", tint: Theme.accent, title: s.text.isEmpty ? "說要點什麼，放開就加進單子" : s.text,
                detail: s.text.isEmpty ? "例如「鴨胸 140 兩份、鴨心一串」" : "放開就加進單子", busy: false, live: true)
        case .thinking:
            row(icon: "sparkles", tint: Theme.accentText, title: "「\(s.text)」", detail: "整理中…（可以接著按住說下一段）", busy: true)
        case .done(let added, let problems, let seconds):
            row(icon: added.isEmpty ? "exclamation-triangle" : "check-circle", tint: added.isEmpty ? Theme.warningFG : Theme.successFG,
                title: added.isEmpty ? "「\(s.text)」沒有加" : "加了 \(added)",
                detail: problems.isEmpty ? nil : problems.joined(separator: "；"), busy: false, detailTint: Theme.warningFG,
                trailing: String(format: "%.1f 秒", seconds))
        case .failed(let why):
            row(icon: "exclamation-triangle", tint: Theme.warningFG, title: why, detail: s.text.isEmpty ? nil : "「\(s.text)」", busy: false)
        }
    }

    private func row(icon: String, tint: Color, title: String, detail: String?, busy: Bool, live: Bool = false,
                     detailTint: Color = Theme.muted, trailing: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    HeroIcon(icon, size: 18)
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: live)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.brand(15, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.brand(12.5, .regular))
                        .foregroundStyle(detailTint)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            // 放開到加好幾秒（夠不夠快一眼看得到）
            if let trailing {
                Text(trailing)
                    .font(.brand(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Metric.radiusLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radiusLg, style: .continuous)
                .strokeBorder(live ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: live ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}
