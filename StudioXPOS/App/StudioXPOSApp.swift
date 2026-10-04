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
                .onOpenURL { model.handle($0) }
        }
        .commands {
            // 外接鍵盤：⌘1–⌘8 切換、⌘L 鎖定
            CommandMenu("前往") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.label) { model.go(s) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                        .disabled(!model.visibleSections.contains(s) || model.phase != .ready)
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
                LockView()
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
            case .ready:
                MainShell()
                    .transition(.opacity)
            }
        }
        .animation(Motion.inOut, value: model.phase)
        .overlay(alignment: .bottom) { ToastHost() }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), presenting: model.alert) { _ in
            Button("知道了", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        .task { if model.phase == .launching { model.launch() } }
        .onChange(of: scenePhase) { _, p in
            if p == .active { model.touch() }
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

/// 畫面下方的一句話，2.6 秒後收起來
struct ToastHost: View {
    @Environment(POSModel.self) private var model

    var body: some View {
        ZStack {
            if let t = model.toast {
                HStack(spacing: 10) {
                    Circle().fill(t.tone.dot).frame(width: 8, height: 8)
                    Text(t.text)
                        .font(.brand(15.5, .medium))
                        .foregroundStyle(Theme.onInverse)
                        .lineLimit(2)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Theme.inverse, in: .capsule)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation(Motion.ease) { if model.toast?.id == t.id { model.toast = nil } }
                }
                .onTapGesture { model.toast = nil }
            }
        }
        .animation(Motion.spring, value: model.toast)
        .allowsHitTesting(model.toast != nil)
    }
}
