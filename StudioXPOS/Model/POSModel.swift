import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

/// 側欄的每一頁
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case order, floor, orders, reservations, kitchen, dashboard, shift, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .order: "點餐"
        case .floor: "桌位"
        case .orders: "訂單"
        case .reservations: "訂位"
        case .kitchen: "廚房"
        case .dashboard: "報表"
        case .shift: "交班"
        case .settings: "設定"
        }
    }

    var icon: String {
        switch self {
        case .order: "squares-2x2"
        case .floor: "table-cells"
        case .orders: "queue-list"
        case .reservations: "calendar-days"
        case .kitchen: "fire"
        case .dashboard: "chart-bar"
        case .shift: "banknotes"
        case .settings: "cog-6-tooth"
        }
    }
}

/// 畫面下方跳出來的一句話（「已結帳 A023・找零 NT$302」）
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var tone: Tone = .active
}

/// 授權：自己有權限，或某位主管在右側鍵盤輸入了 PIN
enum Authorization: Equatable {
    case allowed
    case by(StaffMember)

    var authorizerId: String? {
        if case .by(let s) = self { return s.id }
        return nil
    }
}

/// POS 的大腦：設定（菜單、桌位、人員）、事件與狀態、同步、目前誰在用、在哪一頁。
///
/// 畫面只讀它的屬性、呼叫它的方法；每個會改資料的動作都變成事件寫進日誌（Ledger），
/// 狀態從事件算出來（StoreState），再送到後台與同一個 Wi-Fi 的其他 iPad。
@Observable
final class POSModel {
    enum Phase: Equatable { case launching, pairing, locked, ready }

    var phase: Phase = .launching

    // MARK: 設定（bootstrap）

    var pairing: DeviceStore.Pairing?
    var device = DeviceProfile(id: "", name: "", code: "A", role: .register, stations: [])
    var store = StoreProfile(name: "StudioX POS")
    var features = FeatureFlags.all
    var catalog = Catalog.empty
    var floor = FloorPlan.empty
    var staff: [StaffMember] = []
    var invoiceSettings = InvoiceSettings.disabled
    var meshConfig: MeshConfig?
    var configVersion: String?
    var isDemo = false

    // MARK: 資料

    /// 從事件算出來的現況（每次記事件、收到別台的事件就更新）
    private(set) var state = StoreState()
    var syncStatus = SyncStatus()
    var reservations: [Reservation] = []
    /// 別台剛做的事（「A2 加點了 2 項」），畫面上閃一下
    var remoteActivity: String?

    // MARK: 這一刻

    var currentStaff: StaffMember?
    var section: AppSection = .order
    var selectedTicketId: String?
    /// 結帳中的單（工作區換成付款畫面）
    var checkoutTicketId: String?
    /// 點了有加料的品項：選甜度、冰塊的那張卡
    var modifierItem: MenuItem?
    var toast: Toast?
    var alert: AlertInfo?
    var lastActivity = Date()
    /// 剛結帳的那一筆（付款畫面上「上一筆」、找零）
    var lastSale: SaleRecord?
    var lastChange = Money.zero
    /// 交易明細要不要印（設定是「問客人」時）
    var receiptOffer: SaleRecord?
    /// 結帳時發票開不出來
    var pendingInvoiceFailure: InvoiceFailure?

    let keypad = KeypadController()
    let printers = PrinterHub()
    let mesh = MeshService()
    let settings = LocalSettings()

    // MARK: 內部

    private(set) var ledger: Ledger?
    private(set) var api: (any POSAPI)?
    private var engine: SyncEngine?
    private var timers: [Task<Void, Never>] = []

    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init() {}

    // MARK: - 開機

    func launch() {
        // 收銀台不睡覺；電量給後台「裝置」頁看
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            startDemo()
            return
        }
        guard let p = DeviceStore.loadPairing(), let token = DeviceStore.token else {
            phase = .pairing
            return
        }
        pairing = p
        let client = POSClient(cmsURL: p.cmsURL, token: token)
        if let cached = DeviceStore.loadBootstrap() { apply(cached) }
        do {
            try open(api: client, deviceId: p.deviceId)
        } catch {
            alert = AlertInfo(title: "打不開本機資料", message: error.localizedDescription)
            phase = .pairing
            return
        }
        phase = .locked
        Task { await refreshBootstrap() }
    }

    /// 打開日誌、接上同步
    private func open(api: any POSAPI, deviceId: String, journalDirectory: URL? = nil) throws {
        let journal = try EventJournal(directory: journalDirectory ?? DeviceStore.journalDirectory(deviceId: deviceId), deviceId: deviceId)
        let ledger = Ledger(journal: journal)
        self.ledger = ledger
        self.api = api
        state = ledger.state
        if !isDemo { _ = try? ledger.compact() }

        let engine = SyncEngine(api: api, ledger: ledger)
        self.engine = engine
        Task {
            _ = await engine.observe { [weak self] status, events in
                Task { @MainActor in self?.syncChanged(status, events) }
            }
            await engine.start(interval: isDemo ? 3600 : 15)
        }
        startTimers()
        if let mesh = meshConfig, mesh.enabled, let key = Crypto.bytes(hex: mesh.key) {
            self.mesh.start(deviceId: deviceId, key: key) { [weak self] events in
                self?.merge(events, source: "同一個 Wi-Fi")
            } summary: { [weak self] in
                self?.ledger?.journal.allEvents ?? []
            }
        }
    }

    private func startTimers() {
        timers.forEach { $0.cancel() }
        timers = [
            // 心跳：每分鐘（後台「裝置」頁看到在線、出單機狀態；後台有新的就拉）
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.heartbeat()
                    try? await Task.sleep(for: .seconds(60))
                }
            },
            // 設定：每 5 分鐘（菜單改價、新員工、新的發票號碼段）
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await self?.refreshBootstrap()
                }
            },
            // 閒置自動鎖定
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    self?.checkAutoLock()
                }
            },
        ]
    }

    func apply(_ b: Bootstrap) {
        configVersion = b.version
        device = b.device
        store = b.store
        features = b.features
        catalog = b.catalog
        floor = b.floor
        staff = b.staff.filter(\.isActive)
        invoiceSettings = b.invoice
        meshConfig = b.mesh
        if let current = currentStaff, let fresh = staff.first(where: { $0.id == current.id }) { currentStaff = fresh }
        if !visibleSections.contains(section) { section = visibleSections.first ?? .order }
    }

    func refreshBootstrap() async {
        guard let api else { return }
        do {
            let b = try await api.bootstrap(ifNoneMatch: configVersion)
            apply(b)
            if !isDemo { DeviceStore.save(b) }
        } catch APIError.notModified {
        } catch APIError.revoked {
            revoked()
        } catch {
            // 離線：用快取照常營業
        }
        await topUpInvoiceRolls()
    }

    private func heartbeat() async {
        guard let api, let ledger, !isDemo else { return }
        let h = Heartbeat(
            appVersion: Bundle.main.appVersion, outbox: ledger.journal.pendingCount, lastSeq: ledger.journal.cursor.lastSeq,
            printers: printers.health, battery: UIDevice.current.batteryLevel >= 0 ? Double(UIDevice.current.batteryLevel) : nil,
            openTickets: state.openTickets.count, staffId: currentStaff?.id
        )
        do {
            let r = try await api.heartbeat(h)
            if r.configVersion != configVersion { await refreshBootstrap() }
            if r.serverSeq > ledger.journal.cursor.pullCursor { await engine?.kick() }
        } catch APIError.revoked {
            revoked()
        } catch {}
    }

    private func syncChanged(_ status: SyncStatus, _ events: [POSEvent]) {
        syncStatus = status
        if !events.isEmpty {
            refreshState()
            describeRemote(events)
        }
        if status.health == .attention, status.lastError == APIError.revoked.userMessage { revoked() }
    }

    /// 收到別台的事件（後台或區網）
    func merge(_ events: [POSEvent], source: String) {
        guard let ledger else { return }
        do {
            let fresh = try ledger.merge(events)
            if !fresh.isEmpty {
                refreshState()
                describeRemote(fresh)
            }
        } catch {}
    }

    private func describeRemote(_ events: [POSEvent]) {
        let added = events.compactMap { e -> Int? in
            if case .linesAdded(let a) = e.body { return a.lines.reduce(0) { $0 + $1.quantity } }
            return nil
        }.reduce(0, +)
        if added > 0 { remoteActivity = "其他裝置加點了 \(added) 項" }
        let closed = events.filter { if case .ticketClosed = $0.body { true } else { false } }.count
        if closed > 0 { remoteActivity = "其他裝置結帳了 \(closed) 張單" }
    }

    func refreshState() {
        guard let ledger else { return }
        state = ledger.state
        if let id = selectedTicketId, state.tickets[id]?.isOpen != true { selectedTicketId = nil }
        if let id = checkoutTicketId, state.tickets[id]?.isOpen != true { checkoutTicketId = nil }
    }

    private func revoked() {
        let id = pairing?.deviceId
        reset()
        DeviceStore.forget(deviceId: id)
        alert = AlertInfo(title: "這台已經從後台移除", message: "本機的資料已經清掉。要再使用，請在後台「門市 POS → 裝置」產生新的配對碼。")
    }

    /// 回到配對畫面（解除配對、示範結束）
    func reset() {
        timers.forEach { $0.cancel() }
        timers = []
        mesh.stop()
        if let engine { Task { await engine.stop() } }
        engine = nil
        ledger = nil
        api = nil
        state = StoreState()
        currentStaff = nil
        selectedTicketId = nil
        checkoutTicketId = nil
        pairing = nil
        isDemo = false
        phase = .pairing
    }

    // MARK: - 配對

    /// 打 8 位數配對碼：先問 console 是哪一家店，再到那家店的後台配對
    func pair(code: String, cmsURL explicit: URL? = nil) async throws {
        let cmsURL: URL
        if let explicit {
            cmsURL = explicit
        } else {
            let r = try await POSClient.resolve(code: code, consoleURL: settings.consoleURL)
            guard let url = URL(string: r.cmsUrl) else { throw APIError.decoding("後台網址不對") }
            cmsURL = url
        }
        let info = DeviceInfo(name: UIDevice.current.name, model: UIDevice.current.modelIdentifier,
                              systemVersion: UIDevice.current.systemVersion, appVersion: Bundle.main.appVersion)
        let r = try await POSClient.pair(cmsURL: cmsURL, request: PairRequest(code: code, device: info))
        let p = DeviceStore.Pairing(cmsURL: cmsURL, deviceId: r.deviceId, deviceCode: r.deviceCode, role: r.role, storeName: r.storeName, pairedAt: Date())
        try DeviceStore.save(p, token: r.token)
        pairing = p
        let client = POSClient(cmsURL: cmsURL, token: r.token)
        let b = try await client.bootstrap(ifNoneMatch: nil)
        DeviceStore.save(b)
        apply(b)
        try open(api: client, deviceId: r.deviceId)
        phase = .locked
        await topUpInvoiceRolls()
    }

    /// 解除配對（店長）：清掉本機資料（還沒送出去的事件會先試著送）
    func unpair() async {
        await engine?.syncNow()
        let id = pairing?.deviceId
        reset()
        DeviceStore.forget(deviceId: id)
    }

    // MARK: - 示範

    /// 不用配對：虛構的「晨麥手作」，菜單、桌位、人員、今天的單都準備好了（資料只在這次開著的時候）
    func startDemo() {
        isDemo = true
        let demo = DemoStore()
        apply(demo.bootstrap)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pos-demo-\(UUID().uuidString)")
        do {
            try open(api: demo.api, deviceId: demo.bootstrap.device.id, journalDirectory: dir)
            if let ledger { try demo.seed(into: ledger) }
            refreshState()
            reservations = demo.reservations()
        } catch {
            alert = AlertInfo(title: "示範模式打不開", message: error.localizedDescription)
            return
        }
        phase = .locked
    }

    // MARK: - 登入、鎖定

    /// 打 PIN 登入（先點自己的名字；沒點就看 PIN 對到誰）
    func login(_ member: StaffMember) {
        currentStaff = member
        lastActivity = Date()
        if features.seating && device.role != .kitchen && section == .order && state.openTickets.contains(where: { !$0.tableIds.isEmpty }) {
            section = .floor
        }
        if device.role == .kitchen { section = .kitchen }
        if !visibleSections.contains(section) { section = visibleSections.first ?? .order }
        phase = .ready
    }

    func lock() {
        keypad.cancel()
        checkoutTicketId = nil
        currentStaff = nil
        phase = .locked
    }

    func touch() { lastActivity = Date() }

    private func checkAutoLock() {
        guard phase == .ready, settings.autoLockMinutes > 0, checkoutTicketId == nil, !keypad.isAsking else { return }
        if Date().timeIntervalSince(lastActivity) > Double(settings.autoLockMinutes * 60) { lock() }
    }

    /// 權限：自己可以就直接過；不行就請主管在右側鍵盤打 PIN（取消回 nil）
    func authorize(_ p: Permission, detail: String? = nil) async -> Authorization? {
        guard let me = currentStaff else { return nil }
        if me.can(p) { return .allowed }
        let candidates = staff.filter { $0.can(p) && $0.isActive }
        guard !candidates.isEmpty else {
            show("沒有人有「\(p.label)」的權限，請到後台設定", tone: .danger)
            return nil
        }
        var matched: StaffMember?
        let entry = await keypad.ask(
            .pin(title: "主管授權", subtitle: (detail.map { "\($0)・" } ?? "") + "\(p.label)要\(p.minimumRole.label)以上輸入 PIN"),
            clearsOnError: true
        ) { e in
            matched = candidates.first { $0.verify(pin: e.digits) }
            return matched == nil ? "PIN 不對，或沒有這個權限" : nil
        }
        guard entry != nil, let m = matched else { return nil }
        return .by(m)
    }

    // MARK: - 記事件

    /// 記一筆事件（寫進日誌、更新畫面、送出去）。失敗的話跳錯誤、回 false
    @discardableResult
    func record(_ bodies: [EventBody]) -> Bool {
        guard let ledger, !bodies.isEmpty else { return false }
        do {
            let events = try ledger.record(bodies, staffId: currentStaff?.id)
            refreshState()
            touch()
            mesh.broadcast(events)
            if let engine { Task { await engine.kick() } }
            return true
        } catch {
            alert = AlertInfo(title: "存不進這台 iPad", message: "\(error.localizedDescription)\n剛剛的動作沒有記下來，請再試一次；一直不行請重新開機。")
            return false
        }
    }

    @discardableResult
    func record(_ body: EventBody) -> Bool { record([body]) }

    func show(_ text: String, tone: Tone = .active) {
        toast = Toast(text: text, tone: tone)
    }

    // MARK: - 查詢

    var businessDate: String { TaipeiTime.businessDate(Date(), cutoffHour: store.businessDayCutoffHour) }

    var selectedTicket: Ticket? { selectedTicketId.flatMap { state.tickets[$0] }.flatMap { $0.isOpen ? $0 : nil } }
    var checkoutTicket: Ticket? { checkoutTicketId.flatMap { state.tickets[$0] } }
    var openShift: Shift? { state.openShift(on: device.id) }

    func staffName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return staff.first { $0.id == id }?.name ?? "—"
    }

    func staffMember(_ id: String?) -> StaffMember? { staff.first { $0.id == id } }

    func isAvailable(_ item: MenuItem) -> Bool { state.isAvailable(item) }

    var visibleSections: [AppSection] {
        switch device.role {
        case .kitchen: return [.kitchen, .orders, .settings]
        case .handheld:
            return [.order] + (features.seating ? [.floor] : []) + [.orders] + (features.reservations ? [.reservations] : []) + [.settings]
        case .register:
            var out: [AppSection] = [.order]
            if features.seating { out.append(.floor) }
            out.append(.orders)
            if features.reservations { out.append(.reservations) }
            if features.kitchen { out.append(.kitchen) }
            if currentStaff?.can(.viewReports) ?? true { out.append(.dashboard) }
            out += [.shift, .settings]
            return out
        }
    }

    /// 30 分鐘內有預約的桌子
    var reservedSoon: Set<String> {
        let now = Date()
        return Set(reservations.filter { $0.status.isActive && $0.kind == .reservation && $0.startsAt > now.addingTimeInterval(-15 * 60) && $0.startsAt < now.addingTimeInterval(30 * 60) }.flatMap(\.tableIds))
    }

    func tableStatus(_ tableId: String) -> TableStatus { state.status(of: tableId, reservedSoon: reservedSoon) }

    var invoicePeriod: InvoicePeriod { InvoicePeriod(date: Date()) }

    var allocator: InvoiceAllocator { InvoiceAllocator(rolls: invoiceSettings.rolls, state: state) }

    var invoiceNumbersLeft: Int { allocator.remaining(period: invoicePeriod) }

    // MARK: - 發票號碼段

    /// 剩不到 10 張、或下一期快開始（最後 3 天）就跟後台要一段
    func topUpInvoiceRolls() async {
        guard let api, features.invoice, invoiceSettings.enabled, device.role != .kitchen else { return }
        var periods = [invoicePeriod]
        if invoicePeriod.endsAt.timeIntervalSinceNow < 3 * 86_400 { periods.append(invoicePeriod.next) }
        for p in periods where allocator.needsMore(period: p) {
            do {
                let r = try await api.requestRoll(period: p.code, count: 50)
                if !invoiceSettings.rolls.contains(where: { $0.id == r.roll.id }) {
                    invoiceSettings.rolls.append(r.roll)
                }
            } catch {
                // 離線或後台沒有字軌：設定頁會顯示剩幾張
            }
        }
    }

    func newID() -> String { UUID().uuidString.lowercased() }
}

/// 存在這台的偏好（設定頁可以改）
@Observable
final class LocalSettings {
    private let d = UserDefaults.standard

    var appearance: String { didSet { d.set(appearance, forKey: "appearance") } }
    var autoLockMinutes: Int { didSet { d.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    /// 交易明細：always 每張都印、ask 問客人、never 不印
    var receiptMode: String { didSet { d.set(receiptMode, forKey: "receiptMode") } }
    var printKitchenTickets: Bool { didSet { d.set(printKitchenTickets, forKey: "printKitchenTickets") } }
    var consoleURLString: String { didSet { d.set(consoleURLString, forKey: "consoleURL") } }
    var openDrawerOnCash: Bool { didSet { d.set(openDrawerOnCash, forKey: "openDrawerOnCash") } }

    var consoleURL: URL { URL(string: consoleURLString) ?? URL(string: "https://console.studiox.tw")! }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    init() {
        appearance = d.string(forKey: "appearance") ?? "dark"
        autoLockMinutes = d.object(forKey: "autoLockMinutes") as? Int ?? 5
        receiptMode = d.string(forKey: "receiptMode") ?? "ask"
        printKitchenTickets = d.object(forKey: "printKitchenTickets") as? Bool ?? true
        consoleURLString = d.string(forKey: "consoleURL") ?? "https://console.studiox.tw"
        openDrawerOnCash = d.object(forKey: "openDrawerOnCash") as? Bool ?? true
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

extension UIDevice {
    /// iPad16,3
    var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
