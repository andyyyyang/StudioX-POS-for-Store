import AVFoundation
import Foundation
import FoundationModels
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import Speech
import SwiftUI

/// 語音點餐（手機，要有 Apple Intelligence；沒有的手機不出現）：按住下面那條單子說話，放開就加進單子。
///
///   按住 → 聽寫（在手機上；字一邊出來，別字一邊改回菜單上的名字）→ 放開 → 這一段交給 Apple 的模型
///   整理成「品項・規格・幾份・備註」（只能從菜單的名字裡選）→ 加進單子
///
/// 準：
/// - 聽寫先拿到菜單上的品名（contextualStrings）
/// - 別字照讀音改回菜單上的名字（VoiceMenu.corrected：「壓胸」→「鴨胸」；「兩份」不會變成「涼粉」）
/// - 模型只能從菜單的名字裡選；選了話裡沒說到的（硬湊的）不加
/// 快：
/// - 模型的 session 先準備好、讀過說明與菜單（prewarm）：放開時直接問；一個 session 只問一次（前一段不會越積越長）
/// - 給模型的菜單寫成一行、不附 JSON 格式說明（格式由框架限制）、不隨機（greedy）
/// - 放開後最多等聽寫 0.5 秒的最後結果
/// 一段一段的：上一段還在整理就可以按住說下一段。沒說價錢、要選口味、賣完的不加，寫在那一段的結果裡（不跳警告）
@Observable
final class VoiceOrdering {
    struct Segment: Identifiable, Equatable {
        enum State: Equatable {
            case listening
            case thinking
            /// 加了什麼（「鴨胸 140 ×2、鴨心 ×1」）、沒加的原因、放開到加好幾秒
            case done(added: String, problems: [String], seconds: Double)
            case failed(String)
        }

        let id = UUID()
        var text = ""
        var state = State.listening
        /// 放開的時候（算放開到加好花了幾秒）
        var releasedAt: Date?
    }

    private(set) var segments: [Segment] = []
    /// 按住中（正在聽）
    private(set) var listening = false
    /// 不能用的原因（沒給麥克風、語音辨識權限）
    private(set) var problem: String?

    @ObservationIgnored private let recorder = SpeechRecorder()
    @ObservationIgnored private let interpreter = VoiceInterpreter()
    @ObservationIgnored private var currentId: UUID?
    /// 第幾次按住（問權限時放開又按：只有最後這一次開麥克風）
    @ObservationIgnored private var press = 0

    /// 能用說的點餐：手機上能聽寫中文、有 Apple Intelligence（沒有就不出現「按住說話」）
    var isSupported: Bool { SpeechRecorder.isSupported && VoiceInterpreter.isAvailable }

    // MARK: 按住、放開

    /// 按住：開始聽一段（上一段還在整理也可以）。馬上算按住（問權限、開麥克風在後面），放開得再快也收得到
    func begin(model: POSModel) {
        guard !listening else { return }
        listening = true
        problem = nil
        press &+= 1
        let token = press
        // 菜單的讀音、先熱好的模型（菜單沒變就不重做）
        interpreter.prepare(model.catalog)
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
        do {
            try recorder.start(contextualStrings: interpreter.vocabulary) { [weak self] text in
                let me = self
                Task { @MainActor in me?.update(id, heard: text) }
            } onFinal: { [weak self, weak model] text in
                let me = self, owner = model
                Task { @MainActor in
                    guard let me, let owner else { return }
                    await me.finish(id, heard: text, model: owner)
                }
            }
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
        if let id = currentId, let i = segments.firstIndex(where: { $0.id == id }) {
            segments[i].releasedAt = Date()
        }
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

    /// 聽寫的字（還在聽、整理中才更新）：別字一邊改回菜單上的名字
    private func update(_ id: UUID, heard: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }), segments[i].state == .listening || segments[i].state == .thinking else { return }
        segments[i].text = interpreter.corrected(heard)
    }

    private func set(_ id: UUID, _ state: Segment.State) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].state = state
    }

    /// 聽完一段：改別字 → 模型整理 → 加進單子
    private func finish(_ id: UUID, heard: String, model: POSModel) async {
        update(id, heard: heard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let text = segments.first(where: { $0.id == id })?.text, !text.isEmpty else {
            set(id, .failed("沒有聽到"))
            autoDismiss(id)
            return
        }
        set(id, .thinking)
        let lines: [VoiceOrderText.Line]
        do {
            lines = try await interpreter.lines(for: text)
        } catch {
            set(id, .failed("沒整理出來，再說一次"))
            autoDismiss(id, after: 6)
            return
        }
        guard !lines.isEmpty else {
            set(id, .failed("菜單上沒有聽到的東西"))
            autoDismiss(id, after: 6)
            return
        }
        var added: [String] = []
        var problems: [String] = []
        for line in lines {
            if let why = reason(notToAdd: line, text: text, model: model) {
                problems.append(why)
                continue
            }
            model.add(line.item, variant: line.variant, quantity: line.quantity, modifiers: [], note: line.note)
            let variant = line.variant.map { " \($0.label)" } ?? ""
            let note = line.note.isEmpty ? "" : "（\(line.note)）"
            added.append("\(line.item.name)\(variant) ×\(line.quantity)\(note)")
        }
        let released = segments.first { $0.id == id }?.releasedAt ?? Date()
        set(id, .done(added: added.joined(separator: "、"), problems: problems, seconds: Date().timeIntervalSince(released)))
        autoDismiss(id, after: problems.isEmpty ? 4 : 8)
    }

    /// 不能直接加的原因（沒說到、沒說價錢、要選口味、賣完…）：寫在結果裡，請店員點一下
    private func reason(notToAdd line: VoiceOrderText.Line, text: String, model: POSModel) -> String? {
        let item = line.item
        if !interpreter.mentions(item, in: text) { return "沒聽到「\(item.name)」，沒有加" }
        if !model.isAvailable(item) { return "\(item.name) 今天賣完了" }
        if line.needsVariant {
            let options = item.activeVariants.map { item.price(of: $0).plain }.joined(separator: "／")
            return "\(item.name) 要說哪一個（\(options)）"
        }
        if let v = line.variant, !v.isAvailable { return "\(item.name) \(v.label) 今天不能賣" }
        let groups = model.catalog.groups(for: item)
        if groups.contains(where: { $0.minSelect > 0 }) { return "\(item.name) 要選\(groups.map(\.name).joined(separator: "、"))，請點一下" }
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

/// 一段話 → 菜單上的幾樣：Apple 的模型，輸出的格式由框架限制（品項只能是菜單上的名字）
final class VoiceInterpreter {
    /// 這支手機有 Apple Intelligence 的模型可以用
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private var menu: VoiceMenu?
    private var menuKey = ""
    private var schema: GenerationSchema?
    private var instructions = ""
    /// 先準備好、讀過說明與菜單的 session；用掉一個補一個
    private var ready: LanguageModelSession?

    /// 不隨機（同一句話每次一樣、也比較快）；一段話最多二十行，夠用
    private static let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 400)

    /// 給聽寫參考的品名
    var vocabulary: [String] { menu?.vocabulary ?? [] }

    func corrected(_ text: String) -> String { menu?.corrected(text) ?? text }

    func mentions(_ item: MenuItem, in text: String) -> Bool { menu?.mentions(item, in: text) ?? true }

    /// 按住時：菜單變了才重建讀音與格式；沒有熱好的 session 就熱一個（趁說話的時候讀菜單）
    func prepare(_ catalog: Catalog) {
        let key = Self.key(catalog)
        if key != menuKey {
            let menu = VoiceMenu(catalog: catalog, pronounce: Pinyin.reading)
            self.menu = menu
            menuKey = key
            schema = menu.isEmpty ? nil : (try? Self.schema(menu))
            instructions = Self.instructions(menu)
            ready = nil
        }
        if ready == nil, schema != nil { ready = warmSession() }
    }

    func lines(for text: String) async throws -> [VoiceOrderText.Line] {
        guard let menu, let schema else { return [] }
        // 用熱好的那一個（沒有就現開一個：上一段還在整理時又說了一段）
        let session = ready ?? warmSession()
        ready = nil
        let response = try await session.respond(to: text, schema: schema, includeSchemaInPrompt: false, options: Self.options)
        if ready == nil { ready = warmSession() }
        let rows = try response.content.value([GeneratedContent].self, forProperty: "lines")
        return rows.compactMap { row -> VoiceOrderText.Line? in
            guard let label = try? row.value(String.self, forProperty: "item"), let item = menu.item(label: label) else { return nil }
            let spec = (try? row.value(String.self, forProperty: "spec")) ?? ""
            let quantity = (try? row.value(Int.self, forProperty: "qty")) ?? 1
            let note = ((try? row.value(String.self, forProperty: "note")) ?? "").trimmingCharacters(in: .whitespaces)
            return VoiceOrderText.Line(item: item, variant: VoiceOrderText.variant(spec, of: item),
                                       quantity: max(1, min(quantity, 99)), note: note)
        }
    }

    private func warmSession() -> LanguageModelSession {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        return session
    }

    /// 菜單有沒有變（品項、名字、規格的價錢）
    private static func key(_ catalog: Catalog) -> String {
        catalog.items.map { item in
            let prices = item.activeVariants.map { "\($0.id)=\(item.price(of: $0).cents)" }.joined(separator: ",")
            return "\(item.id)|\(item.categoryId)|\(item.name)|\(item.shortName ?? "")|\(prices)"
        }.joined(separator: "\n")
    }

    /// 輸出的格式：{ lines: [{ item: 菜單上的名字之一, spec?, qty, note? }] }
    private static func schema(_ menu: VoiceMenu) throws -> GenerationSchema {
        let item = DynamicGenerationSchema(name: "MenuItem", anyOf: menu.entries.map(\.label))
        let text = DynamicGenerationSchema(type: String.self)
        let count = DynamicGenerationSchema(type: Int.self)
        let properties: [DynamicGenerationSchema.Property] = [
            DynamicGenerationSchema.Property(name: "item", schema: item),
            DynamicGenerationSchema.Property(name: "spec", schema: text, isOptional: true),
            DynamicGenerationSchema.Property(name: "qty", schema: count),
            DynamicGenerationSchema.Property(name: "note", schema: text, isOptional: true),
        ]
        let line = DynamicGenerationSchema(name: "Line", properties: properties)
        let lines = DynamicGenerationSchema.Property(name: "lines", schema: DynamicGenerationSchema(arrayOf: line))
        let order = DynamicGenerationSchema(name: "Order", properties: [lines])
        return try GenerationSchema(root: order, dependencies: [])
    }

    /// 說明越短越快：怎麼填、菜單一行
    private static func instructions(_ menu: VoiceMenu) -> String {
        """
        把店員說的話整理成要點的品項 lines。
        item：菜單上的名字；話裡沒點到的不要寫。
        spec：菜單括號裡有幾種價錢或規格的，說到哪個寫哪個；沒說就不寫。
        qty：幾份（兩份＝2、三個＝3）；沒說就是 1。
        note：備註（不要辣、切小塊）；沒有就不寫。
        菜單：\(menu.menuLine)
        """
    }
}

/// 一個中文字的讀音（「鴨」→「ya1」）：系統的拼音轉換，算過的記起來（菜單與說的話都用這個）
nonisolated enum Pinyin {
    private static let cache = ReadingCache()

    static let reading: VoiceMenu.Pronounce = { c in Pinyin.cache.reading(of: c) }
}

nonisolated private final class ReadingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var memo: [Character: String?] = [:]

    func reading(of c: Character) -> String? {
        if let hit = lock.withLock({ memo[c] }) { return hit }
        let value = Self.compute(c)
        lock.withLock { memo[c] = .some(value) }
        return value
    }

    /// 「鴨」→ "yā" → 聲調 1、去掉聲調符號 "ya" →「ya1」（輕聲 5）
    private static func compute(_ c: Character) -> String? {
        guard c.unicodeScalars.count == 1, let u = c.unicodeScalars.first,
              (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || (0xF900...0xFAFF).contains(u.value),
              let latin = String(c).applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        var tone = "5"
        for mark in latin.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch mark.value {
            case 0x0304: tone = "1"
            case 0x0301: tone = "2"
            case 0x030C: tone = "3"
            case 0x0300: tone = "4"
            default: break
            }
        }
        let base = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased().filter { $0.isASCII && $0.isLetter }
        return base.isEmpty ? nil : base + tone
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

    /// 放開：不再收聲音；最後的結果晚一點回（最多等 0.5 秒，等不到就用聽到的最後一句：手機上聽寫的最後一句幾乎就是結果）
    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        if let box = current {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { box.deliver() }
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
