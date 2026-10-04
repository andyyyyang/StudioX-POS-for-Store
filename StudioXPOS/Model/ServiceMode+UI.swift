import POSCore
import POSInvoice
import POSPrinting
import POSSync

extension ServiceMode {
    /// 側欄、設定裡的圖示（Heroicons）
    var icon: String {
        switch self {
        case .tableService: "table-cells"
        case .counter: "shopping-bag"
        case .retail: "tag"
        case .cafe: "cake"
        case .apparel: "swatch"
        case .salon: "scissors"
        case .fitness: "bolt"
        }
    }
}
