import CoreBluetooth
import Foundation
import Observation
import POSCore
import POSInvoice
import POSPrinting
import POSSync

/// 藍牙出單機（BLE）：台灣小店常見的 58／80 mm 藍牙熱感機。
///
/// 這類機器都是「藍牙版的 ESC/POS」：有一個可以寫入的特徵值（characteristic），把 ESC/POS 的位元組切成小塊寫進去就印。
/// 不同廠牌的服務 UUID 不一樣，所以連上之後把每個服務都找一遍，挑可以寫的那一個（常見的優先）。
/// 只支援 BLE：傳統藍牙（SPP）的機器 iPad 沒辦法直接連（要 Apple 的 MFi 認證），買機器時請選「支援 BLE」的。
nonisolated struct BLEPrinterInfo: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var rssi: Int

    /// 訊號強度 0–3 格
    var bars: Int {
        switch rssi {
        case (-60)...: 3
        case (-75)...: 2
        case (-90)...: 1
        default: 0
        }
    }
}

/// 給畫面用的：附近的藍牙出單機、掃描中、藍牙的狀態
@Observable
final class BluetoothPrinters {
    static let shared = BluetoothPrinters()

    private(set) var found: [BLEPrinterInfo] = []
    private(set) var scanning = false
    /// 藍牙關著、沒有權限…（nil＝正常）
    private(set) var problem: String?

    @ObservationIgnored private lazy var link: BLELink = {
        let l = BLELink()
        l.onDiscover = { info in
            Task { @MainActor in BluetoothPrinters.shared.add(info) }
        }
        l.onState = { problem in
            Task { @MainActor in BluetoothPrinters.shared.problem = problem }
        }
        return l
    }()

    /// 第一次會跳出系統的藍牙權限詢問
    func startScan() {
        found = []
        scanning = true
        link.startScan()
        // 掃 20 秒就停（省電）
        Task {
            try? await Task.sleep(for: .seconds(20))
            if scanning { stopScan() }
        }
    }

    func stopScan() {
        scanning = false
        link.stopScan()
    }

    /// 送一串 ESC/POS 到這台（沒連上會先連；連上之後保持連線，下一張印得比較快）
    func send(_ bytes: [UInt8], to id: String) async throws {
        try await link.send(bytes, to: id)
    }

    private func add(_ info: BLEPrinterInfo) {
        if let i = found.firstIndex(where: { $0.id == info.id }) {
            found[i] = info
        } else {
            found.append(info)
            found.sort { $0.rssi > $1.rssi }
        }
    }
}

nonisolated enum BLEError: LocalizedError {
    case off(String)
    case notFound
    case timeout
    case notPrinter
    case disconnected

    var errorDescription: String? {
        switch self {
        case .off(let m): m
        case .notFound: "找不到這台藍牙出單機（電源開著嗎？離 iPad 太遠？）"
        case .timeout: "藍牙出單機沒有回應"
        case .notPrinter: "這個藍牙裝置不能列印（找不到可以寫入的通道）"
        case .disconnected: "藍牙出單機斷線了"
        }
    }
}

/// CoreBluetooth 的工作都在自己的佇列上做（回呼也在這個佇列），一次印一張
nonisolated final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    var onDiscover: (@Sendable (BLEPrinterInfo) -> Void)?
    var onState: (@Sendable (String?) -> Void)?

    private let queue = DispatchQueue(label: "tw.studiox.pos.ble")
    private var central: CBCentralManager?
    private var wantScan = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var targets: [UUID: (CBCharacteristic, CBCharacteristicWriteType)] = [:]
    private var servicesLeft: [UUID: Int] = [:]

    private struct Job {
        let id: UUID
        var bytes: [UInt8]
        var offset = 0
        let continuation: CheckedContinuation<Void, Error>
        let serial: Int
    }

    private var jobs: [Job] = []
    private var current: Job?
    private var serial = 0

    /// 常見的藍牙出單機寫入通道（找到這些優先，其次是任何可以寫入的）
    private static let preferred: [CBUUID] = [
        CBUUID(string: "2AF1"),                                     // 很多 58 mm 機器：服務 18F0
        CBUUID(string: "FF02"), CBUUID(string: "FFE1"), CBUUID(string: "FFF2"),
        CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"),     // Microchip（ISSC）透通
        CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    func startScan() {
        queue.async {
            self.wantScan = true
            self.ensureCentral()
            if self.central?.state == .poweredOn {
                self.central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        }
    }

    func stopScan() {
        queue.async {
            self.wantScan = false
            self.central?.stopScan()
        }
    }

    func send(_ bytes: [UInt8], to id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { throw BLEError.notFound }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                self.serial += 1
                self.jobs.append(Job(id: uuid, bytes: bytes, continuation: c, serial: self.serial))
                self.ensureCentral()
                self.pump()
            }
        }
    }

    // MARK: 一張一張印（都在 queue 上）

    private func pump() {
        guard current == nil, !jobs.isEmpty, let central else { return }
        switch central.state {
        case .unknown, .resetting:
            return // 等 centralManagerDidUpdateState
        case .poweredOn:
            break
        default:
            let message = Self.stateMessage(central.state) ?? "藍牙不能用"
            let waiting = jobs
            jobs = []
            for j in waiting { j.continuation.resume(throwing: BLEError.off(message)) }
            return
        }
        var job = jobs.removeFirst()
        guard let p = peripherals[job.id] ?? central.retrievePeripherals(withIdentifiers: [job.id]).first else {
            job.continuation.resume(throwing: BLEError.notFound)
            pump()
            return
        }
        peripherals[job.id] = p
        p.delegate = self
        job.offset = 0
        current = job
        let s = job.serial
        // 10 秒還沒印完就算失敗（機器沒開、太遠）
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let cur = self.current, cur.serial == s else { return }
            self.finish(error: BLEError.timeout)
        }
        if p.state == .connected, targets[job.id] != nil {
            write()
        } else if p.state == .connected {
            p.discoverServices(nil)
        } else {
            central.connect(p, options: nil)
        }
    }

    private func finish(error: Error?) {
        guard let job = current else { return }
        current = nil
        if let error {
            job.continuation.resume(throwing: error)
        } else {
            job.continuation.resume()
        }
        pump()
    }

    /// 切成小塊寫：不用回應的寫法照機器說「可以再送」的節奏送；要回應的寫法一塊等一個回應
    private func write() {
        guard var job = current, let p = peripherals[job.id], let (ch, type) = targets[job.id] else { return }
        let chunk = max(20, min(p.maximumWriteValueLength(for: type), 180))
        if type == .withoutResponse {
            while job.offset < job.bytes.count && p.canSendWriteWithoutResponse {
                let end = min(job.offset + chunk, job.bytes.count)
                p.writeValue(Data(job.bytes[job.offset..<end]), for: ch, type: .withoutResponse)
                job.offset = end
            }
            current = job
            if job.offset >= job.bytes.count {
                // 給出單機一點時間把緩衝區印完再換下一張
                let s = job.serial
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.current?.serial == s else { return }
                    self.finish(error: nil)
                }
            }
        } else {
            guard job.offset < job.bytes.count else {
                finish(error: nil)
                return
            }
            let end = min(job.offset + chunk, job.bytes.count)
            p.writeValue(Data(job.bytes[job.offset..<end]), for: ch, type: .withResponse)
            job.offset = end
            current = job
        }
    }

    private static func stateMessage(_ s: CBManagerState) -> String? {
        switch s {
        case .poweredOff: "藍牙關著：到「設定」或控制中心打開藍牙"
        case .unauthorized: "沒有藍牙權限：到「設定 → StudioX POS」打開藍牙"
        case .unsupported: "這台 iPad 不支援藍牙出單機"
        default: nil
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onState?(Self.stateMessage(central.state))
        if central.state == .poweredOn, wantScan {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        pump()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // 沒有名字的（耳機、手錶的廣播）不列；出單機都有名字
        guard let name, !name.isEmpty else { return }
        peripherals[peripheral.identifier] = peripheral
        onDiscover?(BLEPrinterInfo(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if current?.id == peripheral.identifier { finish(error: error ?? BLEError.notFound) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        targets[peripheral.identifier] = nil
        if current?.id == peripheral.identifier { finish(error: BLEError.disconnected) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            if current?.id == peripheral.identifier { finish(error: BLEError.notPrinter) }
            return
        }
        servicesLeft[peripheral.identifier] = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        servicesLeft[id, default: 1] -= 1
        for ch in service.characteristics ?? [] {
            let canNoResponse = ch.properties.contains(.writeWithoutResponse)
            let canWrite = ch.properties.contains(.write)
            guard canNoResponse || canWrite else { continue }
            let type: CBCharacteristicWriteType = canNoResponse ? .withoutResponse : .withResponse
            let isPreferred = Self.preferred.contains(ch.uuid)
            // 第一個可以寫的先記著；之後找到常見的出單機通道就換成它
            if targets[id] == nil || (isPreferred && !Self.preferred.contains(targets[id]!.0.uuid)) {
                targets[id] = (ch, type)
            }
        }
        if servicesLeft[id, default: 0] <= 0, current?.id == id {
            if targets[id] != nil { write() } else { finish(error: BLEError.notPrinter) }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if current?.id == peripheral.identifier { write() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard current?.id == peripheral.identifier else { return }
        if let error {
            finish(error: error)
        } else {
            write()
        }
    }
}
