import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 右欄最上面固定的一塊（只在收銀台的右欄，鎖定、配對、手機的鍵盤不放）：
/// 全外帶的店（叫號 usage 有 takeout）在這裡放叫號——現在叫到幾號、下一號、叫號鍵。沒有要放的就是空的。
struct DockPinned: View {
    var body: some View {
        EmptyView()
    }
}
