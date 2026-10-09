import Foundation
import POSCore

// 外送平台的動作（docs/DELIVERY.md 的「iPad 用的 API」）：接單、拒單、出餐好了、忙碌、暫停。
// 外送的單本身從事件同步來；這裡是「現在就要平台知道」的事，所以要連線（斷線時 App 擋住按鈕並說明）。

public enum DeliveryAction: Sendable, Hashable {
    case accept(orderId: String, prepMinutes: Int)
    case reject(orderId: String, reason: DeliveryReason, message: String?)
    case ready(orderId: String)
    case cancel(orderId: String, reason: DeliveryReason, message: String?)
    /// 之後的單備餐時間多加幾分鐘（0＝取消）；minutes＝維持多久（沒給＝到手動取消）
    case busy(extraMinutes: Int, minutes: Int?)
    /// 暫停接單（platform 沒給＝全部；minutes 沒給＝到明天開店）
    case pause(platform: DeliveryPlatform?, minutes: Int?)
    case resume(platform: DeliveryPlatform?)
    /// 測試單（後台開了測試模式才行）
    case simulate(platform: DeliveryPlatform)

    /// POST /delivery/<path>
    public var path: String {
        switch self {
        case .accept(let id, _): "orders/\(id)/accept"
        case .reject(let id, _, _): "orders/\(id)/reject"
        case .ready(let id): "orders/\(id)/ready"
        case .cancel(let id, _, _): "orders/\(id)/cancel"
        case .busy: "busy"
        case .pause: "pause"
        case .resume: "resume"
        case .simulate: "simulate"
        }
    }

    public var body: DeliveryActionBody {
        switch self {
        case .accept(_, let m): DeliveryActionBody(prepMinutes: m)
        case .reject(_, let r, let msg), .cancel(_, let r, let msg): DeliveryActionBody(reason: r.rawValue, message: msg)
        case .ready: DeliveryActionBody()
        case .busy(let extra, let minutes): DeliveryActionBody(extraMinutes: extra, minutes: minutes)
        case .pause(let p, let minutes): DeliveryActionBody(minutes: minutes, platform: p?.rawValue)
        case .resume(let p): DeliveryActionBody(platform: p?.rawValue)
        case .simulate(let p): DeliveryActionBody(platform: p.rawValue)
        }
    }
}

public struct DeliveryActionBody: Codable, Sendable, Hashable {
    public var prepMinutes: Int?
    public var reason: String?
    public var message: String?
    public var extraMinutes: Int?
    public var minutes: Int?
    public var platform: String?

    public init(prepMinutes: Int? = nil, reason: String? = nil, message: String? = nil, extraMinutes: Int? = nil, minutes: Int? = nil, platform: String? = nil) {
        self.prepMinutes = prepMinutes; self.reason = reason; self.message = message
        self.extraMinutes = extraMinutes; self.minutes = minutes; self.platform = platform
    }
}

/// 動作的回應：接單回 readyAt、acceptedBy、mine（這台接的＝這台負責結帳、送廚房）；忙碌、暫停回各平台的狀態
public struct DeliveryActionResult: Codable, Sendable, Hashable {
    public var status: DeliveryStatus?
    public var readyAt: Date?
    public var acceptedBy: String?
    public var mine: Bool?
    public var platforms: [DeliveryPlatformState]?

    public init(status: DeliveryStatus? = nil, readyAt: Date? = nil, acceptedBy: String? = nil, mine: Bool? = nil, platforms: [DeliveryPlatformState]? = nil) {
        self.status = status; self.readyAt = readyAt; self.acceptedBy = acceptedBy; self.mine = mine; self.platforms = platforms
    }
}

/// GET /delivery
public struct DeliveryStateResponse: Codable, Sendable, Hashable {
    public var platforms: [DeliveryPlatformState]
    public init(platforms: [DeliveryPlatformState]) { self.platforms = platforms }
}

extension APIError {
    /// 另一台先接了（409 already_accepted）：照同步來的事件更新就好
    public static let alreadyAcceptedCode = "already_accepted"
    public static let deliveryUnsupported = "後台還不支援外送平台，請更新後台"

    public var isAlreadyAccepted: Bool {
        if case .http(409, Self.alreadyAcceptedCode, _) = self { return true }
        return false
    }
}

extension POSAPI {
    // 舊的假後台（測試）沒有外送：當作後台還不支援
    public func delivery() async throws -> DeliveryStateResponse {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.deliveryUnsupported)
    }

    public func delivery(_ action: DeliveryAction) async throws -> DeliveryActionResult {
        throw APIError.http(status: 404, code: "unsupported", message: APIError.deliveryUnsupported)
    }
}

extension POSClient {
    public func delivery() async throws -> DeliveryStateResponse {
        do {
            return try await call("delivery")
        } catch APIError.http(404, let code, _) {
            throw APIError.http(status: 404, code: code, message: APIError.deliveryUnsupported)
        }
    }

    public func delivery(_ action: DeliveryAction) async throws -> DeliveryActionResult {
        do {
            return try await call("delivery/\(action.path)", method: "POST", body: action.body)
        } catch APIError.http(404, let code, let message) where code != "not_found" {
            throw APIError.http(status: 404, code: code, message: message ?? APIError.deliveryUnsupported)
        }
    }
}
