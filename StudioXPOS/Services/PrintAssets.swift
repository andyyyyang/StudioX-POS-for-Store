import Foundation
import ImageIO
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 單據樣式的圖（店標、頁尾、底圖、貼圖）。
///
/// - 開機資料來的時候（`PrinterHub.applyStyle`）下載，存在 Application Support/print-assets（檔名＝網址的 SHA-256）：斷網照樣印
/// - 印的時候同步讀（記憶體 → 磁碟）：**列印從來不等網路**，還沒下載好、下載失敗的圖就不印
/// - 樣式沒用到的檔案清掉
/// - 示範的圖（`demo-art://…`）不下載：在這台 iPad 上用 SwiftUI 畫成 PNG（DemoPrintArt）
@Observable
final class PrintAssets {
    /// 有新的圖進來（設定頁的「單據樣式」預覽跟著重畫）
    private(set) var revision = 0
    /// 下載失敗的網址（設定頁顯示）
    private(set) var failed: Set<String> = []
    /// 已經讀進來的（網址 → 圖）。印的時候會順便放進來，不需要讓畫面重畫
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// 印的時候：記憶體 → 磁碟；都沒有就是 nil（這張圖不印）
    func image(for url: String?) -> UIImage? {
        guard let url, !url.isEmpty else { return nil }
        if let img = images[url] { return img }
        guard let data = try? Data(contentsOf: Self.file(for: url)), let img = Self.decode(data) else { return nil }
        images[url] = img
        return img
    }

    /// 這份樣式的圖還缺幾張（下載中或失敗）
    func missing(in style: PrintStyle) -> Int {
        style.imageURLs.filter { image(for: $0) == nil }.count
    }

    /// 照樣式準備好所有的圖：已經有的不再抓；prune＝清掉這份樣式沒用到的檔案
    func sync(_ style: PrintStyle, prune: Bool = true) async {
        let urls = style.imageURLs
        for url in urls.sorted() where image(for: url) == nil {
            await fetch(url)
        }
        if prune { self.prune(keeping: urls) }
        revision += 1
    }

    /// 自己畫好的圖（示範）直接放進來
    func store(_ data: Data, for url: String) {
        guard let img = Self.decode(data) else { return }
        try? data.write(to: Self.file(for: url), options: .atomic)
        images[url] = img
        failed.remove(url)
    }

    private func fetch(_ url: String) async {
        guard !loading.contains(url) else { return }
        loading.insert(url)
        defer { loading.remove(url) }
        let data: Data?
        if url.hasPrefix(DemoPrintArt.scheme) {
            data = DemoPrintArt.png(for: url)
        } else if let remote = URL(string: url), ["https", "http"].contains(remote.scheme?.lowercased() ?? "") {
            data = await Self.download(remote)
        } else {
            data = nil
        }
        guard let data, Self.decode(data) != nil else {
            failed.insert(url)
            return
        }
        store(data, for: url)
    }

    /// 樣式沒用到的檔案刪掉（換了店標、拿掉底圖之後）
    private func prune(keeping urls: Set<String>) {
        let keep = Set(urls.map { Self.file(for: $0).lastPathComponent })
        let dir = Self.directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where !keep.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        images = images.filter { urls.contains($0.key) }
        failed = failed.intersection(urls)
    }

    nonisolated static func download(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        let (data, response) = result
        guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 300 else { return nil }
        return data
    }

    /// Application Support/print-assets（不跟著 iCloud 備份：開機資料來了會再下載）
    static var directory: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("print-assets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    static func file(for url: String) -> URL {
        let ext = (URL(string: url)?.pathExtension ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return directory.appendingPathComponent(Crypto.SHA256.hex(url) + (ext.isEmpty || ext.count > 5 ? "" : ".\(ext)"))
    }

    /// 解碼（很大的照片先縮到 1600 點寬：紙最寬 576 點，再大也印不出來）。1 px＝1 點（scale 1）
    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }
}
