import AppKit
import SwiftUI

/// Borderless floating panel with continuous rounded corners on all four
/// sides. It can become key so the duration field accepts typing, and closes
/// on Escape or when it loses focus.
final class RoundedPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}


/// Owns the status item and the panel under it.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = RoundedPanel()
    private let hosting: NSHostingView<PanelRootView>
    private var clickMonitor: Any?
    private var lastClose = Date.distantPast
    /// Latest content height reported by SwiftUI.
    private var contentHeight: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        let box = HeightBox()
        hosting = NSHostingView(rootView: PanelRootView(model: model, onHeight: { box.handler?($0) }))
        super.init()
        box.handler = { [weak self] h in self?.contentHeightChanged(h) }

        // Solid warm surface (drawn by SwiftUI), clipped to a continuous rounded rect.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400))
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.panelRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        renderStatusItem()
    }

    // MARK: Status item

    /// Re-renders the button whenever the observed model values change.
    private func renderStatusItem() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            button.image = model.menuBarImage
            if let text = model.menuBarText {
                button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                    .baselineOffset: 0.5,
                ])
            } else {
                button.title = ""
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.renderStatusItem() }
        }
    }

    // MARK: Panel

    var isOpen: Bool { panel.isVisible }

    @objc private func togglePanel() {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.25 {
            // A click on the icon first makes the panel lose focus (closing it);
            // don't reopen it on the same click.
            open()
        }
    }

    func open() {
        model.panelWillOpen()
        // Let SwiftUI lay out the fresh data now (this reports the height
        // synchronously), so the panel opens at exactly the right size.
        hosting.layoutSubtreeIfNeeded()
        if contentHeight > 0 { fit(height: contentHeight) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        lastClose = Date()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    #if DEBUG
    func debugCapture(to path: String) {
        print("top \(panel.frame.maxY)  height \(panel.frame.height)  content \(contentHeight)")
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 1, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        fit(height: height)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Sizes the panel to `height` and places it under the status item,
    /// keeping the top edge fixed so content changes only move the bottom.
    private func fit(height rawHeight: CGFloat) {
        guard rawHeight > 1 else { return }
        let width = Theme.panelWidth
        let height = ceil(rawHeight)
        var top: CGFloat
        var midX: CGFloat
        if let button = statusItem.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            top = rect.minY - 6
            midX = rect.midX
        } else if let screen = NSScreen.main {
            top = screen.visibleFrame.maxY - 6
            midX = screen.visibleFrame.maxX - width / 2 - 12
        } else {
            return
        }
        var x = (midX - width / 2).rounded()
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            x = min(max(x, f.minX + 8), f.maxX - width - 8)
            top = min(top, f.maxY)
        }
        let frame = NSRect(x: x, y: (top - height).rounded(), width: width, height: height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
    }
}

final class HeightBox: @unchecked Sendable {
    var handler: ((CGFloat) -> Void)?
}

/// The panel's SwiftUI root. The content keeps its natural height (measured
/// and reported on every change) and is pinned to the top, so if the window
/// is momentarily a different size nothing is centred or cut off at the top.
struct PanelRootView: View {
    let model: AppModel
    let onHeight: (CGFloat) -> Void

    var body: some View {
        MenuContentView(model: model)
            .fixedSize(horizontal: false, vertical: true)
            .background(rounded(Theme.panelRadius).fill(Theme.background))
            .overlay(rounded(Theme.panelRadius).strokeBorder(Theme.border, lineWidth: 1))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onHeight(ceil(height))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
