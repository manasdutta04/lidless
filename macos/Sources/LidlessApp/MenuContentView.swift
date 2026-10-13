import AppKit
import LidlessCore
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel

    private let presets: [(String, TimeInterval)] = [
        ("30m", 1_800), ("1h", 3_600), ("2h", 7_200),
        ("4h", 14_400), ("8h", 28_800), ("12h", 43_200),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.showHeatNotice { heatNotice }
            if let ready = model.readiness, !ready.ready { setupNeeded(ready) }

            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.busyText).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let session = model.snapshot?.session {
                activeView(session)
            } else {
                idleView
            }

            if let error = model.errorText {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            warningsView
            Divider()
            statusRow
            agentsView
            if model.showSettings {
                Divider()
                SettingsSection(model: model)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Lidless").font(.headline)
            Spacer()
            Text(model.isActive ? "Awake" : "Normal sleep")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(model.isActive ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
                .foregroundStyle(model.isActive ? .orange : .secondary)
        }
    }

    private var heatNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keep it ventilated", systemImage: "thermometer.sun")
                .font(.subheadline.weight(.semibold))
            Text("With the lid closed your Mac keeps running and can get warm. Leave it on a hard, open surface. Never in a bag or sleeve.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { model.acknowledgeHeatNotice() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    private func setupNeeded(_ ready: ReadinessReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Setup needed", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
            if !ready.privilege {
                Text("• Permission to change the sleep setting is not installed.").font(.callout)
            }
            if !ready.recoveryArmed {
                Text("• The recovery agent is not installed or not running.").font(.callout)
            }
            Text("Run `macos/scripts/install.sh` from the Lidless folder, then reopen this menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check again") { Task { await model.refreshReadiness() } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
    }

    // MARK: Active

    private func activeView(_ s: StatusSnapshot.SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DurationParser.clock(model.remaining))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Awake with the lid closed until \(s.endsAt.formatted(date: Calendar.current.isDateInToday(s.endsAt) ? .omitted : .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let cmd = s.command {
                    Text("Running: \(cmd.joined(separator: " "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if s.owner.kind == .cli {
                    Text("Started from the command line").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach([("+30m", 1_800.0), ("+1h", 3_600.0), ("+4h", 14_400.0)], id: \.0) { label, secs in
                    Button(label) { model.extend(secs) }
                }
                Spacer()
                Button(role: .destructive) { model.stop() } label: {
                    Text("Stop")
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.regular)
        }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep awake with the lid closed for…")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets, id: \.0) { label, secs in
                    Button { model.start(seconds: secs) } label: {
                        Text(label).frame(maxWidth: .infinity)
                    }
                    .disabled(model.readiness?.ready == false)
                }
            }
            HStack(spacing: 6) {
                TextField("Custom, e.g. 1d2h or 90m", text: $model.customDuration)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startCustom)
                Button("Start", action: startCustom)
                    .disabled(model.customDuration.trimmingCharacters(in: .whitespaces).isEmpty || model.readiness?.ready == false)
            }
            if let le = model.snapshot?.lastEnd {
                Text("Last session ended \(le.at.formatted(.relative(presentation: .named))): \(le.reason.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startCustom() {
        let raw = model.customDuration
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.start(raw)
        model.customDuration = ""
    }

    // MARK: Status

    @ViewBuilder
    private var warningsView: some View {
        let warnings = (model.snapshot?.warnings ?? []).filter { w in
            // Readiness problems already have their own card.
            !(model.readiness.map { !$0.ready } ?? false) || !w.hasPrefix("Lidless will not start")
        }
        if model.owner.networkLost {
            Label("Offline: remote control cannot reach this Mac.", systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        ForEach(warnings, id: \.self) { w in
            Label(w, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 14) {
            if let p = model.snapshot?.power {
                if p.hasBattery {
                    Label(p.percent.map { "\($0)%" } ?? "?", systemImage: p.onBattery ? batterySymbol(p.percent) : "bolt.fill")
                } else {
                    Label("AC", systemImage: "powerplug")
                }
                if p.thermal == .serious || p.thermal == .critical {
                    Label(p.thermal.rawValue.capitalized, systemImage: "thermometer.high").foregroundStyle(.red)
                }
            }
            if let lid = model.snapshot?.lidClosed {
                Label(lid ? "Lid closed" : "Lid open", systemImage: "laptopcomputer")
            }
            if model.owner.lowPowerActive {
                Label("Low Power", systemImage: "leaf")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var agentsView: some View {
        if !model.agents.isEmpty {
            let names = Dictionary(grouping: model.agents, by: \.name)
                .map { $0.value.count > 1 ? "\($0.key) ×\($0.value.count)" : $0.key }
                .sorted()
            Label("Agents running: \(names.joined(separator: ", "))", systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(model.showSettings ? "Hide settings" : "Settings…") { model.showSettings.toggle() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func batterySymbol(_ percent: Int?) -> String {
        guard let p = percent else { return "battery.0percent" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct SettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Turn the display off when the lid closes", isOn: $model.config.sleepDisplayOnLidClose)
            Toggle("Low Power Mode while the lid is closed (on battery)", isOn: $model.config.lowPowerOnLidClose)
            Toggle("Warn when the network drops", isOn: $model.config.warnOnNetworkLoss)
            Toggle("Notifications", isOn: $model.config.notifications)
            Toggle("End on critical temperature", isOn: $model.config.thermalRules)
            Stepper("Low Power Mode below \(model.config.lowPowerBelowPercent)%", value: $model.config.lowPowerBelowPercent, in: 0...100, step: 5)
            Stepper(model.config.endBelowPercent == 0 ? "Never end on low battery" : "End below \(model.config.endBelowPercent)% battery",
                    value: $model.config.endBelowPercent, in: 0...50, step: 5)
            if model.loginItemAvailable {
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.opensAtLogin = $0 }))
            }
            Button("Open log") { model.openLog() }
                .buttonStyle(.link)
                .font(.caption)
            Text("Changes apply to the next session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: model.config) { _, _ in model.saveConfig() }
    }
}
