import SwiftUI
import UIKit
import Vision
import VisionKit

/// 相機掃碼（配對的 QR Code、客人的手機條碼載具、商品條碼）。用 VisionKit 的 DataScanner：在 iPad 上處理、不上傳
struct CodeScannerSheet: View {
    var title: String
    var types: [DataScannerViewController.RecognizedDataType]
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: "對準條碼，掃到就自動關掉", closeLabel: "取消", close: { dismiss() })
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ScannerRepresentable(symbologies: types) { code in
                    onCode(code)
                    dismiss()
                }
                .clipShape(.rect(cornerRadius: Metric.radiusLg))
                .padding([.horizontal, .bottom], 20)
            } else {
                EmptyState(icon: "qr-code", title: "這台裝置不能用相機掃碼", message: "請用外接的條碼掃描器，或直接輸入")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet)
        .posSheet()
    }
}

/// 要掃哪些條碼
enum ScanKind {
    static let pairing: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.qr])]
    /// 手機條碼載具是 Code 39
    static let carrier: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.code39, .qr])]
    static let product: [DataScannerViewController.RecognizedDataType] = [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39, .qr])]
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let symbologies: [DataScannerViewController.RecognizedDataType]
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: Set(symbologies), qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue, !s.isEmpty {
                    done = true
                    onCode(s)
                    return
                }
            }
        }
    }
}
