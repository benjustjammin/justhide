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
    private var clockRestoreTimer: Timer?
    private var clockFrame: CGRect?
    private var clockFrameReadAt: Date?
    /// Concealment lifted for the clock, rather than by the user. Everything
    /// else -- the glyph, the auto-hide timer, the newcomer watch -- goes on
    /// treating the icons as hidden, because as far as the user is concerned
    /// they are; only the assertion is down.
    private var suspendedForClock = false
    /// So the watcher can tell "not open yet" from "opened and has now closed".
    private var sawNotificationCentreOpen = false
    private var allowlistTimer: Timer?
    private var runningAppsObserver: NSKeyValueObservation?
    private var knownPIDs: Set<pid_t> = []

    private var isConcealed: Bool { token != nil || suspendedForClock }

    private var hiddenBundleIDs: Set<String> { Settings.hiddenBundleIDs }

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.migrateIfNeeded()
        // Nothing is asked for here. Accessibility is needed to LIST what is in
        // the menu bar, not to hide anything, so the ask belongs in the app
        // picker -- the one place the answer changes what someone sees -- rather
        // than in a dialog at every first launch of every new build.
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

        // Opening or closing the lid, or plugging a display in, moves the menu
        // bar around, and the bar that appears draws our item from whatever it
        // last had -- which is how a glyph ends up disagreeing with the state on
        // the other screen. Nothing else re-applies it, because the glyph only
        // changes when the state does. (The width mechanism has watched this
        // notification all along, for its own reasons.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

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
        // The glyph goes on BEFORE the assertion does. Measured on 27.0 with a
        // second display: while an assertion is held, the secondary bar's copy
        // of our item stops updating -- it keeps whatever it was drawn with, so
        // a glyph applied after the assertion went up never appears over there,
        // while a probe holding no assertion updated both bars within 80ms.
        // Drawing first means the copy freezes on the right thing.
        JustHide.applyGlyph(to: chevron, concealed: true)

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
                self.endClockSuspension()
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
        endClockSuspension()
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

    @objc private func screensChanged() {
        Log.controller.log("displays changed; re-applying the glyph")
        // The bar may have moved to another display, taking the clock with it.
        clockFrameReadAt = nil
        refreshGlyph()
        // Again once the new arrangement has settled: the notification arrives
        // while the bars are still being rebuilt, so the first pass can be drawn
        // over by whatever that bar was already holding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshGlyph()
        }
    }

    /// The chevron as it should look right now, warning included: re-applying
    /// the normal glyph while hiding is broken would go back to claiming the
    /// icons are merely showing.
    private func refreshGlyph() {
        if Mechanism.failure != nil {
            JustHide.applyWarningGlyph(to: chevron)
        } else {
            JustHide.applyGlyph(to: chevron, concealed: isConcealed)
        }
    }

    @objc private func settingsChanged() {
        refreshGlyph()
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
        GlobalHotkey.shared.applyItemShortcuts()
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
        hoverDwellTimer = nil
        // Two features share the one monitor: revealing on hover, and standing
        // aside for the clock. Either is reason enough to watch the pointer.
        guard Settings.hoverToReveal || Settings.clockClickThrough else {
            // Turning the clock option off mid-suspension must not leave the
            // icons out.
            endClockSuspension(puttingConcealmentBack: true)
            return
        }

        var mask: NSEvent.EventTypeMask = []
        if Settings.hoverToReveal { mask.insert(.mouseMoved) }
        if Settings.clockClickThrough { mask.insert(.leftMouseUp) }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return }
            if event.type == .leftMouseUp {
                self.clockClicked()
            } else {
                self.pointerMoved()
            }
        }
    }

    private func pointerMoved() {
        guard Settings.hoverToReveal else { return }
        // Standing aside for the clock must not turn into a full reveal: a
        // glance at the time is not a request to open the bar.
        guard isConcealed, !suspendedForClock, MenuBarGeometry.pointerIsInMenuBar else {
            hoverDwellTimer?.invalidate()
            hoverDwellTimer = nil
            return
        }
        // A short dwell, so merely crossing the bar does not open it.
        guard hoverDwellTimer == nil else { return }
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.hoverDwellTimer = nil
            if self.isConcealed, !self.suspendedForClock, MenuBarGeometry.pointerIsInMenuBar {
                self.reveal()
            }
        }
    }

    // MARK: - Standing aside for the clock

    /// The clock is the one casualty of this mechanism: while an assertion is
    /// held MenuBarAgent ignores clicks on its OWN items, so Notification Centre
    /// cannot be opened.
    ///
    /// Driven by the CLICK, not by hovering. Hover was tried first and Ben's
    /// verdict was that it is far too keen -- the top right corner is a route
    /// the pointer takes constantly, and every crossing brought the hidden icons
    /// back. A click is unambiguous: you only click the clock when you want the
    /// clock.
    ///
    /// The cost of waiting for the click is that the click itself is already
    /// gone: it reached MenuBarAgent while the assertion was still up, and was
    /// ignored. So it is replayed. Measured on 27.0 (26A428):
    ///   - assertion held: `AXUIElementPerformAction(clock, kAXPressAction)`
    ///     returns 0 and nothing opens, the same silent refusal a real click gets
    ///   - assertion invalidated: the same press opens Notification Centre
    /// which is what makes replaying work at all. The element is looked up after
    /// the assertion is down, since one found while it was up does not respond.
    private func clockClicked() {
        guard Settings.clockClickThrough, isConcealed, !suspendedForClock,
              let clock = currentClockFrame() else { return }
        // Only the x range is compared. The clock's frame comes from
        // Accessibility, whose origin is the top left, while NSEvent.mouseLocation
        // counts up from the bottom left -- and pointerIsInMenuBar has already
        // settled the vertical question for every attached display, so flipping
        // coordinates here would add a second chance to get it wrong.
        let mouse = NSEvent.mouseLocation
        guard MenuBarGeometry.pointerIsInMenuBar,
              mouse.x >= clock.minX - 2, mouse.x <= clock.maxX + 2 else { return }

        guard let token = token else { return }
        suspendedForClock = true
        token.invalidate()
        self.token = nil
        Log.controller.log("clock clicked; concealment suspended")

        // A beat for MenuBarAgent to notice the restriction has gone, then
        // replay -- but only if the panel did not open by itself. Between our
        // mouse-up and here the real click can occasionally get through, and
        // pressing as well would toggle it straight back shut.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, self.suspendedForClock else { return }
            if !Self.notificationCentreIsOpen {
                AccessibilityAccess.pressClock()
            }
            self.watchForNotificationCentreClosing(attempt: 0)
        }
    }

    /// Re-conceals once the panel has gone, which is the "click off" half of
    /// what Ben asked for. Polled rather than observed: Notification Centre
    /// posts nothing we can subscribe to, and its window appearing and
    /// disappearing in the window list is the only signal there is.
    ///
    /// The attempt count is a safety net. If the press never landed -- no
    /// Accessibility, a future macOS that moves the clock -- nothing would ever
    /// close and the icons would stay out for the rest of the session.
    private func watchForNotificationCentreClosing(attempt: Int) {
        clockRestoreTimer?.invalidate()
        // Half a minute of looking, then give up and put the bar back.
        guard attempt < 75 else {
            Log.controller.log("Notification Centre never opened or never closed; concealing again")
            restoreAfterClock()
            return
        }
        clockRestoreTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self, self.suspendedForClock else { return }
            // Never seen open yet: keep waiting, it may still be coming up.
            if Self.notificationCentreIsOpen {
                self.sawNotificationCentreOpen = true
                self.watchForNotificationCentreClosing(attempt: attempt + 1)
            } else if self.sawNotificationCentreOpen {
                self.restoreAfterClock()
            } else {
                self.watchForNotificationCentreClosing(attempt: attempt + 1)
            }
        }
    }

    private func restoreAfterClock() {
        clockRestoreTimer?.invalidate()
        clockRestoreTimer = nil
        guard suspendedForClock else { return }
        suspendedForClock = false
        sawNotificationCentreOpen = false
        Log.controller.log("Notification Centre closed; concealing again")
        conceal()
    }

    /// Clears the suspension. The user-driven paths -- a click, the shortcut, a
    /// reveal -- want the state cleared and nothing else, because they are about
    /// to decide for themselves what the bar should look like.
    private func endClockSuspension(puttingConcealmentBack: Bool = false) {
        clockRestoreTimer?.invalidate()
        clockRestoreTimer = nil
        let wasSuspended = suspendedForClock
        suspendedForClock = false
        sawNotificationCentreOpen = false
        if puttingConcealmentBack, wasSuspended { conceal() }
    }

    /// Cached, because mouse-moved fires far too often to ask Accessibility each
    /// time, and re-read often enough to follow the clock as its width changes
    /// with the date string or the bar moves between displays.
    private func currentClockFrame() -> CGRect? {
        if let readAt = clockFrameReadAt, Date().timeIntervalSince(readAt) < 5 {
            return clockFrame
        }
        clockFrame = AXMenuBar.clockFrame()
        clockFrameReadAt = Date()
        if clockFrame == nil {
            // Without Accessibility there is no way to know where the clock is,
            // so the option silently does nothing. Say so once in a while rather
            // than leaving someone wondering why their click is still dead.
            Log.controller.log("cannot locate the clock; Accessibility is needed for the clock option")
        }
        return clockFrame
    }

    /// Measured on 27.0: while the panel is open, Notification Centre owns an
    /// on-screen window (layer 21, full screen); closed, it owns none. Matched on
    /// the owning process's bundle identifier rather than the window name, which
    /// is localised -- and reading names is the part that would need Screen
    /// Recording, while the owner and bounds do not.
    private static var notificationCentreIsOpen: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                == "com.apple.notificationcenterui"
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
