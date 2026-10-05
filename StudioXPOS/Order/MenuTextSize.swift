import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 菜單卡片的字多大（每台自己選：iPad 設定 → 外觀與安全、菜單上面的「Aa」；手機 更多 → 這支手機）。
/// 字大了卡片跟著變寬變高（一排放少一點），名字才不會被切掉；選好了大小就固定，點來點去不會變
enum MenuTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "小"
        case .standard: "標準"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }

    /// 字放大幾倍（以「小」為準：品名 16、價錢 15）
    var scale: CGFloat {
        switch self {
        case .small: 1
        case .standard: 1.15
        case .large: 1.32
        case .extraLarge: 1.52
        }
    }

    /// 卡片的寬、高跟著放大多少（比字少一點：字大一級，一排不會少掉太多）
    var space: CGFloat { 1 + (scale - 1) * 0.8 }

    /// 卡片角上「點了幾份」的圓：跟著大一點（不像字放那麼多）
    var badge: CGFloat { 24 * (1 + (scale - 1) * 0.5) }

    /// 卡片上的字（大小以「小」為準）
    func font(_ size: CGFloat, _ face: Face = .medium) -> Font {
        .brand(size * scale, face)
    }
}

extension EnvironmentValues {
    /// 菜單卡片的字級（MenuView、PhoneOrderView 放進來，卡片讀）
    @Entry var menuText: MenuTextSize = .standard
}

extension LocalSettings {
    var menuText: MenuTextSize {
        get { MenuTextSize(rawValue: menuTextSize) ?? .standard }
        set { menuTextSize = newValue.rawValue }
    }
}

/// 選菜單的字級：四個大小的「Aa」並排（設定頁、手機的更多）
struct MenuTextSizePicker: View {
    @Environment(POSModel.self) private var model
    var height: CGFloat = 64

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MenuTextSize.allCases) { size in
                Button {
                    model.settings.menuText = size
                } label: {
                    VStack(spacing: 4) {
                        Text("Aa")
                            .font(.brand(14 * size.scale, .semibold))
                            .frame(height: 26)
                        Text(size.label)
                    }
                }
                .buttonStyle(.choice(model.settings.menuText == size, height: height))
                .accessibilityLabel("菜單的字 \(size.label)")
                .accessibilityAddTraits(model.settings.menuText == size ? .isSelected : [])
            }
        }
    }
}

/// iPad 菜單上面的「Aa」：點開選字級
struct MenuTextSizeMenu: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        Menu {
            Picker("菜單的字", selection: Binding(get: { model.settings.menuText }, set: { model.settings.menuText = $0 })) {
                ForEach(MenuTextSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
        } label: {
            Text("Aa")
                .font(.brand(16, .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: .rect(cornerRadius: Metric.radius))
                .overlay { RoundedRectangle(cornerRadius: Metric.radius).strokeBorder(Theme.line) }
                .contentShape(.rect)
        }
        .accessibilityLabel("菜單的字：\(model.settings.menuText.label)")
    }
}
