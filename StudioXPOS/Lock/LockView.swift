import POSCore
import POSInvoice
import POSPrinting
import POSSync
import SwiftUI

/// 鎖定畫面：點自己的名字、在右側鍵盤打 PIN。也在這裡上下班打卡。
///
///   ┌──────────────┬────────────────────────┬──────────┐
///   │ 班表          │        14:05           │  輸入 PIN │
///   │ (L) Leslie K. │    10月3日 星期六         │  ● ● ○ ○ │
///   │ (C) Cameron W.│   晨麥手作・櫃台 1        │  1  2  3 │
///   │ (J) Jacob J.  │                        │   …      │
///   └──────────────┴────────────────────────┴──────────┘
struct LockView: View {
    enum Mode: String, CaseIterable { case login, clock }

    @Environment(POSModel.self) private var model
    @Environment(KeypadController.self) private var keypad
    @State private var selected: StaffMember?
    @State private var mode: Mode = .login
    /// 錯太多次：鎖 30 秒（PIN 只有 4–6 碼）
    @State private var failures = 0
    @State private var lockedUntil: Date?

    var body: some View {
        HStack(spacing: 0) {
            roster
                .frame(width: 300)
            Rule(vertical: true)
            hero
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            KeypadDock()
                .frame(width: Metric.dock)
        }
        .background(Theme.page.ignoresSafeArea())
        .task(id: "\(selected?.id ?? "-")-\(mode.rawValue)") { await askPIN() }
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
                Text("上下班打卡").tag(Mode.clock)
            }
            .pickerStyle(.segmented)
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
                    Text("Leslie 1234・Cameron 2580・Jacob 1111・王小美 0000")
                        .font(.brand(12, .regular))
                        .foregroundStyle(Theme.muted)
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
                Text(s.role.label + (clocked ? "・上班中" : ""))
                    .font(.brand(12.5, .regular))
                    .foregroundStyle(on ? Theme.page.opacity(0.7) : Theme.muted)
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
