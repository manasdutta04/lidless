import AppKit
import LidlessCore
import SwiftUI

/// The desktop window: opened from the Dock icon, ⌘, or the panel's Settings
/// button. One fixed size (no resizing or zooming). Closing it never quits
/// Lidless; only Quit does.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Default size, and also the smallest the window can be made.
    static let size = NSSize(width: 1000, height: 680)
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(page: WindowPage? = nil) {
        if let page { model.windowPage = page }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Lidless"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenPrimary]
            w.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x262624) : NSColor(hex: 0xFAF9F5)
            }
            let hosting = NSHostingView(rootView: DesktopView(model: model))
            hosting.sizingOptions = []
            w.contentView = hosting
            w.delegate = self
            w.setFrameAutosaveName("LidlessWindow")
            let restored = w.setFrameUsingName("LidlessWindow")
            applyMinimumSize(w)
            if !restored { w.center() }
            window = w
        }
        model.panelWillOpen()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Never smaller than the default size (or the screen, if that is smaller);
    /// as large as the screen allows.
    private var minimumContentSize: NSSize {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? Self.size
        return NSSize(width: min(Self.size.width, visible.width), height: min(Self.size.height, visible.height - 28))
    }

    private func applyMinimumSize(_ w: NSWindow) {
        let minimum = minimumContentSize
        w.contentMinSize = minimum
        w.minSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        let current = w.contentRect(forFrameRect: w.frame).size
        if current.width < minimum.width || current.height < minimum.height {
            w.setContentSize(NSSize(width: max(current.width, minimum.width), height: max(current.height, minimum.height)))
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        return NSSize(width: max(frameSize.width, minFrame.width), height: max(frameSize.height, minFrame.height))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let w = window { applyMinimumSize(w) }
    }

    #if DEBUG
    func debugResize(_ size: NSSize) {
        // Route through the same path a user drag takes.
        if let w = window {
            let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            w.setContentSize(w.contentRect(forFrameRect: NSRect(origin: .zero, size: windowWillResize(w, to: frame))).size)
        }
        print("asked \(Int(size.width))x\(Int(size.height)) -> got \(Int(window?.contentLayoutRect.width ?? 0))x\(Int(window?.contentLayoutRect.height ?? 0)) (min \(Int(window?.contentMinSize.width ?? 0))x\(Int(window?.contentMinSize.height ?? 0)))")
    }

    func debugCapture(to path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

// MARK: - Layout

struct DesktopView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 236)
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                Group {
                    switch model.windowPage {
                    case .overview: OverviewPage(model: model)
                    case .history: HistoryPage(model: model)
                    case .settings: PreferencesPage(model: model)
                    case .setup: SetupPage(model: model)
                    case .about: AboutPage(model: model)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 52)
                .padding(.bottom, 40)
                .frame(maxWidth: 980, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .background(Theme.background)
        }
        .frame(minWidth: SettingsWindowController.size.width, maxWidth: .infinity,
               minHeight: SettingsWindowController.size.height, maxHeight: .infinity)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .transaction { $0.animation = nil }
        .onChange(of: model.config) { _, _ in model.saveConfig() }
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: BrandMark.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                Text("Lidless").font(Theme.display(20, weight: .medium))
            }
            .padding(.horizontal, 18)
            .padding(.top, 50)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(WindowPage.allCases) { page in
                    navItem(page)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            if let r = model.availableRelease {
                Button { model.windowPage = .about } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .regular))
                        Text("Update to \(r.version)")
                            .font(Theme.ui(12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(rounded(Theme.controlRadius).fill(Theme.accentWash))
                    .contentShape(rounded(Theme.controlRadius))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(model.isActive ? Theme.accent : Theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(model.isActive ? "Awake · \(DurationParser.clock(model.remaining))" : "Sleeps normally")
                    .font(Theme.ui(12))
                    .monospacedDigit()
                    .foregroundStyle(model.isActive ? Theme.accentText : Theme.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceSunken)
    }

    private func navItem(_ page: WindowPage) -> some View {
        let selected = model.windowPage == page
        return Button { model.windowPage = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: selected ? .regular : .light))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(page.title)
                    .font(Theme.ui(13.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer(minLength: 0)
                if page == .setup && model.needsSetup {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(rounded(Theme.controlRadius).fill(selected ? Theme.surface : Color.clear))
            .overlay(rounded(Theme.controlRadius).strokeBorder(selected ? Theme.border : Color.clear, lineWidth: 1))
            .contentShape(rounded(Theme.controlRadius))
        }
        .buttonStyle(.plain)
    }
}

/// Page title in the display serif with a secondary line.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var subtitleColor: Color = Theme.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.display(32))
            Text(subtitle)
                .font(Theme.ui(14))
                .foregroundStyle(subtitleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group of cards with an optional footnote.
struct PageSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.display(15, weight: .medium))
                .padding(.leading, 2)
            Card(padding: 14, spacing: 11) { content }
            if let footer {
                Text(footer)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - Overview

/// Stats, charts and tips. Read-only: sessions are started from the menu bar
/// panel, never from this window.
struct OverviewPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: greeting, subtitle: statusLine,
                       subtitleColor: model.isActive ? Theme.accentText : Theme.textSecondary)
            FeaturedTips(model: model)
            if model.needsSetup { SetupCard(model: model) }
            if model.isActive { liveStatus }
            statsGrid
            ActivityHeatmap(days: UsageStats.daily(model.history, days: 7 * 12, now: model.now))
            WeekChart(days: model.stats.lastSevenDays)
            HourChart(hours: UsageStats.hourOfDay(model.history))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: model.now) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var statusLine: String {
        if let s = model.snapshot?.session {
            let until = s.endsAt.formatted(date: Calendar.current.isDateInToday(s.endsAt) ? .omitted : .abbreviated, time: .shortened)
            return "Your Mac is staying awake with the lid closed until \(until)."
        }
        return "Your Mac sleeps normally. Start a session from the menu bar whenever an agent has work to do."
    }

    /// Read-only summary of the running session.
    private var liveStatus: some View {
        Card(fill: Theme.accentWash, stroke: .clear, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Awake").font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accentText)
                    Text(DurationParser.clock(model.remaining))
                        .font(Theme.display(30))
                        .monospacedDigit()
                }
                Spacer()
                Button("Open Menu Bar Panel") { model.openPanel() }
                    .buttonStyle(OutlineButtonStyle(expand: false))
            }
            ProgressLine(fraction: model.remainingFraction)
            Text("Extend or stop the session from the menu bar.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statsGrid: some View {
        let s = model.stats
        let f = DurationParser.format
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Lidless").font(Theme.display(15, weight: .medium))
                Spacer()
                if let first = s.firstSession {
                    Text("Since \(first.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if s.sessions == 0 {
                Card {
                    Text("Your stats appear here after your first session: time awake, hours with the lid closed, and more. Start one from the Lidless icon in the menu bar.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    StatTile(value: f(s.totalAwakeSeconds), label: "Time awake", detail: "across \(s.sessions) session\(s.sessions == 1 ? "" : "s")")
                    StatTile(value: f(s.closedLidSeconds), label: "With the lid closed", detail: "your agents kept working")
                    StatTile(value: f(s.thisWeekSeconds), label: "This week", detail: "last 7 days")
                    StatTile(value: f(s.longestSeconds), label: "Longest session", detail: "average \(f(s.averageSeconds))")
                    StatTile(value: "\(s.sessions)", label: "Sessions", detail: s.commandSessions > 0 ? "\(s.commandSessions) wrapped a command" : "from the menu bar or Terminal")
                    StatTile(value: s.cleanRestorePercent.map { "\($0)%" } ?? "—", label: "Restored cleanly",
                             detail: s.endedBySafety > 0 ? "\(s.endedBySafety) ended by safety limits" : "sleep settings put back")
                }
            }
        }
    }
}

/// GitHub-style grid of the last 12 weeks: one cell per day, darker = more
/// time awake. Columns are weeks, rows are weekdays.
struct ActivityHeatmap: View {
    let days: [UsageStats.Day]

    var body: some View {
        let maxSeconds = max(days.map(\.awakeSeconds).max() ?? 0, 1)
        let calendar = Calendar.current
        // Pad the front so the first column starts on the calendar's first weekday.
        let lead = days.first.map { (calendar.component(.weekday, from: $0.start) - calendar.firstWeekday + 7) % 7 } ?? 0
        let cells: [UsageStats.Day?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        let columns = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        let activeDays = days.filter { $0.awakeSeconds > 0 }.count

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity").font(Theme.display(15, weight: .medium))
                Spacer()
                Text("\(activeDays) active day\(activeDays == 1 ? "" : "s") in the last 12 weeks")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 2)
            Card(spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    // Weekday labels (Mon, Wed, Fri rows).
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let weekday = (calendar.firstWeekday - 1 + row) % 7
                            Text(row % 2 == 1 ? calendar.shortWeekdaySymbols[weekday] : "")
                                .font(Theme.ui(10))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(height: 20)
                        }
                    }
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 4) {
                                ForEach(0..<7, id: \.self) { row in
                                    let day = row < week.count ? week[row] : nil
                                    rounded(3)
                                        .fill(color(day?.awakeSeconds, max: maxSeconds, exists: day != nil))
                                        .frame(height: 20)
                                        .help(day.map { "\($0.start.formatted(date: .abbreviated, time: .omitted)): \($0.awakeSeconds > 0 ? DurationParser.format($0.awakeSeconds) : "no sessions")" } ?? "")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Spacer()
                    Text("Less").font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        rounded(3).fill(level == 0 ? Theme.surfaceSunken : Theme.accent.opacity(0.2 + 0.8 * level))
                            .frame(width: 10, height: 10)
                    }
                    Text("More").font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func color(_ seconds: TimeInterval?, max: TimeInterval, exists: Bool) -> Color {
        guard exists else { return .clear }
        guard let seconds, seconds > 0 else { return Theme.surfaceSunken }
        let level = (seconds / max).squareRoot()  // keeps short days visible
        return Theme.accent.opacity(0.25 + 0.75 * level)
    }
}

/// When the Mac usually works: awake time by hour of day.
struct HourChart: View {
    let hours: [TimeInterval]

    var body: some View {
        let maxSeconds = max(hours.max() ?? 0, 1)
        let peak = hours.firstIndex(of: hours.max() ?? 0) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("When your Mac works").font(Theme.display(15, weight: .medium))
                Spacer()
                if hours.contains(where: { $0 > 0 }) {
                    Text("Busiest around \(hourLabel(peak))")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 2)
            Card(spacing: 6) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        rounded(2)
                            .fill(hours[h] > 0 ? Theme.accent.opacity(h == peak ? 1 : 0.5) : Theme.surfaceSunken)
                            .frame(height: max(3, 60 * hours[h] / maxSeconds))
                            .frame(maxWidth: .infinity)
                            .help("\(hourLabel(h)): \(hours[h] > 0 ? DurationParser.format(hours[h]) : "none")")
                    }
                }
                .frame(height: 60, alignment: .bottom)
                HStack {
                    ForEach([0, 6, 12, 18], id: \.self) { h in
                        Text(hourLabel(h)).font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary)
                        if h != 18 { Spacer() }
                    }
                    Spacer()
                    Text(hourLabel(23)).font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

/// A tip for the Overview banner, with an optional action.
struct Tip: Identifiable, Equatable {
    enum Action: Equatable {
        case openPanel, openSettings, copy(String), link(String)
    }

    let symbol: String
    let title: String
    let body: String
    var action: Action? = nil
    var actionTitle: String? = nil
    /// About the Mac's current state (shown first, marked "Right now").
    var timely = false
    var id: String { title }
}

@MainActor
enum TipLibrary {
    /// Context-aware tips first, then general good practice.
    static func tips(for model: AppModel) -> [Tip] {
        var list: [Tip] = []
        let c = model.config
        if model.thermal.isWarm {
            list.append(Tip(symbol: "thermometer.high", title: "Your Mac is warm right now",
                            body: "Give it open air before closing the lid: a desk, not a bed, sofa or lap.", timely: true))
        }
        if !model.online {
            list.append(Tip(symbol: "wifi.exclamationmark", title: "You're offline",
                            body: "Connect to Wi-Fi before closing the lid, so remote control and SSH can reach your agent.",
                            action: .link("x-apple.systempreferences:com.apple.wifi-settings-extension"), actionTitle: "Open Wi-Fi Settings",
                            timely: true))
        }
        if let p = model.snapshot?.power, p.hasBattery, p.onBattery, let pct = p.percent, pct < 50 {
            list.append(Tip(symbol: "powerplug", title: "Plug in for a long session",
                            body: "You're at \(pct)%. Low Power Mode starts below \(c.lowPowerBelowPercent)%, and the session ends below \(c.endBelowPercent)% to protect the battery.",
                            action: .openSettings, actionTitle: "Battery Settings", timely: true))
        }
        if !model.isActive, let agent = model.agents.first {
            list.append(Tip(symbol: "terminal", title: "\(agent.name) is running",
                            body: "Start a session from the Lidless icon in the menu bar before you close the lid, and it keeps working.",
                            action: .openPanel, actionTitle: "Open Menu Bar Panel", timely: true))
        }
        list += [
            Tip(symbol: "wind", title: "Keep it ventilated",
                body: "Closed-lid work holds in heat. Use a hard, open surface, and never close the Mac in a bag or sleeve.",
                action: .link("https://github.com/manasdutta04/lidless#readme"), actionTitle: "Learn More"),
            Tip(symbol: "chevron.left.forwardslash.chevron.right", title: "Wrap your agent in one command",
                body: "Run lidless run -- claude and your Mac stays awake exactly as long as the agent runs, then sleeps normally.",
                action: .copy("lidless run -- claude"), actionTitle: "Copy Command"),
            Tip(symbol: "wifi", title: "Stay connected",
                body: "Remote control and SSH need a network. Lidless warns you if the connection drops while the lid is closed.",
                action: .openSettings, actionTitle: "Notification Settings"),
            Tip(symbol: "bolt", title: "Plug in for overnight work",
                body: "On the power adapter the battery limits don't apply, so a session can run as long as you set."),
            Tip(symbol: "mic.slash", title: "The microphone turns off with the lid",
                body: "Apple silicon Macs disconnect the built-in mic when closed. Use AirPods or an external mic for voice tools."),
        ]
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    static let decorativeSymbols = ["wind", "wifi", "bolt", "terminal", "mic.slash", "thermometer.medium", "powerplug"]
}

/// Featured tip banner under the greeting: one tip at a time with an action,
/// paging dots and a cluster of round icons along the right edge. Flat colours.
struct FeaturedTips: View {
    @Bindable var model: AppModel

    var body: some View {
        let tips = TipLibrary.tips(for: model)
        let index = tips.isEmpty ? 0 : model.tipIndex % tips.count
        if let tip = tips.isEmpty ? nil : tips[index] {
            ZStack(alignment: .topLeading) {
                rounded(18).fill(Theme.heroFill)
                IconCluster(highlight: tip.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipShape(rounded(18))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if tip.timely {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            Text("Right now").font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                        } else {
                            Text("Tip \(index + 1) of \(tips.count)").font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.heroTextSecondary)
                        }
                    }
                    .padding(.bottom, 10)
                    Text(tip.title)
                        .font(Theme.display(27))
                        .foregroundStyle(Theme.heroText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Text(tip.body)
                        .font(Theme.ui(14))
                        .foregroundStyle(Theme.heroTextSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 18)
                    HStack(spacing: 18) {
                        if let action = tip.action, let title = tip.actionTitle {
                            Button(copiedRecently(action) ? "Copied" : title) { perform(action) }
                                .buttonStyle(HeroButtonStyle())
                        }
                        if tips.count > 1 {
                            Button("Next tip") { model.nextTip() }
                                .buttonStyle(.plain)
                                .font(Theme.ui(13.5, weight: .medium))
                                .foregroundStyle(Theme.heroText)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            ForEach(0..<tips.count, id: \.self) { i in
                                Capsule()
                                    .fill(i == index ? Theme.heroText : Theme.heroText.opacity(0.25))
                                    .frame(width: i == index ? 14 : 6, height: 6)
                                    .onTapGesture { model.tipIndex = i }
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 470, alignment: .leading)
            }
            .frame(height: 236)
            .frame(maxWidth: .infinity)
        }
    }

    private func copiedRecently(_ action: Tip.Action) -> Bool {
        if case .copy = action, let at = model.copiedAt { return model.now.timeIntervalSince(at) < 2.5 }
        return false
    }

    private func perform(_ action: Tip.Action) {
        switch action {
        case .openPanel: model.openPanel()
        case .openSettings: model.windowPage = .settings
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            model.showCopied()
        case .link(let url): model.openURL(url)
        }
    }
}

/// Round icon badges scattered along the banner's right edge, some cut off by
/// the card, the current tip's icon filled with the accent.
struct IconCluster: View {
    let highlight: String

    // (x from the right edge, y from the top, symbol index)
    private let spots: [(CGFloat, CGFloat, Int)] = [
        (-14, 22, 0), (92, 34, 1), (196, 14, 2),
        (40, 118, 3), (146, 104, 4),
        (-6, 196, 5), (98, 186, 6),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                let symbol = TipLibrary.decorativeSymbols[spot.2]
                let on = symbol == highlight
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(on ? Color.white : Theme.heroText.opacity(0.75))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(on ? Theme.accent : Theme.heroText.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Theme.heroText.opacity(on ? 0 : 0.14), lineWidth: 1))
                    .position(x: proxy.size.width - spot.0 - 31, y: spot.1 + 31)
            }
        }
        .frame(width: 300)
        .allowsHitTesting(false)
    }
}

/// Light button on the dark banner.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(13.5, weight: .medium))
            .foregroundStyle(Theme.heroButtonText)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(rounded(9).fill(Theme.heroButton.opacity(configuration.isPressed ? 0.85 : 1)))
            .contentShape(rounded(9))
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.display(24))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(Theme.ui(12, weight: .medium))
            Text(detail)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rounded(Theme.cardRadius).fill(Theme.surface))
        .overlay(rounded(Theme.cardRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Seven flat bars: awake time per day, today on the right.
struct WeekChart: View {
    let days: [UsageStats.Day]

    var body: some View {
        let maxSeconds = max(days.map(\.awakeSeconds).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("This week").font(Theme.display(15, weight: .medium)).padding(.leading, 2)
            Card(spacing: 0) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let isToday = index == days.count - 1
                        VStack(spacing: 6) {
                            Text(day.awakeSeconds > 0 ? DurationParser.format(day.awakeSeconds).components(separatedBy: " ").first ?? "" : "")
                                .font(Theme.ui(10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .fixedSize()
                            rounded(4)
                                .fill(day.awakeSeconds > 0 ? (isToday ? Theme.accent : Theme.accent.opacity(0.45)) : Theme.surfaceSunken)
                                .frame(height: max(4, 84 * day.awakeSeconds / maxSeconds))
                            Text(day.start.formatted(.dateTime.weekday(.abbreviated)))
                                .font(Theme.ui(11, weight: isToday ? .medium : .regular))
                                .foregroundStyle(isToday ? Theme.text : Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 124, alignment: .bottom)
            }
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "History", subtitle: model.history.isEmpty
                       ? "Sessions you run will be listed here."
                       : "Your last \(min(model.history.count, 100)) sessions, newest first.")
            if !model.history.isEmpty {
                Card(padding: 0, spacing: 0) {
                    ForEach(Array(model.history.prefix(100).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Hairline().padding(.leading, 14) }
                        HistoryRow(entry: entry)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(entry.restoreComplete ? Theme.textSecondary : Theme.danger)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.startedAt.formatted(.relative(presentation: .named)).capitalizedFirst + " · " + entry.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.ui(13))
                Text(subtitle)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(DurationParser.format(entry.duration))
                    .font(Theme.ui(13, weight: .medium))
                    .monospacedDigit()
                if entry.closedLidSeconds > 0 {
                    Text("\(DurationParser.format(entry.closedLidSeconds)) lid closed")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var icon: String {
        switch entry.reason {
        case .batteryFloor, .batteryUnreadable: return "battery.25percent"
        case .thermalFloor: return "thermometer.high"
        case .commandExited: return "terminal"
        case .expired: return "timer"
        default: return entry.restoreComplete ? "checkmark.circle" : "exclamationmark.circle"
        }
    }

    private var subtitle: String {
        let source: String
        switch entry.owner {
        case .app: source = "Menu bar"
        case .cli: source = "Terminal"
        case .run: source = "lidless run"
        }
        return "\(source) · \(entry.reason.summary)"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Settings

struct PreferencesPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Settings", subtitle: "Changes apply right away, and to every new session.")

            PageSection(title: "While the lid is closed") {
                ToggleRow(title: "Turn the display off", isOn: $model.config.sleepDisplayOnLidClose)
                Hairline()
                ToggleRow(title: "Use Low Power Mode on battery", isOn: $model.config.lowPowerOnLidClose)
            }

            PageSection(title: "Safety", footer: "Battery rules apply on battery power only. A session also ends if the battery level cannot be read twice in a row.") {
                StepperRow(title: "Low Power Mode below", value: $model.config.lowPowerBelowPercent, range: 5...100,
                           format: { "\($0)%" })
                Hairline()
                StepperRow(title: "End the session below", value: $model.config.endBelowPercent, range: 0...50,
                           format: { $0 == 0 ? "Never" : "\($0)%" })
                Hairline()
                ToggleRow(title: "End on critical temperature", isOn: $model.config.thermalRules)
            }

            PageSection(title: "General") {
                ToggleRow(title: "Show in Dock", isOn: $model.config.showInDock)
                Hairline()
                if model.loginItemAvailable {
                    ToggleRow(title: "Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.opensAtLogin = $0 }))
                    Hairline()
                }
                ToggleRow(title: "Animate the menu bar icon", isOn: $model.config.animateMenuBarIcon)
            }

            PageSection(title: "Notifications") {
                ToggleRow(title: "Session started and ended", isOn: $model.config.notifications)
                Hairline()
                ToggleRow(title: "Warn when the network drops", isOn: $model.config.warnOnNetworkLoss)
            }
        }
    }
}

// MARK: - Setup

struct SetupPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Setup", subtitle: model.needsSetup
                       ? "One step left: allow Lidless to switch one sleep setting."
                       : "Everything Lidless needs is installed and working.")

            PageSection(title: "Status") {
                statusRow("Sleep permission", ok: model.readiness?.privilege,
                          detail: "Lets Lidless run four exact pmset commands without asking for a password.")
                Hairline()
                statusRow("Recovery helper", ok: model.readiness?.recoveryArmed,
                          detail: model.readiness?.recoveryDetail ?? "Checks every minute and puts settings back if Lidless stops unexpectedly.")
                if let message = model.setupMessage {
                    Hairline()
                    Text(message)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button(model.needsSetup ? "Set Up…" : "Run Setup Again") { model.runSetup() }
                        .buttonStyle(model.needsSetup ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(OutlineButtonStyle(expand: false)))
                        .disabled(model.setupRunning)
                    Button("Open Log") { model.openLog() }
                        .buttonStyle(OutlineButtonStyle(expand: false))
                    if model.setupRunning { ProgressView().controlSize(.small) }
                }
            }

            PageSection(title: "What runs as administrator",
                        footer: "Nothing else ever runs with elevated rights. The rule lives in /etc/sudoers.d/lidless and applies to your account only.") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(["pmset -a disablesleep 1", "pmset -a disablesleep 0", "pmset -b lowpowermode 1", "pmset -b lowpowermode 0"], id: \.self) { cmd in
                        Text(cmd)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            PageSection(title: "Remove Lidless",
                        footer: "Restores your sleep settings, then removes the permission and the recovery helper. Afterwards, move Lidless to the Trash.") {
                HStack {
                    Text(model.isActive ? "Stop the current session first." : "Uninstall the permission and helper")
                        .font(Theme.ui(13))
                        .foregroundStyle(model.isActive ? Theme.textTertiary : Theme.text)
                    Spacer()
                    Button("Uninstall…") { model.runUninstall() }
                        .buttonStyle(DangerButtonStyle())
                        .disabled(model.setupRunning || model.isActive)
                }
            }
        }
    }

    private func statusRow(_ title: String, ok: Bool?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CheckRow(title: "", ok: ok).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13))
                Text(detail)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(ok == true ? "Ready" : ok == false ? "Not set up" : "Checking…")
                .font(Theme.ui(12))
                .foregroundStyle(ok == true ? Theme.success : ok == false ? Theme.danger : Theme.textTertiary)
        }
    }
}

/// Type-erased button style for conditional styling.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - About & Updates

struct AboutPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                Image(nsImage: BrandMark.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lidless").font(Theme.display(30))
                    Text("Version \(LidlessVersion.string)")
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Close the lid. Your agent keeps working.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            PageSection(title: "Updates") {
                updateBody
                Hairline()
                ToggleRow(title: "Check for updates automatically", isOn: $model.config.checkForUpdates)
            }

            PageSection(title: "Links") {
                linkRow("GitHub", detail: "Source code, issues and releases", url: "https://github.com/manasdutta04/lidless")
                Hairline()
                linkRow("Report an issue", detail: "Tell us what went wrong", url: "https://github.com/manasdutta04/lidless/issues/new")
                Hairline()
                linkRow("All releases", detail: "Release notes and downloads", url: "https://github.com/manasdutta04/lidless/releases")
            }

            Text("Free and open source under the MIT License. No accounts, no telemetry. The only network request Lidless makes is the update check above.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var updateBody: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(updateTitle).font(Theme.ui(13, weight: .medium))
                Text(updateDetail)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch model.update {
            case .checking, .downloading:
                ProgressView().controlSize(.small)
            case .available:
                HStack(spacing: 8) {
                    Button("Release Notes") { model.openReleasePage() }
                        .buttonStyle(OutlineButtonStyle(expand: false))
                    Button("Download") { model.downloadUpdate() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            case .downloaded:
                Button("Show in Finder") { model.revealDownload() }
                    .buttonStyle(OutlineButtonStyle(expand: false))
            default:
                Button("Check Now") { model.checkForUpdates() }
                    .buttonStyle(OutlineButtonStyle(expand: false))
            }
        }
    }

    private var updateTitle: String {
        switch model.update {
        case .idle: return "Lidless \(LidlessVersion.string)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date"
        case .noReleases: return "You're on the latest build"
        case .available(let r): return "Lidless \(r.version) is available"
        case .downloading(let r): return "Downloading Lidless \(r.version)…"
        case .downloaded(let r, _): return "Lidless \(r.version) downloaded"
        case .failed: return "Couldn't check for updates"
        }
    }

    private var updateDetail: String {
        switch model.update {
        case .idle: return "Check GitHub for a newer version."
        case .checking: return "Asking GitHub for the latest release."
        case .upToDate(let v): return "Lidless \(v) is the newest version."
        case .noReleases: return "No newer release has been published yet."
        case .available(let r):
            let date = r.publishedAt.map { " Released \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            return "You have \(LidlessVersion.string).\(date)"
        case .downloading: return "Saving the disk image to your Downloads folder."
        case .downloaded: return "The disk image is open. Quit Lidless, drag the new Lidless into Applications to replace it, then open it again."
        case .failed(let m): return m
        }
    }

    private func linkRow(_ title: String, detail: String, url: String) -> some View {
        Button { model.openURL(url) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.ui(13))
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
