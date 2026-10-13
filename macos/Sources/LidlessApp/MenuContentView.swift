import AppKit
import LidlessCore
import SwiftUI

/// Everything inside the rounded menu bar panel.
struct MenuContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        MainPage(model: model)
        .padding(Theme.padding)
        .frame(width: Theme.panelWidth, alignment: .top)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .transaction { $0.animation = nil }   // layout never animates: no drifting content
    }
}

// MARK: - Main page

struct MainPage: View {
    @Bindable var model: AppModel

    private let presets: [(String, TimeInterval)] = [
        ("30m", 1_800), ("1h", 3_600), ("2h", 7_200),
        ("4h", 14_400), ("8h", 28_800), ("12h", 43_200),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.needsSetup {
                SetupCard(model: model)
            }
            if let seconds = model.pendingStart {
                VentilationCard(model: model, seconds: seconds)
            } else if model.busy {
                busyCard
            } else if let s = model.snapshot?.session {
                activeSection(s)
            } else {
                idleSection
            }
            if let error = model.errorText { errorBanner(error) }
            warnings
            if let r = model.availableRelease {
                Button { model.openSettings(); model.windowPage = .about } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 13))
                        Text("Lidless \(r.version) is available").font(Theme.ui(12.5, weight: .medium))
                        Spacer()
                        Text("Update").font(Theme.ui(12))
                    }
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(rounded(Theme.cardRadius).fill(Theme.accentWash))
                    .contentShape(rounded(Theme.cardRadius))
                }
                .buttonStyle(.plain)
            }
            statusCard
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: BrandMark.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            Text("Lidless")
                .font(Theme.display(17, weight: .medium))
            Spacer(minLength: 8)
            statePill
        }
    }

    private var statePill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isActive ? Theme.accent : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(model.isActive ? "Awake" : "Sleeps normally")
                .font(Theme.ui(11.5, weight: .medium))
                .foregroundStyle(model.isActive ? Theme.accentText : Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(model.isActive ? Theme.accentWash : Theme.surface))
        .overlay(Capsule().strokeBorder(model.isActive ? Color.clear : Theme.border, lineWidth: 1))
    }

    // MARK: Idle

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Close the lid, keep working.")
                    .font(Theme.display(21))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Choose how long your Mac stays awake.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets, id: \.0) { label, secs in
                    Button(label) { model.start(seconds: secs) }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(!model.isReady)
                }
            }
            HStack(spacing: 6) {
                TextField("Custom, like 1h30m", text: $model.customDuration)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(rounded(Theme.controlRadius).fill(Theme.surface))
                    .overlay(rounded(Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
                    .onSubmit { model.start(model.customDuration) }
                Button("Start") { model.start(model.customDuration) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.isReady || model.customDuration.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11, weight: .light))
                Text("Keep it on a hard, ventilated surface. Never close it in a bag.")
                    .font(Theme.ui(11.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(model.thermal.isWarm ? Theme.accentText : Theme.textSecondary)
            if let le = model.snapshot?.lastEnd {
                Text("Last session ended \(le.at.formatted(.relative(presentation: .named))). \(le.reason.summary)")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Active

    private func activeSection(_ s: StatusSnapshot.SessionInfo) -> some View {
        Card(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Awake for")
                    .font(Theme.ui(11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(DurationParser.clock(model.remaining))
                    .font(Theme.display(34))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(detailText(s))
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressLine(fraction: model.remainingFraction)
            HStack(spacing: 6) {
                ForEach([("+15m", 900.0), ("+1h", 3_600.0), ("+4h", 14_400.0)], id: \.0) { label, secs in
                    Button(label) { model.extend(secs) }
                        .buttonStyle(OutlineButtonStyle(accent: true))
                }
                Button("Stop") { model.stop() }
                    .buttonStyle(DangerButtonStyle(expand: true))
            }
        }
    }

    private func detailText(_ s: StatusSnapshot.SessionInfo) -> String {
        let until = "Until \(s.endsAt.formatted(date: Calendar.current.isDateInToday(s.endsAt) ? .omitted : .abbreviated, time: .shortened))"
        if let cmd = s.command { return "\(until) · \(cmd.joined(separator: " "))" }
        switch s.owner.kind {
        case .app: return until
        case .cli: return "\(until) · from Terminal"
        case .run: return "\(until) · lidless run"
        }
    }

    private var busyCard: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.busyText).font(Theme.ui(13)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
        }
    }

    // MARK: Messages

    private func errorBanner(_ text: String) -> some View {
        Card(fill: Theme.dangerWash, stroke: .clear) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Theme.danger)
                Text(text)
                    .font(Theme.ui(12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.dismissError() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        // Readiness problems already have the setup card.
        let list = (model.snapshot?.warnings ?? []).filter { !$0.hasPrefix("Lidless will not start") }
        if !list.isEmpty {
            Card(fill: Theme.warningWash, stroke: .clear, spacing: 8) {
                ForEach(list, id: \.self) { w in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.warning)
                        Text(w)
                            .font(Theme.ui(12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        Card(padding: 12, spacing: 9) {
            if let p = model.snapshot?.power {
                StatusRow(symbol: batterySymbol(p), title: "Battery", value: batteryText(p),
                          valueColor: batteryLow(p) ? Theme.danger : Theme.textSecondary)
                Hairline()
            }
            StatusRow(symbol: "laptopcomputer", title: "Lid", value: model.snapshot?.lidClosed == true ? "Closed" : "Open")
            Hairline()
            StatusRow(symbol: model.online ? "wifi" : "wifi.slash", title: "Network",
                      value: model.online ? "Online" : "Offline", valueColor: model.online ? Theme.textSecondary : Theme.danger)
            Hairline()
            StatusRow(symbol: "terminal", title: "Agents", value: agentsText)
            if model.owner.lowPowerActive {
                Hairline()
                StatusRow(symbol: "leaf", title: "Low Power Mode", value: "On while closed")
            }
        }
    }

    private var agentsText: String {
        guard !model.agents.isEmpty else { return "None running" }
        return Dictionary(grouping: model.agents, by: \.name)
            .map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }
            .sorted()
            .joined(separator: ", ")
    }

    private func batteryText(_ p: StatusSnapshot.PowerInfo) -> String {
        guard p.hasBattery else { return "Power adapter" }
        let level = p.percent.map { "\($0)%" } ?? "Unknown"
        return p.onBattery ? level : "\(level), charging"
    }

    private func batteryLow(_ p: StatusSnapshot.PowerInfo) -> Bool {
        p.hasBattery && p.onBattery && (p.percent ?? 100) < 20
    }

    private func batterySymbol(_ p: StatusSnapshot.PowerInfo) -> String {
        guard p.hasBattery else { return "powerplug" }
        if !p.onBattery { return "bolt" }
        switch p.percent ?? 0 {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(LightIconLabelStyle())
            }
            .buttonStyle(QuietButtonStyle())
            Button { model.openHelp() } label: {
                Label("Help", systemImage: "questionmark.circle").labelStyle(LightIconLabelStyle())
            }
            .buttonStyle(QuietButtonStyle())
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, -8)
    }
}

/// The ventilation checkpoint shown before a start (first time ever, or
/// whenever the Mac is already warm).
struct VentilationCard: View {
    @Bindable var model: AppModel
    let seconds: TimeInterval

    var body: some View {
        let heat = model.thermal
        Card(fill: heat.isWarm ? Theme.warningWash : Theme.surface, stroke: heat.isWarm ? .clear : Theme.border, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: heat >= .serious ? "thermometer.high" : "thermometer.medium")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(heat.isWarm ? Theme.warning : Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(heat.isWarm ? "Your Mac is warm" : "Keep it ventilated")
                        .font(Theme.display(17, weight: .medium))
                    Text(heat.startWarning ?? "With the lid closed your Mac keeps working and can get warm. Leave it on a hard, open surface like a desk, never on a bed or sofa, and never in a bag or sleeve.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Lidless ends the session by itself if your Mac gets too hot.")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelStart() }
                    .buttonStyle(OutlineButtonStyle(expand: true))
                    .keyboardShortcut(.cancelAction)
                Button("Start \(DurationParser.format(seconds))") { model.confirmStart() }
                    .buttonStyle(PrimaryButtonStyle(expand: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Thin progress line for the time left.
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceSunken)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

/// SF Symbol at light weight next to the title.
struct LightIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 12, weight: .light))
            configuration.title
        }
    }
}

/// Shown until the one-time setup is done.
struct SetupCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card(fill: Theme.accentWash, stroke: .clear, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One-time setup")
                    .font(Theme.display(16, weight: .medium))
                Text("Lidless needs permission to switch one sleep setting, and a small helper that switches it back if anything goes wrong.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ready = model.readiness {
                VStack(alignment: .leading, spacing: 5) {
                    CheckRow(title: "Sleep permission", ok: ready.privilege)
                    CheckRow(title: "Recovery helper", ok: ready.recoveryArmed)
                }
            }
            if let message = model.setupMessage {
                Text(message)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Learn more") { model.openHelp() }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, -8)
                Spacer()
                if model.setupRunning {
                    ProgressView().controlSize(.small)
                }
                Button("Set Up…") { model.runSetup() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.setupRunning)
            }
        }
    }
}

struct CheckRow: View {
    let title: String
    let ok: Bool?

    var body: some View {
        HStack(spacing: 7) {
            switch ok {
            case .some(true):
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
            case .some(false):
                Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
            case .none:
                ProgressView().controlSize(.mini)
            }
            Text(title)
                .font(Theme.ui(12.5))
                .foregroundStyle(ok == true ? Theme.textSecondary : Theme.text)
        }
        .font(.system(size: 13, weight: .light))
    }
}

// MARK: - Shared rows

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(13))
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .frame(minHeight: 22)
    }
}

struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(13))
            Spacer()
            Text(format(value))
                .font(Theme.ui(12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 0) {
                stepButton("minus") { value = max(range.lowerBound, value - 5) }
                Rectangle().fill(Theme.border).frame(width: 1, height: 14)
                stepButton("plus") { value = min(range.upperBound, value + 5) }
            }
            .background(rounded(6).fill(Theme.surface))
            .overlay(rounded(6).strokeBorder(Theme.border, lineWidth: 1))
        }
        .frame(minHeight: 22)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
