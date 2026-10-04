import Foundation
import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 鎖定畫面：點自己的名字、在右側鍵盤打 PIN。也在這裡上下班打卡。
///
/// 按鈕照 docs/DESIGN.md：只有人員名單（點了選起來）、「登入／打卡」分段控制、右側鍵盤；沒有別的按鈕。
///
///   ┌──────────────┬────────────────────────┬──────────┐
///   │ 班表          │        14:05           │  輸入 PIN │
///   │ (L) Leslie K. │    10月3日 星期六         │  ● ● ○ ○ │
///   │ (C) Cameron W.│   晨麥手作・櫃台 1        │  1  2  3 │
///   │ (J) Jacob J.  │                        │   …      │
///   └──────────────┴────────────────────────┴──────────┘
///
/// 手機（寬度 compact）：上面是店名、時間、「登入／打卡」與一排人員，下面是整個寬度的 PIN 鍵盤
struct LockView: View {
    enum Mode: String, CaseIterable { case login, clock }

    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @State private var selected: StaffMember?
    @State private var mode: Mode = .login
    /// 錯太多次：鎖 30 秒（PIN 只有 4–6 碼）
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                compact
            } else {
                HStack(spacing: 0) {
                    roster
                        .frame(width: 300)
                    Rule(vertical: true)
                    hero
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    KeypadDock(showsCancel: false)
                        .frame(width: Metric.dock)
                }
            }
        }
        .background(Theme.page.ignoresSafeArea())
        .task(id: "\(selected?.id ?? "-")-\(mode.rawValue)") { await askPIN() }
    }

    // MARK: 手機：上面選人、下面打 PIN

    /// 鍵盤要的高度（題目、大字、四排鍵、確認鍵）；上面放店名、登入／打卡、一排人員
    private static let compactKeypadHeight: CGFloat = 572

    private var compact: some View {
        GeometryReader { geo in
            if geo.size.height >= 175 + Self.compactKeypadHeight {
                VStack(spacing: 0) {
                    compactHeader
                    compactRoster
                    KeypadDock(showsCancel: false)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .top) { Rule() }
                }
            } else {
                // 矮的手機（SE、mini）：整頁可以捲，鍵盤照樣是全寬、一樣大
                ScrollView {
                    VStack(spacing: 0) {
                        compactHeader
                        compactRoster
                        KeypadDock(showsCancel: false)
                            .frame(height: Self.compactKeypadHeight)
                            .overlay(alignment: .top) { Rule() }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// 店名・這支手機｜時間；登入／打卡（題目與「錯太多次」寫在鍵盤上）
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(model.store.name)
                    Text(model.device.name.isEmpty ? model.role.label : "\(model.device.name)・\(model.role.label)")
                        .textRole(.xs)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(TaipeiTime.clock(ctx.date))
                        .font(.brand(26, .medium))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
            }
            Picker("", selection: $mode) {
                Text("登入").tag(Mode.login)
                Text("打卡").tag(Mode.clock)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("登入或上下班打卡")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 一排人員（左右滑）：點了選起來、再點一下取消
    private var compactRoster: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.staff) { s in
                        let on = selected?.id == s.id
                        let clocked = model.isClockedIn(s)
                        Button {
                            withAnimation(Motion.fast) { selected = on ? nil : s }
                        } label: {
                            HStack(spacing: 8) {
                                StaffAvatar(name: s.name, swatch: s.swatch, size: 30)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(s.name)
                                        .font(.brand(14.5, .medium))
                                        .foregroundStyle(on ? Theme.page : Theme.ink)
                                        .lineLimit(1)
                                    Text((s.title ?? s.role.label) + (clocked ? "・上班中" : ""))
                                        .font(.brand(11.5, .regular))
                                        .foregroundStyle(on ? Theme.page.opacity(0.7) : Theme.muted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.leading, 7)
                            .padding(.trailing, 14)
                            .frame(height: 48)
                            .background(on ? Theme.ink : Theme.surface, in: .capsule)
                            .overlay { Capsule().strokeBorder(on ? Color.clear : Theme.line) }
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            if model.isDemo {
                // 示範的 PIN：一行，左右滑
                ScrollView(.horizontal) {
                    Text("示範的 PIN：\(DemoStore.kind.pinHint)")
                        .font(.brand(11.5, .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 班表

    private var roster: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(model.store.name)
                Headline("On *shift*", role: .h3)
            }
            .padding(24)

            Picker("", selection: $mode) {
                Text("登入").tag(Mode.login)
                Text("打卡").tag(Mode.clock)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("登入或上下班打卡")
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.staff) { s in
                        Button {
                            withAnimation(Motion.fast) { selected = selected?.id == s.id ? nil : s }
                        } label: {
                            row(s)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            if model.isDemo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("示範的 PIN")
                        .font(.brand(12, .semibold))
                        .foregroundStyle(Theme.xenaIrisLavender)
                    Text(DemoStore.kind.pinHint)
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .background(Theme.pageAlt.opacity(0.5))
    }

    private func row(_ s: StaffMember) -> some View {
        let on = selected?.id == s.id
        let clocked = model.isClockedIn(s)
        return HStack(spacing: 12) {
            StaffAvatar(name: s.name, swatch: s.swatch, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.brand(16, .medium))
                    .foregroundStyle(on ? Theme.page : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // 職稱（設計師、教練）沒有就寫權限（店長、收銀）；上班中是狀態，不是按鈕
                Text((s.title ?? s.role.label) + (clocked ? "・上班中" : ""))
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(on ? Theme.page.opacity(0.7) : Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer()
            if clocked {
                Circle().fill(Theme.live).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(on ? Theme.ink : Theme.surface, in: .rect(cornerRadius: Metric.radiusLg))
        .overlay { RoundedRectangle(cornerRadius: Metric.radiusLg).strokeBorder(on ? Color.clear : Theme.line) }
        .contentShape(.rect)
    }

    // MARK: 中間

    private var hero: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 14) {
                Spacer()
                Text(TaipeiTime.clock(ctx.date))
                    .font(.brand(120, .medium))
                    .tracking(-6)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(ctx.date.dayTitle)
                    .textRole(.lead)
                    .foregroundStyle(Theme.ink2)
                HStack(spacing: 8) {
                    Text(model.store.name)
                    Text("・")
                    Text(model.device.name.isEmpty ? model.role.label : "\(model.device.name)・\(model.role.label)")
                }
                .textRole(.small)
                .foregroundStyle(Theme.muted)
                Spacer()
                Text(prompt)
                    .textRole(.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 36)
            }
        }
    }

    private var prompt: String {
        if let until = lockedUntil, until > Date() { return "錯太多次，請稍等一下再試" }
        switch mode {
        case .login: return selected.map { "\($0.name)，請在右邊輸入 PIN" } ?? "點自己的名字，或直接輸入 PIN"
        case .clock: return selected.map { "\($0.name)，輸入 PIN \(model.isClockedIn($0) ? "下班" : "上班")" } ?? "點自己的名字，輸入 PIN 打卡"
        }
    }

    // MARK: PIN

    private func askPIN() async {
        while !Task.isCancelled && model.phase == .locked {
            let candidates = selected.map { [$0] } ?? model.staff
            var matched: StaffMember?
            let title = mode == .login ? "輸入 PIN" : "打卡"
            let subtitle = selected?.name ?? (mode == .login ? model.store.name : "選自己的名字")
            let entry = await keypad.ask(.pin(title: title, subtitle: subtitle), clearsOnError: true) { e in
                if let until = lockedUntil, until > Date() { return "錯太多次，請 \(Int(until.timeIntervalSinceNow) + 1) 秒後再試" }
                let hits = candidates.filter { $0.verify(pin: e.digits) }
                if hits.count == 1 {
                    matched = hits[0]
                    return nil
                }
                failures += 1
                if failures >= 5 {
                    failures = 0
                    lockedUntil = Date().addingTimeInterval(30)
                    return "錯太多次，30 秒後再試"
                }
                return hits.count > 1 ? "這個 PIN 有兩個人用，請先點自己的名字" : "PIN 不對"
            }
            if Task.isCancelled { return }
            guard entry != nil, let who = matched else { continue }
            failures = 0
            switch mode {
            case .login:
                if !model.isClockedIn(who) {
                    model.currentStaff = who
                    model.toggleClock(who)
                }
                model.login(who)
                return
            case .clock:
                let previous = model.currentStaff
                model.currentStaff = who
                model.toggleClock(who)
                model.currentStaff = previous
                if selected != nil {
                    selected = nil
                    return
                }
            }
        }
    }
}
