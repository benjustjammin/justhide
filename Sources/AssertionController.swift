//
//  AssertionController.swift
//  JustHide
//
//  The app: a chevron, a set of hidden apps, an auto-hide timer.
//
//  Hiding is macOS 27's own concealment facility (see AssessmentMode), which
//  takes an allowlist of bundle identifiers permitted to show items. Nothing in
//  the menu bar's layout is touched, so unlike the width mechanism this leaves no
//  gap between items, nothing slides across a wide second display, and there is
//  nothing to calibrate.
//
//  Measured on macOS 27.0 (26A428) with an ad-hoc signed build:
//    - concealing one app took all of that app's items and left every other app's
//      alone (Vorssaint's three readouts went, Clop's icon stayed)
//    - this app's own chevron stayed visible while the assertion was live
//    - the Wi-Fi menu still opened normally from a click
//    - clicking the clock did nothing: Notification Center is blocked while an
//      assertion is held, which is the one real casualty
//

import Cocoa

final class AssertionController: NSObject, NSApplicationDelegate {
    private let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var token: AssessmentMode.Token?
    private var autoHideTimer: Timer?
    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?

    private var isConcealed: Bool { token != nil }

    private var hiddenBundleIDs: Set<String> { Settings.hiddenBundleIDs }

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.migrateIfNeeded()
        JustHide.applyGlyph(to: chevron, concealed: false)
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        guard AssessmentMode.isAvailable else {
            Log.controller.error("macOS 27 concealment is unavailable; relaunch with --width for the layout-based mechanism")
            chevron.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                            accessibilityDescription: "JustHide cannot hide items on this system")
            return
        }
        Log.controller.log("launched; hiding \(self.hiddenBundleIDs.sorted().joined(separator: ",") )")

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .justHideSettingsChanged, object: nil)
        applyShortcut()
        applyHoverMonitor()

        // Handy for testing the window without going through the menu.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreferencesWindow.shared.show()
            }
        }

        // Let the bar settle before the first conceal, so every owner has
        // registered its items.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.conceal()
        }
    }

    // MARK: - Conceal / reveal

    @objc private func chevronClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
            return
        }
        isConcealed ? reveal() : conceal()
    }

    private func conceal() {
        let hidden = hiddenBundleIDs
        guard !hidden.isEmpty else {
            Log.controller.log("nothing is marked hidden yet; right-click the chevron to choose")
            return
        }
        AssessmentMode.conceal(bundleIDs: hidden) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(token):
                // New assertion first, THEN release the old one: an app concealed
                // on both sides of a change never flickers into view.
                let previous = self.token
                self.token = token
                previous?.invalidate()
                JustHide.applyGlyph(to: self.chevron, concealed: true)
                self.autoHideTimer?.invalidate()
                Log.controller.log("concealed \(hidden.count) app(s)")
            case let .failure(error):
                Log.controller.error("conceal failed: \(error.localizedDescription)")
            }
        }
    }

    private func reveal() {
        token?.invalidate()
        token = nil
        JustHide.applyGlyph(to: chevron, concealed: false)
        Log.controller.log("revealed")
        scheduleAutoHide()
    }

    /// Re-applies the current membership without a visible flicker, for when the
    /// hidden set changes while items are already concealed.
    private func reapplyIfConcealed() {
        guard isConcealed else { return }
        if hiddenBundleIDs.isEmpty {
            reveal()
        } else {
            conceal()
        }
    }

    // MARK: - Auto hide

    private func scheduleAutoHide() {
        autoHideTimer?.invalidate()
        guard Settings.autoHideDelay > 0 else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: Settings.autoHideDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Don't hide out from under a pointer that is in the menu bar: the
            // user is most likely reaching for something just revealed.
            if MenuBarGeometry.pointerIsInMenuBar {
                self.scheduleAutoHide()
            } else {
                self.conceal()
            }
        }
    }

    @objc private func settingsChanged() {
        JustHide.applyGlyph(to: chevron, concealed: isConcealed)
        applyShortcut()
        applyHoverMonitor()
        if hiddenBundleIDs.isEmpty {
            if isConcealed { reveal() }
        } else {
            reapplyIfConcealed()
        }
    }

    // MARK: - Shortcut and hover

    private func applyShortcut() {
        GlobalHotkey.shared.update { [weak self] in
            guard let self = self else { return }
            self.isConcealed ? self.reveal() : self.conceal()
        }
    }

    /// Reveals when the pointer settles in the menu bar. Off unless asked for:
    /// a bar that opens as the cursor passes through is worse than one that
    /// waits to be clicked. Mouse-move monitoring needs no permission; keyboard
    /// monitoring would, which is why the shortcut uses Carbon instead.
    private func applyHoverMonitor() {
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
            hoverMonitor = nil
        }
        hoverDwellTimer?.invalidate()
        guard Settings.hoverToReveal else { return }

        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isConcealed, MenuBarGeometry.pointerIsInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // A short dwell, so merely crossing the bar does not open it.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isConcealed, MenuBarGeometry.pointerIsInMenuBar {
                    self.reveal()
                }
            }
        }
    }

    // MARK: - Menu

    private func showMenu() {
        guard let button = chevron.button else { return }
        let menu = NSMenu()

        let toggle = NSMenuItem(title: isConcealed ? "Show Hidden Icons" : "Hide Icons",
                                action: #selector(chevronClicked), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit JustHide",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    @objc private func openSettings() {
        PreferencesWindow.shared.show()
    }

}
