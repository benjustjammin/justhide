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
    /// Nothing at all is done about where this sits, deliberately.
    ///
    /// Two things were tried on 27.0 and both made it worse. A preferred position
    /// (`NSStatusItem Preferred Position <name>` = 10000) does pin it to the far
    /// left, but that makes the symbol the end of the bar rather than a boundary
    /// as soon as hidden icons come back, and it cannot fix the order anyway --
    /// every other app's slot is remembered per app, and launch order does not
    /// come into it. Setting an `autosaveName` is just as bad: it changes the
    /// item's identity, so macOS forgets the slot this item has always had and
    /// treats it as brand new, which lands it at the far left. Leaving both alone
    /// keeps the position macOS already remembers, and a cmd-drag still sticks.
    private let chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var token: AssessmentMode.Token?
    private var autoHideTimer: Timer?
    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    private var allowlistTimer: Timer?
    private var runningAppsObserver: NSKeyValueObservation?
    private var knownPIDs: Set<pid_t> = []

    private var isConcealed: Bool { token != nil }

    private var hiddenBundleIDs: Set<String> { Settings.hiddenBundleIDs }

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.migrateIfNeeded()
        // Asked up front rather than at the moment it is first needed: the thing
        // it is needed for is a list in Settings, and a permission dialog that
        // appears while someone is reading a list is worse than one at launch.
        AccessibilityAccess.requestOnFirstLaunch()
        JustHide.applyGlyph(to: chevron, concealed: false)
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // A second copy of JustHide asks this one to open Settings rather than
        // running alongside it. Registered before the availability check below so
        // Settings can still be opened when hiding itself is unavailable.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettings(_:)),
            name: .justHideShowSettings, object: nil)

        // Handy for testing the window without going through the menu. Above the
        // availability check on purpose: the window is exactly what someone
        // needs when hiding is NOT working.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreferencesWindow.shared.show()
            }
        }

        guard AssessmentMode.isAvailable else {
            // Not fatal and not silent: the chevron says something is wrong, the
            // menu and Settings offer the width mechanism instead. Keep the
            // settings observer so switching from the window still works.
            Mechanism.report(failure: "This version of macOS does not have the hiding facility "
                             + "JustHide uses.")
            JustHide.applyWarningGlyph(to: chevron)
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsChanged),
                name: .justHideSettingsChanged, object: nil)
            return
        }
        Log.controller.log("launched; hiding \(self.hiddenBundleIDs.sorted().joined(separator: ",") )")

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .justHideSettingsChanged, object: nil)
        knownPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        // KVO rather than NSWorkspace.didLaunchApplicationNotification, which was
        // measured not to fire for LSUIElement apps -- and a menu bar agent is
        // exactly the kind of app this is about. runningApplications sees them.
        runningAppsObserver = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { self?.runningAppsChanged() }
        }
        applyShortcut()
        applyHoverMonitor()


        // Let the bar settle before the first conceal, so every owner has
        // registered its items.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.conceal()
        }

        // Well after the work of starting up, and once a day at most.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            UpdateCheck.checkIfDue()
        }
    }

    // MARK: - Conceal / reveal

    @objc private func chevronClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
            return
        }
        isConcealed ? reveal() : conceal(userAsked: true)
    }

    /// `userAsked` marks the paths where someone is watching -- a click, the
    /// shortcut, the menu. Those get told when hiding fails; the automatic ones
    /// (launch, auto-hide, an allowlist refresh) only mark the chevron, because
    /// a dialog nobody asked for in the middle of something else is worse than
    /// the chevron carrying the news until they look.
    private func conceal(userAsked: Bool = false) {
        let hidden = hiddenBundleIDs
        guard !hidden.isEmpty else {
            Log.controller.log("nothing is marked hidden yet; right-click the chevron to choose")
            return
        }
        AssessmentMode.conceal(allowing: AssessmentMode.allowlist(excluding: hidden)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(token):
                // New assertion first, THEN release the old one: an app concealed
                // on both sides of a change never flickers into view. Measured on
                // 27.0 that this order reveals too -- an app the new list permits
                // and the old one did not comes straight back, both for an icon
                // concealed since it appeared and one hidden on purpose until now
                // -- so there is never a need to drop concealment and re-apply it.
                let previous = self.token
                self.token = token
                previous?.invalidate()
                JustHide.applyGlyph(to: self.chevron, concealed: true)
                self.autoHideTimer?.invalidate()
                Mechanism.report(failure: nil)
                Log.controller.log("concealed \(hidden.count) app(s)")
            case let .failure(error):
                // The completion handler comes back from MenuBarAgent, so it is
                // not promised to be the main queue, and everything below is UI.
                DispatchQueue.main.async {
                    let detail = error.localizedDescription
                    Log.controller.error("conceal failed: \(detail)")
                    Mechanism.report(failure: "macOS would not hide the icons: \(detail)")
                    JustHide.applyWarningGlyph(to: self.chevron)
                    if userAsked { Mechanism.offerFallback(detail: detail) }
                }
            }
        }
    }

    private func reveal() {
        token?.invalidate()
        token = nil
        Mechanism.report(failure: nil)
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

    // MARK: - Newly launched apps

    /// The allowlist is the set of apps running when the assertion was applied,
    /// so an app launched afterwards is not on it and its icon is concealed even
    /// though nobody asked for it. Measured with Newton: no icon on launch, then
    /// an icon after a toggle, because toggling rebuilt the list. Nothing was
    /// wrong with the app or the hidden set -- the allowlist was just stale.
    ///
    /// Re-applying the assertion fixes it, but it stalls MenuBarAgent for a
    /// moment, so it is only done for an app that has actually put an icon up.
    /// Apps do not do that at launch -- an Electron app can take seconds -- so
    /// each newcomer is looked at a few times before being given up on.
    private static let itemChecks: [TimeInterval] = [1, 2.5, 5, 9]

    private func runningAppsChanged() {
        let running = NSWorkspace.shared.runningApplications
        let newcomers = running.filter { !knownPIDs.contains($0.processIdentifier) }
        knownPIDs = Set(running.map(\.processIdentifier))
        guard isConcealed else { return }
        for app in newcomers {
            guard let bundleID = app.bundleIdentifier,
                  !hiddenBundleIDs.contains(bundleID) else { continue }
            checkForItems(from: app, named: bundleID, attempt: 0)
        }
    }

    private func checkForItems(from app: NSRunningApplication, named bundleID: String, attempt: Int) {
        guard attempt < Self.itemChecks.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemChecks[attempt]) { [weak self] in
            guard let self = self, self.isConcealed, !app.isTerminated,
                  !self.hiddenBundleIDs.contains(bundleID) else { return }
            // Without Accessibility there is no way to tell whether this app owns
            // an icon, so refresh once regardless: a missing icon is worse than a
            // pointless refresh.
            let owns = AXIsProcessTrusted()
                ? AXMenuBar.hasItems(forPID: app.processIdentifier)
                : attempt == 0
            guard owns else {
                self.checkForItems(from: app, named: bundleID, attempt: attempt + 1)
                return
            }
            Log.controller.log("\(bundleID) put a menu bar icon up after we concealed; refreshing the allowlist")
            self.scheduleAllowlistRefresh()
        }
    }

    /// Coalesced: several apps can arrive at once (a login, or an app that brings
    /// agents with it), and each refresh stalls MenuBarAgent for 100-150ms.
    private func scheduleAllowlistRefresh() {
        allowlistTimer?.invalidate()
        allowlistTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, self.isConcealed else { return }
            self.conceal()
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
        if Mechanism.failure != nil {
            // Re-applying the normal glyph here would go back to claiming the
            // icons are merely showing.
            JustHide.applyWarningGlyph(to: chevron)
        } else {
            JustHide.applyGlyph(to: chevron, concealed: isConcealed)
        }
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
            self.isConcealed ? self.reveal() : self.conceal(userAsked: true)
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

        if let version = UpdateCheck.availableVersion {
            let update = NSMenuItem(title: "Get JustHide \(version)\u{2026}",
                                    action: #selector(openUpdate), keyEquivalent: "")
            update.target = self
            update.attributedTitle = JustHide.menuTitle("Get JustHide \(version)\u{2026}",
                                                        symbol: "arrow.down.circle")
            menu.addItem(update)
            menu.addItem(NSMenuItem.separator())
        }

        if Mechanism.failure != nil {
            let switchItem = NSMenuItem(title: "Use the Older Method",
                                        action: #selector(useWidthMechanism), keyEquivalent: "")
            switchItem.target = self
            switchItem.attributedTitle = JustHide.menuTitle("Use the Older Method",
                                                            symbol: "arrow.2.squarepath")
            menu.addItem(switchItem)
            menu.addItem(NSMenuItem.separator())
        }

        let toggle = NSMenuItem(title: isConcealed ? "Show Hidden Icons" : "Hide Icons",
                                action: #selector(chevronClicked), keyEquivalent: "")
        toggle.target = self
        toggle.attributedTitle = JustHide.menuTitle(isConcealed ? "Show Hidden Icons" : "Hide Icons",
                                                    symbol: isConcealed ? "eye" : "eye.slash")
        // The shortcut is registered with Carbon, not here; this is so the menu
        // shows what it is, the way every other app's menu does.
        if let shortcut = Settings.menuKeyEquivalent {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        // macOS draws its own cog on this one, so it is left alone -- an
        // attributed title here would put a second cog inside the row.
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit JustHide",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.attributedTitle = JustHide.menuTitle("Quit JustHide", symbol: "door.left.hand.open")
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    @objc private func openSettings() {
        PreferencesWindow.shared.show()
    }

    @objc private func useWidthMechanism() {
        Mechanism.use(.width)
    }

    @objc private func openUpdate() {
        UpdateCheck.openReleasePage()
    }

    /// From another copy of JustHide that found this one already running.
    @objc private func showSettings(_ note: Notification) {
        Log.controller.log("a second copy asked for Settings")
        PreferencesWindow.shared.show()
    }

}
