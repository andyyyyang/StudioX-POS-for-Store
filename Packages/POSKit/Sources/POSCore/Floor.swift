import Foundation

// 桌位：區域（1F、2F、戶外）裡的桌子。座標用 0–100 的格子（和畫面大小無關），iPad 上可以拖拉排列。

public enum TableShape: String, Codable, Sendable, CaseIterable, Hashable {
    case square, round, rect, booth, bar
}

public struct DiningTable: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var areaId: String
    /// 桌號（A1、12、吧台3）
    public var name: String
    public var seats: Int
    public var shape: TableShape
    /// 左上角（0–100 的格子）
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var rotation: Double

    public init(id: String, areaId: String, name: String, seats: Int = 4, shape: TableShape = .square,
                x: Double = 0, y: Double = 0, width: Double = 12, height: Double = 12, rotation: Double = 0) {
        self.id = id; self.areaId = areaId; self.name = name; self.seats = seats; self.shape = shape
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
    }
}

public struct FloorArea: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var sortOrder: Int
    public var tables: [DiningTable]

    public init(id: String, name: String, sortOrder: Int = 0, tables: [DiningTable] = []) {
        self.id = id; self.name = name; self.sortOrder = sortOrder; self.tables = tables
    }
}

public struct FloorPlan: Codable, Sendable, Hashable {
    public var areas: [FloorArea]

    public init(areas: [FloorArea] = []) { self.areas = areas.sorted { $0.sortOrder < $1.sortOrder } }

    public static let empty = FloorPlan()

    public var allTables: [DiningTable] { areas.flatMap(\.tables) }
    public func table(_ id: String) -> DiningTable? { allTables.first { $0.id == id } }
    public func tableNames(_ ids: [String]) -> String {
        ids.compactMap { table($0)?.name }.joined(separator: "+")
    }
}

/// 桌子現在的狀態（從事件算出來，不存）
public enum TableStatus: String, Codable, Sendable, Hashable {
    /// 空桌
    case available
    /// 有預約、快到了（30 分鐘內）
    case reserved
    /// 帶位了、還沒點
    case seated
    /// 點了、出餐中
    case ordering
    /// 要買單了（印了結帳單）
    case billing
    /// 結完帳、還沒清桌
    case needsCleaning

    public var label: String {
        switch self {
        case .available: "空桌"
        case .reserved: "已預約"
        case .seated: "已入座"
        case .ordering: "用餐中"
        case .billing: "待結帳"
        case .needsCleaning: "待清桌"
        }
    }
}
