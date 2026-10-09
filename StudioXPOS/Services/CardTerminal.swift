import Foundation
import Network
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

// 刷卡機（銀行 EDC 的收銀機連線，「ECR 連線」）：設定、連線（UDP）、正在進行的那一筆。
// 電文、封包、不重複扣款的規則在 POSKit（Packages/POSKit/Sources/POSCore/CardTerminal）；結帳、退款怎麼用在 POSModel+CardTerminal。
// 示範店用模擬的刷卡機（ECRSimulatedTerminal，不連網路、兩秒後核准）。

/// 刷卡機的設定。存在這台（每台 iPad 接自己的刷卡機，和出單機一樣）
nonisolated struct CardTerminalConfig: Codable, Hashable {
    /// 預設關：沒有接刷卡機的店照舊手動輸入末四碼
    var enabled = false
    var format: ECRFormat = .nccc
    var host = ""
    var port = ECRFraming.defaultUDPPort
    /// 等客人刷卡、主機授權最多幾秒；超過就查上一筆
    var timeoutSeconds = 90
    /// 信用卡、銀聯、Smart Pay
    var cards = true
    /// 悠遊卡、一卡通、愛金卡
    var eTickets = false
    /// LINE Pay、悠遊付、全支付…（刷卡機掃客人的付款碼）
    var wallets = false

    init() {}

    // 之後加欄位：舊的設定照樣讀得出來
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CardTerminalConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        format = (try? c.decodeIfPresent(ECRFormat.self, forKey: .format)) ?? d.format
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        cards = try c.decodeIfPresent(Bool.self, forKey: .cards) ?? d.cards
        eTickets = try c.decodeIfPresent(Bool.self, forKey: .eTickets) ?? d.eTickets
        wallets = try c.decodeIfPresent(Bool.self, forKey: .wallets) ?? d.wallets
    }
}

/// 上次跟刷卡機講話的結果（設定頁、左邊的提示）
struct TerminalHealth: Equatable {
    var ok: Bool
    var message: String
    var at = Date()
}

/// 刷卡機：設定、連線、正在進行的那一筆
@Observable
final class CardTerminalHub {
    var config = CardTerminalConfig() {
        didSet { save() }
    }
    var health: TerminalHealth?
    /// 查上一筆、刷卡機結帳的結果（設定頁）
    var lastSummary: String?
    /// 正在進行的那一筆（結帳畫面上那張卡；CardTerminalSheet）
    var session: TerminalSession?
    /// 設定頁的測試、查上一筆、結帳正在跑
    var busy = false

    /// 示範店的刷卡機（同一次示範一直是同一台：查上一筆、取消才對得上）
    @ObservationIgnored private var simulator: ECRSimulatedTerminal?
    @ObservationIgnored private let headers = ECRHeaderSource()

    private static let key = "cardTerminal"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let c = try? JSONDecoder().decode(CardTerminalConfig.self, from: data) {
            config = c
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var trimmedHost: String { config.host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 截圖：示範店用 -cardTerminal 直接打開（不存）
    var demoForced: Bool {
        #if DEBUG
        LaunchArguments.has("-cardTerminal")
        #else
        false
        #endif
    }

    /// 這台能不能用刷卡機收。示範店用模擬的，不用 IP
    func isReady(demo: Bool) -> Bool {
        if demo { return config.enabled || demoForced }
        return config.enabled && config.format.isSupported && !trimmedHost.isEmpty
    }

    /// 這種付款方式要不要經刷卡機
    func covers(_ tender: Tender, demo: Bool) -> Bool {
        let forced = demo && demoForced && !config.enabled
        switch tender {
        case .card: return forced || config.cards
        case .stored: return forced || config.eTickets
        case .linePay, .easyWallet, .pxPay: return forced || config.wallets
        default: return false
        }
    }

    static func kind(for tender: Tender) -> ECRPaymentKind {
        switch tender {
        case .stored: .eTicket
        case .linePay, .easyWallet, .pxPay, .jkoPay: .wallet
        default: .card
        }
    }

    // MARK: 連線

    private struct Connection {
        let driver: NCCCDriver
        let close: @MainActor () -> Void
    }

    private func connect(demo: Bool) async throws -> Connection {
        var options = NCCCDriver.Options(responseTimeout: .seconds(min(max(config.timeoutSeconds, 30), 300)))
        if demo {
            let sim = simulator ?? ECRSimulatedTerminal(delay: .seconds(2))
            simulator = sim
            options.cancelGrace = .seconds(1)
            return Connection(driver: NCCCDriver(transport: sim, options: options, headers: headers), close: {})
        }
        guard config.enabled else { throw ECRError.unsupported("這台沒有打開刷卡機（設定 → 刷卡機）") }
        guard config.format.isSupported else { throw ECRError.unsupported("\(config.format.label)的刷卡機格式即將支援") }
        guard !trimmedHost.isEmpty else { throw ECRError.notConfigured }
        let transport = ECRUDPTransport(host: trimmedHost, port: config.port)
        try await transport.open()
        return Connection(driver: NCCCDriver(transport: transport, options: options, headers: headers), close: { transport.close() })
    }

    /// 做一筆（交易只送一次；等不到結果就查上一筆）
    func perform(_ op: ECROperation, known: Set<String>, watch: ECRWatch, demo: Bool) async -> ECROutcome {
        let connection: Connection
        do {
            connection = try await connect(demo: demo)
        } catch {
            // 連線都沒開成：一定沒送到刷卡機
            let e = (error as? ECRError) ?? .notSent(error.localizedDescription)
            let outcome = ECROutcome.notCharged(e.mayHaveReachedTerminal ? .notSent(e.message) : e)
            note(outcome)
            return outcome
        }
        let outcome = await ECRCharge.run(connection.driver, op, known: known, watch: watch)
        connection.close()
        note(outcome)
        return outcome
    }

    /// 再查一次上一筆（不確定的時候）
    func verify(_ op: ECROperation, known: Set<String>, demo: Bool) async -> ECROutcome {
        let connection: Connection
        do {
            connection = try await connect(demo: demo)
        } catch {
            return .unknown((error as? ECRError) ?? .unreachable(error.localizedDescription))
        }
        let outcome = await ECRCharge.verify(connection.driver, op, known: known)
        connection.close()
        note(outcome)
        return outcome
    }

    /// 示範店：店員「在刷卡機上按了取消」
    func cancelDemo() {
        guard let simulator else { return }
        Task { await simulator.cancelPending() }
    }

    private func note(_ outcome: ECROutcome) {
        switch outcome {
        case .approved, .declined:
            health = TerminalHealth(ok: true, message: "連線正常")
        case .notCharged(let e), .unknown(let e):
            health = e == .notOnTerminal ? TerminalHealth(ok: true, message: "連線正常") : TerminalHealth(ok: false, message: e.message)
        }
    }

    // MARK: 那一筆的卡片

    /// 關掉那張卡（同一筆才關，不會關到下一筆）
    func end(_ s: TerminalSession) {
        if session === s { session = nil }
    }

    func end(_ s: TerminalSession, after delay: Duration) async {
        try? await Task.sleep(for: delay)
        end(s)
    }

    // MARK: 設定頁的動作

    /// 連線測試（98）
    func test(demo: Bool) async {
        guard !busy, session == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let c = try await connect(demo: demo)
            defer { c.close() }
            let r = try await c.driver.echo()
            health = r.isApproved ? TerminalHealth(ok: true, message: "連線正常")
                : TerminalHealth(ok: false, message: "刷卡機回了代碼 \(r.responseCode)")
        } catch {
            health = TerminalHealth(ok: false, message: (error as? ECRError)?.message ?? error.localizedDescription)
        }
    }

    /// 查上一筆（62；上一筆是電子錢包再查 68）
    func checkLast(demo: Bool) async {
        guard !busy, session == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let c = try await connect(demo: demo)
            defer { c.close() }
            var r = try await c.driver.lastTransaction()
            if r.status == .walletLast { r = try await c.driver.walletQuery(orderId: nil) }
            lastSummary = Self.describe(r)
            health = TerminalHealth(ok: true, message: "連線正常")
        } catch {
            let message = (error as? ECRError)?.message ?? error.localizedDescription
            health = TerminalHealth(ok: false, message: message)
            lastSummary = "查不到上一筆：\(message)"
        }
    }

    /// 刷卡機結帳（50）：這一批送給銀行請款、換下一批
    @discardableResult
    func settle(demo: Bool) async -> Bool {
        guard !busy, session == nil else { return false }
        busy = true
        defer { busy = false }
        do {
            let c = try await connect(demo: demo)
            defer { c.close() }
            let r = try await c.driver.settle()
            health = TerminalHealth(ok: true, message: "連線正常")
            guard r.isApproved else {
                lastSummary = "刷卡機結帳沒有成功（代碼 \(r.responseCode)）"
                return false
            }
            let count = r.response.settlementCount.map { "\($0) 筆" } ?? "—"
            let total = r.response.settlementTotal?.formatted ?? "NT$0"
            lastSummary = "刷卡機結帳完成（\(Date().clockText)）：\(count)、\(total)"
            return true
        } catch {
            let message = (error as? ECRError)?.message ?? error.localizedDescription
            health = TerminalHealth(ok: false, message: message)
            lastSummary = "刷卡機結帳沒有成功：\(message)"
            return false
        }
    }

    /// 「上一筆：一般交易 NT$1,280・Visa ****1234・調閱 000123・10/09 14:30・已核准」
    static func describe(_ r: ECRResult) -> String {
        guard r.isApproved else { return "上一筆沒有核准，或刷卡機上沒有上一筆（代碼 \(r.responseCode)）" }
        var parts: [String] = []
        if let t = r.response.transType, t != .lastTransaction, t != .walletQuery { parts.append(t.label) }
        if let a = r.amount { parts.append(a.formatted) }
        let card = [r.brand?.label, r.last4.map { "****\($0)" }].compactMap { $0 }.joined(separator: " ")
        if !card.isEmpty { parts.append(card) }
        if let n = r.receiptNo { parts.append("調閱 \(n)") }
        let d = r.response.transDate, t = r.response.transTime
        if d.count == 6, t.count >= 4 {
            parts.append("\(d.dropFirst(2).prefix(2))/\(d.suffix(2)) \(t.prefix(2)):\(t.dropFirst(2).prefix(2))")
        }
        parts.append("已核准")
        return "上一筆：" + parts.joined(separator: "・")
    }
}

// MARK: - UDP

/// 刷卡機的 UDP 連線（聯卡中心 UDP 收銀機連線，刷卡機預設 50002）。一筆交易開一條，用完關掉。
/// 刷卡機可能回到 POS 這邊的同一個埠：本機也綁同一個埠（綁不到就用系統給的）。收到的封包排隊，receive 一個一個拿
nonisolated final class ECRUDPTransport: ECRTransport, @unchecked Sendable {
    let host: String
    let port: Int
    private let lock = NSLock()
    private var inbox: [[UInt8]] = []
    private var failure: String?
    private var connection: NWConnection?
    private var closed = false
    private let queue = DispatchQueue(label: "tw.studiox.pos.card-terminal")

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// UDP 沒有握手：ready 只代表這台準備好送了（刷卡機在不在，要送了才知道）
    @concurrent func open() async throws {
        guard (1...65_535).contains(port), let p = NWEndpoint.Port(rawValue: UInt16(port)) else { throw ECRError.notConfigured }
        do {
            try await start(p, bindLocal: true)
        } catch {
            try await start(p, bindLocal: false)
        }
    }

    private func start(_ p: NWEndpoint.Port, bindLocal: Bool) async throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if bindLocal { params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: p) }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { c.resume() }
                case .failed(let e), .waiting(let e):
                    conn.cancel()
                    once.run { c.resume(throwing: ECRError.unreachable(ECRUDPTransport.describe(e))) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.run {
                    conn.cancel()
                    c.resume(throwing: ECRError.unreachable("5 秒連不上"))
                }
            }
        }
        // 之後斷線：記下來，收的時候丟錯
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.fail(ECRUDPTransport.describe(e)) }
        }
        lock.lock()
        connection = conn
        lock.unlock()
        listen(conn)
    }

    @concurrent func send(_ packet: [UInt8]) async throws {
        guard let conn = current() else { throw ECRError.notSent("還沒連線") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(packet), completion: .contentProcessed { error in
                if let error {
                    c.resume(throwing: ECRError.unreachable(ECRUDPTransport.describe(error)))
                } else {
                    c.resume()
                }
            })
        }
    }

    @concurrent func receive(timeout: Duration) async throws -> [UInt8]? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let packet = take() { return packet }
            if let f = failed() { throw ECRError.unreachable(f) }
            if clock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        lock.lock()
        closed = true
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
    }

    /// 一次收一個封包；收完再收下一個（照順序）
    private func listen(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.deliver([UInt8](data)) }
            if let error {
                self.fail(ECRUDPTransport.describe(error))
                return
            }
            if !self.isClosed { self.listen(conn) }
        }
    }

    private func current() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : connection
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func deliver(_ packet: [UInt8]) {
        lock.lock()
        inbox.append(packet)
        lock.unlock()
    }

    private func take() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    private func fail(_ message: String) {
        lock.lock()
        if failure == nil && !closed { failure = message }
        lock.unlock()
    }

    private func failed() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    static func describe(_ e: NWError) -> String {
        if case .posix(let code) = e {
            switch code {
            case .ECONNREFUSED: return "刷卡機的連接埠沒有回應（銀行要在 TMS 開收銀機連線與 UDP）"
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return "找不到刷卡機（IP、Wi-Fi；iPad 的「區域網路」權限要允許 StudioX POS）"
            case .EADDRINUSE: return "這台 iPad 的連接埠被占用"
            default: break
            }
        }
        return e.localizedDescription
    }
}

// MARK: - 正在進行的那一筆

/// 刷卡機的那張卡上的按鈕：再試一次、再查一次、手動記／只改 POS、改用退貨、關掉
enum TerminalChoice: Hashable {
    case retry, recheck, bypass, alternate, close
}

struct TerminalButton: Identifiable, Hashable {
    let choice: TerminalChoice
    let title: String
    var prominent = false
    var id: TerminalChoice { choice }
}

/// 正在跟刷卡機做的那一筆：結帳、退回付款、退款時那張卡（CardTerminalSheet）看它
@Observable
final class TerminalSession: Identifiable {
    enum Purpose: Equatable {
        case charge(ECRPaymentKind)
        case refund(ECRPaymentKind)
        case void
    }

    enum Phase: Equatable {
        /// 送出去了（刷卡機還沒回 ACK）
        case sending
        /// 刷卡機收到了：等客人
        case waiting
        /// 按了取消：等刷卡機回
        case cancelling
        /// 等不到結果：查上一筆
        case checking
        case approved(String)
        /// 沒有成功（標題、說明）：沒有扣款／沒有退
        case failed(String, String)
        /// 不確定：要看刷卡機
        case unknown(String, String)

        var isWorking: Bool {
            switch self {
            case .sending, .waiting, .cancelling, .checking: true
            default: false
            }
        }
    }

    let id = UUID()
    let purpose: Purpose
    let title: String
    let amount: Money
    var phase: Phase = .sending
    var buttons: [TerminalButton] = []
    @ObservationIgnored private(set) var watch = ECRWatch()
    @ObservationIgnored private var pending: CheckedContinuation<TerminalChoice, Never>?
    /// 按了取消時（示範店：模擬「在刷卡機上按取消」）
    @ObservationIgnored var onCancel: (() -> Void)?

    init(purpose: Purpose, title: String, amount: Money) {
        self.purpose = purpose
        self.title = title
        self.amount = amount
        renewWatch()
    }

    /// 每一次送出用新的（上一次按過取消的不能沿用）
    func renewWatch() {
        watch = ECRWatch { [weak self] p in
            let target = self
            Task { @MainActor in target?.progressed(p) }
        }
        phase = .sending
        buttons = []
    }

    private func progressed(_ p: ECRProgress) {
        switch p {
        case .sent: break
        case .acknowledged: if phase == .sending { phase = .waiting }
        case .cancelling: phase = .cancelling
        case .checking: phase = .checking
        }
    }

    /// 取消：刷卡機可能已經在扣款，不是馬上斷線——等它回（或查上一筆）才知道
    func cancel() {
        guard phase == .sending || phase == .waiting else { return }
        watch.requestCancel()
        phase = .cancelling
        onCancel?()
    }

    /// 停下來問店員要怎麼做
    func ask(_ phase: Phase, buttons: [TerminalButton]) async -> TerminalChoice {
        self.phase = phase
        self.buttons = buttons
        return await withCheckedContinuation { c in pending = c }
    }

    func choose(_ choice: TerminalChoice) {
        guard let p = pending else { return }
        pending = nil
        buttons = []
        p.resume(returning: choice)
    }
}
