import SwiftUI

// 暫時的：預約表、報到、會員三頁還在寫，先放空的頁面讓 App 編得過。寫好的那一頁把這裡對應的一行刪掉。
struct AppointmentsView: View { var body: some View { EmptyState(icon: "calendar", title: "預約（製作中）") } }
struct CheckInView: View { var body: some View { EmptyState(icon: "qr-code", title: "報到（製作中）") } }
struct MembersView: View { var body: some View { EmptyState(icon: "user-group", title: "會員（製作中）") } }
