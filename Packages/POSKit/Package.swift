// swift-tools-version: 6.2
//
// POSKit：StudioX POS 的核心（沒有畫面）。
//
//   POSCore     金額與稅、菜單、桌位、單子、付款、交班、事件與狀態（同一串事件在每台 iPad、伺服器算出一樣的結果）、
//               數字鍵盤的輸入規則、加解密（SHA-256、HMAC、PBKDF2、AES-128，純 Swift）、
//               銀行刷卡機的收銀機連線（聯卡中心 8N1 電文、封包、不重複扣款；CardTerminal/，連線在 App）
//   POSInvoice  台灣電子發票：期別、字軌號碼段、開立、證明聯的一維與二維條碼
//   POSPrinting 出單機：ESC/POS 指令、點陣圖、收據／廚房單／交班報表的版面
//   POSSync     本機事件日誌（雜湊鏈）、和後台同步、API 的資料格式
//
// 只用 Foundation，Linux 上也能 `swift test`（GitHub Actions 的 Linux 便宜，畫面以外的邏輯都在這裡測）。
import PackageDescription

let package = Package(
    name: "POSKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "POSCore", targets: ["POSCore"]),
        .library(name: "POSInvoice", targets: ["POSInvoice"]),
        .library(name: "POSPrinting", targets: ["POSPrinting"]),
        .library(name: "POSSync", targets: ["POSSync"]),
    ],
    targets: [
        .target(name: "POSCore"),
        .target(name: "POSInvoice", dependencies: ["POSCore"]),
        .target(name: "POSPrinting", dependencies: ["POSCore", "POSInvoice"]),
        .target(name: "POSSync", dependencies: ["POSCore", "POSInvoice", "POSPrinting"]),
        .testTarget(name: "POSCoreTests", dependencies: ["POSCore"]),
        .testTarget(name: "POSInvoiceTests", dependencies: ["POSCore", "POSInvoice"]),
        .testTarget(name: "POSPrintingTests", dependencies: ["POSCore", "POSInvoice", "POSPrinting"]),
        .testTarget(name: "POSSyncTests", dependencies: ["POSCore", "POSInvoice", "POSPrinting", "POSSync"]),
    ],
    swiftLanguageModes: [.v6]
)
