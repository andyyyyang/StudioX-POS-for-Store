import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit
import Vision
import VisionKit

/// 相機掃碼（配對的 QR Code、會員卡、發票載具、折價券、商品條碼）。用 VisionKit 的 DataScanner：在這台處理、不上傳。
///
///   ┌ 掃碼                          × ┐
///   │ 商品、會員卡、載具、折價券都可以    │
///   │ ┌──────── 相機 ─────────┐       │
///   │ │                       │       │
///   │ │ ● 拿鐵 加 1 份・A012   │       │ ← 最後認出的（小標籤，一定說認出了什麼）
///   │ └───────────────────────┘       │
///   │ 這次掃了 3 個  拿鐵 ×2  會員 王小美 │ ← 連續掃：認出了哪些
///   │ [             完成             ] │
///   └─────────────────────────────────┘
///
/// - 只收一種的（載具、會員、折價券、配對）：認出來、做好了就關掉；不對的在相機上說一聲、繼續掃
/// - 連續掃（一般的「掃碼」）：不關掉，商品一個接一個掃；同一個碼 2 秒內不重複算；「完成」關掉
/// - 認出來要先做別的（打開會員頁、選甜度或規格）：關掉相機
/// - 要店員確認的（套折價券會換掉原本的折扣）：在相機上問
struct CodeScannerSheet: View {
    @Environment(POSModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var title: String
    var subtitle: String?
    var types: [DataScannerViewController.RecognizedDataType]
    /// 連續掃（不關掉、有清單、有「完成」）
    var continuous = false
    /// 掃到一個碼：做該做的事、回傳認出了什麼
    var recognise: @MainActor (String) async -> ScanOutcome

    @State private var last: ScanOutcome?
    @State private var tally: [ScanTallyEntry] = []
    @State private var queue: [String] = []
    @State private var working = false
    @State private var finished = false
    @State private var successTick = 0
    @State private var errorTick = 0

    /// subtitle 一定要寫（nil＝預設的說明）：和下面只要一串字的那一個分得開（配對的尾隨閉包不會選錯）
    init(title: String, subtitle: String?, types: [DataScannerViewController.RecognizedDataType], continuous: Bool = false,
         recognise: @escaping @MainActor (String) async -> ScanOutcome) {
        self.title = title
        self.subtitle = subtitle
        self.types = types
        self.continuous = continuous
        self.recognise = recognise
    }

    /// 只要那一串字（配對）：掃到就交出去、關掉
    init(title: String, types: [DataScannerViewController.RecognizedDataType], onCode: @escaping @MainActor (String) -> Void) {
        self.init(title: title, subtitle: nil, types: types) { code in
            onCode(code)
            return .accepted()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle ?? defaultSubtitle, closeLabel: continuous ? "完成" : "取消", close: { close() })
            camera
                .padding(.horizontal, 20)
                .padding(.bottom, continuous ? 14 : 20)
            if continuous {
                tallyRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                Button {
                    close()
                } label: {
                    Text("完成").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand(.primary, size: .lg, fullWidth: true))
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet)
        .sensoryFeedback(.success, trigger: successTick)
        .sensoryFeedback(.error, trigger: errorTick)
        .onAppear { model.scannersOpen += 1 }
        .onDisappear { model.scannersOpen = max(model.scannersOpen - 1, 0) }
        .posSheet()
    }

    private var defaultSubtitle: String {
        continuous ? "一個接一個掃，掃完按「完成」" : "對準條碼，掃到就自動關掉"
    }

    // MARK: 相機

    private var camera: some View {
        ZStack(alignment: .bottom) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ScannerRepresentable(symbologies: types) { code in
                    received(code)
                }
            } else {
                Theme.surface
                EmptyState(icon: "qr-code", title: "這台裝置不能用相機掃碼", message: "請用外接的條碼掃描器，或直接輸入")
            }
            if let last {
                ScanPill(outcome: last)
                    .padding(14)
                    .id(last.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: Metric.radiusLg))
        .overlay {
            if let r = model.confirmRequest {
                ScannerConfirmCard(request: r)
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .animation(Motion.spring, value: last?.id)
        .animation(Motion.fast, value: model.confirmRequest?.id)
    }

    // MARK: 連續掃：認出了哪些

    private var tallyRow: some View {
        let count = tally.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(count == 0 ? "還沒掃到東西" : "這次掃了 \(count) 個")
            if !tally.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(tally) { e in
                            StatusBadge(e.count > 1 ? "\(e.label) ×\(e.count)" : e.label, tone: e.tone)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.fast, value: count)
    }

    // MARK: 掃到了

    /// 一次處理一個（查會員、查折價券要等後台）：掃得快的排隊，不會漏掉
    private func received(_ code: String) {
        guard !finished else { return }
        queue.append(code)
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while !finished, !queue.isEmpty {
            let code = queue.removeFirst()
            let outcome = await recognise(code)
            note(outcome)
            if outcome.closesScanner || (!continuous && outcome.ok) { finish() }
        }
        queue.removeAll()
        working = false
    }

    private func note(_ o: ScanOutcome) {
        last = o
        if o.ok { successTick += 1 } else { errorTick += 1 }
        guard o.ok, let label = o.tally else { return }
        if let i = tally.firstIndex(where: { $0.label == label && $0.kind == o.kind }) {
            var e = tally.remove(at: i)
            e.count += o.count
            tally.insert(e, at: 0)
        } else {
            tally.insert(ScanTallyEntry(kind: o.kind, label: label, count: o.count), at: 0)
        }
    }

    /// 只收一種的：讓店員看一眼認出了什麼再關
    private func finish() {
        guard !finished else { return }
        finished = true
        Task {
            try? await Task.sleep(for: .milliseconds(continuous ? 150 : 450))
            dismiss()
        }
    }

    private func close() {
        finished = true
        dismiss()
    }
}

/// 連續掃的清單：同一樣東西掃好幾次是「拿鐵 ×2」
struct ScanTallyEntry: Identifiable, Equatable {
    var id: String { "\(kind)-\(label)" }
    var kind: ScanOutcome.Kind
    var label: String
    var count: Int

    var tone: Tone {
        switch kind {
        case .member: .gold
        case .carrier: .info
        case .coupon: .active
        case .product, .unknown: .neutral
        }
    }
}

/// 相機上的小標籤：最後認出了什麼（成功是綠點、不對是黃點、不能用是紅點）
private struct ScanPill: View {
    let outcome: ScanOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(outcome.tone.dot)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(outcome.text)
                .font(.brand(15, .medium))
                .foregroundStyle(Theme.onInverse)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.inverse.opacity(0.92), in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// 相機開著時要確認的事（套折價券會換掉原本的折扣）：蓋在相機上的一張卡
private struct ScannerConfirmCard: View {
    @Environment(POSModel.self) private var model
    let request: ConfirmRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.title)
                    .font(.brand(18, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(request.message)
                    .textRole(.small)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                model.answerConfirm(true)
            } label: {
                VStack(spacing: 2) {
                    Text(request.confirmLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let d = request.confirmDetail {
                        Text(d).font(.brand(12.5, .regular)).monospacedDigit().opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.accent, size: .lg, fullWidth: true))
            Button {
                model.answerConfirm(false)
            } label: {
                Text(request.keepLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brand(.ghost, size: .lg, fullWidth: true))
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(Theme.sheet, in: .rect(cornerRadius: Metric.radiusLg + 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg + 6, style: .continuous).strokeBorder(Theme.line) }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }
}

/// 要掃哪些條碼
enum ScanKind {
    /// 手機條碼載具是 Code 39
    static let carrier: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.code39, .qr])]
    static let product: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39, .qr])]
    /// 會員卡：條碼／QR 就是手機號碼（黃毛丫頭的網站印成 Code 128；App、網址是 QR）
    static let member: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.code128, .qr, .code39])]
    /// 折價券：QR、Code 128（網路商店、紙本的折價券）
    static let coupon: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.qr, .code128, .code39])]
    /// 一般的「掃碼」：什麼都收（App 照內容判斷）
    static let all: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.qr, .code128, .code39, .ean13, .ean8, .upce])]
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let symbologies: [DataScannerViewController.RecognizedDataType]
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: Set(symbologies), qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    /// 同一個碼 2 秒內不重複算（拿開再對準就算第二個；一直對著不會重複加）
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Void
        private var lastCode: String?
        private var lastAt = Date.distantPast

        init(onCode: @escaping @MainActor (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let b) = item, let s = b.payloadStringValue, !s.isEmpty else { continue }
                let now = Date()
                if s == lastCode, now.timeIntervalSince(lastAt) < 2 { continue }
                lastCode = s
                lastAt = now
                onCode(s)
                return
            }
        }
    }
}
