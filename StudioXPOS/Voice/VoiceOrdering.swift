import AVFoundation
import Foundation
import FoundationModels
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import Speech
import SwiftUI

/// 語音點餐（手機）：按住下面那條單子說話，放開就加進單子。
///
///   按住 → 開始聽（字一邊出來）→ 放開 → 這一段交給 Apple 的模型（Foundation Models）整理成要點的東西
///   （品名、價錢／規格、幾份、備註）→ 對到菜單 → 加進單子
///
/// - 一段一段的：第一段還在整理，就可以按住說第二段（每一段自己整理、整理好就加）
/// - 沒有 Apple Intelligence 的手機：直接從整句話找菜單上的品名與數量（VoiceOrderText.parse）
/// - 對不到的不亂加：沒說哪個價錢、要選口味、賣完了的寫在這一段的結果裡（不跳警告），其他的照樣加
/// - 聽寫在手機上做（支援的話不上網）；菜單的品名先給聽寫，認得比較準
@Observable
final class VoiceOrdering {
    struct Segment: Identifiable, Equatable {
        enum State: Equatable {
            case listening
            case thinking
            /// 加了什麼（「鴨胸 140 ×2、鴨心 ×1」）、沒加的原因
            case done(added: String, problems: [String])
            case failed(String)
        }

        let id = UUID()
        var text = ""
        var state = State.listening
    }

    private(set) var segments: [Segment] = []
    /// 按住中（正在聽）
    private(set) var listening = false
    /// 不能用的原因（沒給麥克風、語音辨識權限；這支手機不支援）
    private(set) var problem: String?

    @ObservationIgnored private let recorder = SpeechRecorder()
    @ObservationIgnored private var currentId: UUID?
    /// 第幾次按住（問權限時放開又按：只有最後這一次開麥克風）
    @ObservationIgnored private var press = 0

    /// 這支手機能不能聽寫中文（不能就不出現「按住說話」）
    var isSupported: Bool { SpeechRecorder.isSupported }

    /// 現在正在聽的那一段說到哪
    var liveText: String { segments.first { $0.id == currentId }?.text ?? "" }

    // MARK: 按住、放開

    /// 按住：開始聽一段（上一段還在整理也可以）。馬上算按住（問權限、開麥克風在後面），放開得再快也收得到
    func begin(model: POSModel) {
        guard !listening else { return }
        listening = true
        problem = nil
        press &+= 1
        let token = press
        Task { await start(model: model, press: token) }
    }

    private func start(model: POSModel, press: Int) async {
        guard await SpeechRecorder.authorize() else {
            if press == self.press { listening = false }
            problem = "要在「設定 → StudioX POS」打開麥克風與語音辨識，才能用說的點餐"
            return
        }
        // 放開得太快（還在問權限時就放開了）、又按了一次：不開始（交給最後那一次）
        guard listening, press == self.press else { return }
        let segment = Segment()
        segments.append(segment)
        currentId = segment.id
        let id = segment.id
        let names = model.catalog.items.map(\.name)
        do {
            try recorder.start(contextualStrings: names) { [weak self] text in
                let me = self
                Task { @MainActor in me?.update(id, text: text) }
            } onFinal: { [weak self, weak model] text in
                let me = self, owner = model
                Task { @MainActor in
                    guard let me, let owner else { return }
                    await me.finish(id, text: text, model: owner)
                }
            }
            VoiceInterpreter.prewarm(catalog: model.catalog)
        } catch {
            listening = false
            currentId = nil
            set(id, .failed("麥克風打不開：\(error.localizedDescription)"))
        }
    }

    /// 放開：這一段不再聽，交給模型整理（整理好自己加進單子）
    func end() {
        guard listening else { return }
        listening = false
        currentId = nil
        recorder.stop()
    }

    /// 結果看過了就收起來（整理好的幾秒後自己收）
    func dismiss(_ id: UUID) {
        segments.removeAll { $0.id == id }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: 一段的經過

    private func update(_ id: UUID, text: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }), segments[i].state == .listening || segments[i].state == .thinking else { return }
        segments[i].text = text
    }

    private func set(_ id: UUID, _ state: Segment.State) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].state = state
    }

    /// 聽完一段：整理 → 對到菜單 → 加進單子
    private func finish(_ id: UUID, text raw: String, model: POSModel) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id, text: text)
        guard !text.isEmpty else {
            set(id, .failed("沒有聽到"))
            autoDismiss(id)
            return
        }
        set(id, .thinking)
        let lines = await VoiceInterpreter.lines(for: text, catalog: model.catalog)
        guard !lines.isEmpty else {
            set(id, .failed("菜單上沒有聽到的東西"))
            autoDismiss(id, after: 6)
            return
        }
        var added: [String] = []
        var problems: [String] = []
        for line in lines {
            if let why = reason(notToAdd: line, model: model) {
                problems.append(why)
                continue
            }
            model.add(line.item, variant: line.variant, quantity: line.quantity, modifiers: [], note: line.note)
            let variant = line.variant.map { " \($0.label)" } ?? ""
            let note = line.note.isEmpty ? "" : "（\(line.note)）"
            added.append("\(line.item.name)\(variant) ×\(line.quantity)\(note)")
        }
        set(id, .done(added: added.joined(separator: "、"), problems: problems))
        autoDismiss(id, after: problems.isEmpty ? 4 : 8)
    }

    /// 不能直接加的原因（沒說價錢、要選口味、賣完…）：寫在結果裡，請店員點一下
    private func reason(notToAdd line: VoiceOrderText.Line, model: POSModel) -> String? {
        let item = line.item
        if !model.isAvailable(item) { return "\(item.name) 今天賣完了" }
        if line.needsVariant {
            let options = item.activeVariants.map { item.price(of: $0).plain }.joined(separator: "／")
            return "\(item.name) 要說哪一個（\(options)）"
        }
        if let v = line.variant, !v.isAvailable { return "\(item.name) \(v.label) 今天不能賣" }
        if model.catalog.groups(for: item).contains(where: { $0.minSelect > 0 }) { return "\(item.name) 要選\(model.catalog.groups(for: item).map(\.name).joined(separator: "、"))，請點一下" }
        if item.openPrice { return "\(item.name) 要打金額，請點一下" }
        if item.itemKind.needsMember { return "\(item.name) 要先找會員" }
        return nil
    }

    private func autoDismiss(_ id: UUID, after seconds: Double = 4) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(Motion.fast) { self?.dismiss(id) }
        }
    }
}

// MARK: - 整理成要點的東西

/// Apple 的模型（Foundation Models）整理出來的一段話
@Generable
nonisolated struct SpokenOrder {
    @Guide(description: "這段話要點的每一樣；同一樣東西不同價錢要分成兩行")
    var lines: [SpokenLine]
}

@Generable
nonisolated struct SpokenLine {
    @Guide(description: "菜單上的品名，照菜單上的寫法")
    var name: String
    @Guide(description: "說到的價錢或規格，例如 140、150、大、小；沒說就是空字串")
    var option: String
    @Guide(description: "幾份；沒說就是 1", .range(1...99))
    var quantity: Int
    @Guide(description: "備註，例如 不要辣、切小塊、分開裝；沒有就是空字串")
    var note: String
}

enum VoiceInterpreter {
    /// 這支手機有 Apple Intelligence 的模型可以用
    static var modelAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// 一段話 → 對到菜單的幾樣。有模型先用模型；模型不能用、出錯、整理不出東西就直接從整句話找
    static func lines(for text: String, catalog: Catalog) async -> [VoiceOrderText.Line] {
        if modelAvailable, let lines = try? await modelLines(for: text, catalog: catalog), !lines.isEmpty {
            return lines
        }
        return VoiceOrderText.parse(text, catalog: catalog)
    }

    /// 按住時先把模型叫醒（放開時比較快）
    static func prewarm(catalog: Catalog) {
        guard modelAvailable else { return }
        LanguageModelSession(instructions: instructions(catalog)).prewarm()
    }

    private static func modelLines(for text: String, catalog: Catalog) async throws -> [VoiceOrderText.Line] {
        // 每一段一個 session：好幾段同時整理也不會互相等
        let session = LanguageModelSession(instructions: instructions(catalog))
        let response = try await session.respond(to: text, generating: SpokenOrder.self)
        return response.content.lines.compactMap { line in
            guard let item = VoiceOrderText.match(name: line.name, in: catalog) else { return nil }
            return VoiceOrderText.Line(item: item, variant: VoiceOrderText.variant(line.option, of: item),
                                       quantity: max(1, min(line.quantity, 99)), note: line.note.trimmingCharacters(in: .whitespaces))
        }
    }

    /// 給模型的說明：店員說的話 → 菜單上的品項；菜單一行一樣（有幾種價錢寫出來）
    private static func instructions(_ catalog: Catalog) -> String {
        let menu = catalog.items.map { item -> String in
            let prices = item.activeVariants.map { item.price(of: $0).plain }
            let detail = prices.isEmpty ? item.price.plain : prices.joined(separator: "／")
            let unit = item.unit.contains(where: \.isNumber) ? "，\(item.unit)" : ""
            return "- \(item.name)（\(detail)\(unit)）"
        }.joined(separator: "\n")
        return """
        你在台灣夜市的小吃攤幫店員點餐。把店員說的一段話整理成要點的品項。
        - name 一定要是下面菜單上的品名（照菜單寫）；菜單上沒有的不要寫
        - option 是說到的價錢或規格（例如「鴨胸 140」的 140）；沒說就空字串
        - quantity 是幾份（兩份＝2、三個＝3）；沒說就是 1
        - note 是備註（不要辣、切小塊）；沒有就空字串
        菜單：
        \(menu)
        """
    }
}

// MARK: - 聽寫（麥克風 → 文字）

/// 一段一段聽：按住時開始、放開時停；停了以後辨識還會回最後的結果（onFinal 只回一次）。
/// 不在主執行緒上（麥克風的回呼在別的執行緒），回呼裡自己切回主執行緒
nonisolated final class SpeechRecorder: @unchecked Sendable {
    private static let locale = Locale(identifier: "zh-TW")
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: SpeechRecorder.locale)
    private var request: SFSpeechAudioBufferRecognitionRequest?

    static let isSupported = SFSpeechRecognizer(locale: locale) != nil

    /// 第一次用：問語音辨識與麥克風的權限
    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(contextualStrings: [String], onText: @escaping @Sendable (String) -> Void, onFinal: @escaping @Sendable (String) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw RecorderError.unavailable }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let box = SegmentBox(request: request, onFinal: onFinal)

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            box.request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.request = request
        box.task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                box.latest = text
                onText(text)
                if result.isFinal { box.deliver() }
            }
            if error != nil { box.deliver() }
        }
        current = box
    }

    private var current: SegmentBox?

    /// 放開：不再收聲音；最後的結果晚一點回（最多等 1.5 秒，等不到就用聽到的最後一句）
    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        if let box = current {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { box.deliver() }
        }
        current = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum RecorderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "這支手機現在不能聽寫中文" }
    }
}

/// 一段的狀態（麥克風、辨識的回呼在別的執行緒改它）：最後的結果只回一次
nonisolated private final class SegmentBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    private let onFinal: @Sendable (String) -> Void
    private let lock = NSLock()
    private var delivered = false
    private var _latest = ""
    var task: SFSpeechRecognitionTask?

    init(request: SFSpeechAudioBufferRecognitionRequest, onFinal: @escaping @Sendable (String) -> Void) {
        self.request = request
        self.onFinal = onFinal
    }

    var latest: String {
        get { lock.withLock { _latest } }
        set { lock.withLock { _latest = newValue } }
    }

    func deliver() {
        let text: String? = lock.withLock {
            guard !delivered else { return nil }
            delivered = true
            return _latest
        }
        guard let text else { return }
        task?.finish()
        onFinal(text)
    }
}
