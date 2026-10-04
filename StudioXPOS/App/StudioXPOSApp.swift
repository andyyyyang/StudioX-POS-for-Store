import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI
import UIKit

@main
struct StudioXPOSApp: App {
    @State private var model = POSModel()

    init() {
        BrandFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.keypad)
                .environment(model.printers)
                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
                .tint(Theme.primary)
                .preferredColorScheme(model.settings.colorScheme)
                // 收銀台滿版：不要系統的時間列（時間在側欄、鎖定畫面）；iPadOS 的視窗模式下系統還是會顯示，畫面的底色照樣延伸到最上緣。
                // iPhone（店員手上的點餐機）照常顯示時間列、電量
                .statusBarHidden(!model.isPhone)
                .onOpenURL { model.handle($0) }
        }
        .commands {
            // 外接鍵盤：⌘1–⌘9 照側欄的順序切換（只算這台看得到的頁）、⌘L 鎖定
            CommandMenu("前往") {
                ForEach(Array(model.visibleSections.prefix(9).enumerated()), id: \.element) { i, s in
                    Button(s.label) { model.go(s) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                        .disabled(model.phase != .ready)
                }
                Divider()
                Button("鎖定") { model.lock() }
                    .keyboardShortcut("l")
                    .disabled(model.phase != .ready)
            }
        }
    }
}

extension POSModel {
    func go(_ s: AppSection) {
        guard visibleSections.contains(s) else { return }
        keypad.cancel()
        if s != .order { checkoutTicketId = nil }
        section = s
        touch()
    }

    /// 後台「裝置」頁的 QR Code：studiox-pos://pair?cms=https://…&code=12345678
    func handle(_ url: URL) {
        guard url.scheme == "studiox-pos", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { return }
        let cms = items.first(where: { $0.name == "cms" })?.value.flatMap(URL.init(string:))
        guard phase == .pairing else {
            show("這台已經配對過了；要換店家請先在設定裡解除配對", tone: .warning)
            return
        }
        Task {
            do {
                try await pair(code: code, cmsURL: cms)
            } catch let e as APIError {
                alert = AlertInfo(title: "配對失敗", message: e.userMessage)
            } catch {
                alert = AlertInfo(title: "配對失敗", message: error.localizedDescription)
            }
        }
    }
}

/// 開機 → 配對 → 鎖定（PIN）→ 收銀台
struct RootView: View {
    @Environment(POSModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// 個人的裝置離開一陣子、回來時剛鎖起來：鎖定畫面直接跳出 Face ID
    @State private var promptUnlock = false

    var body: some View {
        ZStack {
            Theme.page.ignoresSafeArea()
            switch model.phase {
            case .launching:
                LaunchView()
                    .transition(.opacity)
            case .pairing:
                PairingView()
                    .transition(.opacity)
            case .locked:
                lockScreen
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
            case .ready:
                // iPhone：上面選、下面做（PhoneShell）；iPad：四欄的收銀台
                if model.isPhone {
                    PhoneShell()
                        .transition(.opacity)
                } else {
                    MainShell()
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.inOut, value: model.phase)
        // 手機的提示在上面（下面是分頁與動作）；收銀台的畫面裡由 PhoneShell 自己放（才不會被單子的 sheet 蓋住）
        .overlay(alignment: model.isPhone ? .top : .bottom) {
            if !(model.isPhone && model.phase == .ready) {
                ToastHost(edge: model.isPhone ? .top : .bottom)
            }
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), presenting: model.alert) { _ in
            Button("知道了", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        .task {
            if model.phase == .launching { model.launch() }
            model.requestLandscapeIfAsked()
            // 手機在店員口袋裡：照系統的設定自動關螢幕（收銀台的 iPad 不睡）
            if model.isPhone { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .onChange(of: model.phase) { _, p in
            // 截圖、自動測試：鎖定畫面一出現就照參數登入、開頁
            if p == .locked { model.applyLaunchArguments() }
            if p == .ready { promptUnlock = false }
        }
        .onChange(of: scenePhase) { _, p in
            // 個人的裝置離開太久就鎖起來（POSModel+Personal）；其他照舊算一次「有人在用」
            if p == .active { promptUnlock = model.returnedToForeground() }
        }
    }

    /// 鎖定畫面：店裡共用的打 PIN；個人的裝置（用 StudioX 帳號登入）用 Face ID／手機密碼；
    /// 綁著的那位被停用了（401 staff_inactive）是「請找店長」＋重試（資料不清）
    @ViewBuilder
    private var lockScreen: some View {
        if model.isPersonalDevice && model.staffBlocked {
            PersonalBlockedView()
        } else if model.isPersonalDevice {
            PersonalLockView(promptOnAppear: promptUnlock)
        } else {
            LockView()
        }
    }
}

/// 開機的那一下：標誌
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            BrandMark()
                .frame(width: 56, height: 56)
                .foregroundStyle(Theme.ink)
            Text("StudioX POS")
                .textRole(.h4)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// 畫面下方（手機是上方）的一句話，2.6 秒後收起來
struct ToastHost: View {
    @Environment(POSModel.self) private var model
    var edge: VerticalEdge = .bottom

    var body: some View {
        ZStack {
            if let t = model.toast {
                HStack(spacing: 10) {
                    Circle().fill(t.tone.dot).frame(width: 8, height: 8)
                    Text(t.text)
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(Theme.onInverse)
                        .lineLimit(2)
                    if let a = t.action {
                        // 「復原」：按了就做、提示收起來
                        Button {
                            a.perform()
                            withAnimation(Motion.ease) { model.toast = nil }
                        } label: {
                            Text(a.title)
                                .font(.brand(15.5, .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.leading, 6)
                                .frame(minHeight: 32)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Theme.inverse, in: .capsule)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .padding(edge == .bottom ? .bottom : .top, edge == .bottom ? 28 : 8)
                .padding(.horizontal, edge == .top ? 16 : 0)
                .transition(.move(edge: edge == .bottom ? .bottom : .top).combined(with: .opacity))
                .id(t.id)
                .task(id: t.id) {
                    // 有「復原」的久一點，來得及按
                    try? await Task.sleep(for: .seconds(t.action == nil ? 2.6 : 4.5))
                    withAnimation(Motion.ease) { if model.toast?.id == t.id { model.toast = nil } }
                }
                .onTapGesture { model.toast = nil }
            }
        }
        .animation(Motion.spring, value: model.toast)
        .allowsHitTesting(model.toast != nil)
    }
}
