import SwiftUI

// 暫時的：桌位、訂位、廚房、訂單、報表、交班、設定這幾頁還在寫，先放空的頁面讓 App 編得過。
// 那幾頁完成時刪掉這個檔案。
struct FloorView: View { var body: some View { EmptyState(icon: "table-cells", title: "桌位（製作中）") } }
struct OrdersView: View { var body: some View { EmptyState(icon: "queue-list", title: "訂單（製作中）") } }
struct ReservationsView: View { var body: some View { EmptyState(icon: "calendar-days", title: "訂位（製作中）") } }
struct KitchenView: View { var body: some View { EmptyState(icon: "fire", title: "廚房（製作中）") } }
struct DashboardView: View { var body: some View { EmptyState(icon: "chart-bar", title: "報表（製作中）") } }
struct ShiftView: View { var body: some View { EmptyState(icon: "banknotes", title: "交班（製作中）") } }
struct SettingsView: View { var body: some View { EmptyState(icon: "cog-6-tooth", title: "設定（製作中）") } }
