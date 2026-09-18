//
//  NookController.swift
//  JustHide
//
//  The whole app: a chevron, a hidden section, an auto-hide timer.
//
//  Hiding mechanism (measured on macOS 27.0 build 26A428, and the same one Thaw
//  arrived at independently):
//
//    Inflate a divider status item so the items to its LEFT no longer fit the
//    menu bar's status region, and macOS overflows them behind its own chevron.
//    Two constraints make this non-trivial on 27:
//
//      * An item longer than the region will take is EJECTED from the layout
//        rather than laid out, and an ejected item pushes nothing. The usable
//        maximum varies with display and with how full the bar is, so it is
//        measured at runtime, never assumed.
//      * The push needed scales with the WIDEST attached bar, while that maximum
//        is capped by the NARROWEST. One item therefore cannot cover a notched
//        built-in plus a wider external. The shortfall is made up with spacer
//        items, each under the cap.
//
//  Spacers only do work while they sit between the divider and the chevron;
//  left of the divider they are overflowed along with the icons, and right of the
//  chevron they overflow the chevron itself. They land there by CREATION ORDER --
//  see the declarations below -- which needs no permissions and reassembles
//  correctly on every launch.
//

import Cocoa

// Superseded by AssertionController, which uses macOS 27's own concealment and
// therefore has none of this mechanism's artifacts. Kept as a fallback for a
// system where that facility is missing: launch with --width.
final class WidthController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Right-hand control the user clicks. Created FIRST so macOS places it
    /// rightmost of our items.
    private let chevron: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Named HERE, at creation, like every other item. Assigning autosaveName
        // later than the other items' reshuffles the group: doing it in
        // applicationDidFinishLaunching put the spacers LEFT of the divider,
        // where their width does nothing.
        item.autosaveName = "nook_chevron" + MenuBarGeometry.itemNameSuffix
        return item
    }()
    /// Created BETWEEN the chevron and the divider, and declared between them on
    /// purpose. On a first run there are no saved positions, so macOS places by
    /// creation order and declaration order IS bar order: chevron rightmost, then
    /// the spacers, then the divider leftmost -- exactly the push zone the spacers
    /// must occupy, with nothing moved.
    ///
    /// Every item is named at creation so that initial order then PERSISTS. Names
    /// matter: without them the group's position relative to the user's own icons
    /// varies between launches (measured: divider@1342 one run, @1149 the next,
    /// which silently emptied the hidden section). Assigning names later than the
    /// spacers' is equally wrong -- that reshuffles the group itself.
    private let spacers: [NSStatusItem] = (0..<MenuBarGeometry.spacerCountNeeded).map { index in
        // Born at a SEED width, not 1pt. AppKit does not materialise a
        // WindowServer window for a status item created too narrow, so a spacer
        // created at 1pt is never placed in the bar at all -- measured: all four
        // reporting the divider's own x, none laid out, nothing in the push zone.
        // They are shrunk to 1pt once placed, in settleSpacers().
        let item = NSStatusBar.system.statusItem(withLength: JustHide.spacerSeedLength)
        item.autosaveName = "nook_spacer_\(index)" + MenuBarGeometry.itemNameSuffix
        return item
    }
    private let divider: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: JustHide.dividerExpandedLength)
        item.autosaveName = "nook_divider" + MenuBarGeometry.itemNameSuffix
        return item
    }()

    /// Which spacers sit in the push zone, sampled while everything is still
    /// deflated. It cannot be measured after the divider inflates: the inflated
    /// divider fills the region, the spacers stop being laid out individually,
    /// and all of them report one identical placeholder x (measured: four
    /// spacers all at 1245).
    private var zoneSpacers: [NSStatusItem] = []
    /// Divider-to-chevron gap measured while deflated, used to confirm after the
    /// fact that the inflated divider was actually laid out and not ejected.
    private var gapBeforeInflating: CGFloat?
    private var recollapseAttempts = 0
    private var isCollapsed = false
    private var autoHideTimer: Timer?
    private let calibrator = CollapseCalibrator()

    func applicationDidFinishLaunching(_ note: Notification) {
        JustHide.applyGlyph(to: chevron, concealed: false)
        chevron.button?.target = self
        chevron.button?.action = #selector(chevronClicked)
        chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        divider.button?.image = JustHide.dividerImage()
        divider.menu = buildMenu()

        Log.controller.log("launched with \(self.spacers.count) spacers, name generation \(MenuBarGeometry.spacerPool.generation); widest bar \(Int(MenuBarGeometry.widestBarWidth))pt")

        applyShortcut()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .justHideSettingsChanged, object: nil)

        // Let the seeded spacers materialise and take their slots, then shrink
        // them out of sight before the first collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.settleSpacers()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.collapse()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PreferencesWindow.shared.show()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            UpdateCheck.checkIfDue()
        }
    }

    /// Shrinks the seeded spacers to a hairline now that macOS has placed them.
    private func settleSpacers() {
        let before = spacers.map { Int($0.button?.window?.frame.minX ?? -1) }
        // Deflated to JustHide.spacerIdleLength. At 1pt each still costs ~17pt of bar
        // (a status window has its own padding), which shows up as an obvious gap
        // between the divider and the chevron. 0pt is only safe AFTER the item has
        // been materialised by its seed width -- created at 0 it never appears at
        // all.
        for spacer in spacers { spacer.length = JustHide.spacerIdleLength }
        Log.controller.log("spacers seeded at \(before.map(String.init).joined(separator: ",")) then shrunk to \(Int(JustHide.spacerIdleLength))pt")
    }

    // MARK: - Collapse / expand

    @objc private func chevronClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            if let menu = divider.menu, let button = chevron.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
            }
            return
        }
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard !isCollapsed else { return }
        // Bring the spacers back before measuring anything. Re-showing an item
        // can reorder the group, so their placement is re-checked below on every
        // collapse rather than assumed to have survived.
        let wereWithdrawn = spacers.contains { !$0.isVisible }
        if wereWithdrawn {
            for spacer in spacers {
                spacer.isVisible = true
                spacer.length = JustHide.spacerSeedLength
            }
            // Let them materialise and take slots, then measure and collapse.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                for spacer in self?.spacers ?? [] { spacer.length = JustHide.spacerIdleLength }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.collapse()
                }
            }
            return
        }

        // Sample the zone FIRST, while the bar is still open and every frame is
        // real. Calibration inflates the divider, after which it cannot be read.
        zoneSpacers = SpacerPlacement.spacersInPushZone(spacers: spacers, divider: divider, chevron: chevron)
        gapBeforeInflating = SpacerPlacement.dividerToChevronGap(divider: divider, chevron: chevron)
        let open = ([("divider", divider), ("chevron", chevron)]
                    + spacers.enumerated().map { ("spacer\($0.offset)", $0.element) })
            .map { "\($0.0)@\(Int($0.1.button?.window?.frame.minX ?? -1))" }
            .joined(separator: " ")
        Log.controller.log("open layout: \(open) -> \(self.zoneSpacers.count) in the push zone")

        calibrator.honoredLength(divider: divider, chevron: chevron) { [weak self] perItem in
            guard let self = self, let perItem = perItem else {
                Log.controller.error("calibration failed; leaving the bar expanded")
                return
            }
            self.isCollapsed = true
            self.divider.length = perItem
            JustHide.applyGlyph(to: self.chevron, concealed: true)
            // Let the collapse settle before judging where the spacers are: a
            // spacer squeezed out of a full bar only takes its slot once the
            // collapse has freed up region.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.inflateSpacers(perItem: perItem)
                self?.verifyCollapseTookEffect()
            }
            Log.controller.log("collapsed, divider \(Int(perItem))pt")
        }
    }

    func expand() {
        guard isCollapsed else { return }
        isCollapsed = false
        divider.length = JustHide.dividerExpandedLength
        // Taken OUT of the bar, not just shrunk. A status item still occupies
        // ~16pt at zero length, so leaving them in left a visible gap between
        // the divider and the chevron whenever the bar was open -- the only
        // cosmetic cost of this mechanism that is actually fixable.
        for spacer in spacers { spacer.isVisible = false }
        JustHide.applyGlyph(to: chevron, concealed: false)
        Log.controller.log("expanded, spacers withdrawn from the bar")
        scheduleAutoHide()
    }

    /// Inflates only the spacers that are genuinely in the push zone, and gives
    /// the chevron back if inflating cost us it.
    private func inflateSpacers(perItem: CGFloat) {
        let positions = ([("divider", divider), ("chevron", chevron)]
                         + spacers.enumerated().map { ("spacer\($0.offset)", $0.element) })
            .map { "\($0.0)@\(Int($0.1.button?.window?.frame.minX ?? -1))" }
            .joined(separator: " ")
        Log.controller.log("layout: \(positions)")
        // Use the sample taken while open; re-measuring now would report none.
        let zone = zoneSpacers
        let wanted = MenuBarGeometry.spacersNeeded(perItem: perItem)
        for spacer in spacers { spacer.length = JustHide.spacerIdleLength }
        for spacer in zone.prefix(wanted) { spacer.length = perItem }
        Log.controller.log("inflated \(min(zone.count, wanted)) of \(wanted) wanted spacers (\(zone.count) in the push zone)")
        noteAnyShortfall(wanted: wanted, inZone: zone.count)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isCollapsed else { return }
            guard !SpacerPlacement.chevronIsOnMenuBarRow(self.chevron) else { return }
            Log.controller.error("chevron left the menu bar; backing off to the divider alone")
            for spacer in self.spacers { spacer.length = JustHide.spacerIdleLength }
        }
    }

    /// A cached collapse length goes stale whenever the bar's occupancy changes --
    /// withdrawing the spacers on expand is enough to do it -- and an over-long
    /// divider is EJECTED rather than clamped, which hides nothing at all while
    /// every internal state still says "collapsed". Measured happening in exactly
    /// that sequence, so the collapse now checks its own work.
    private func verifyCollapseTookEffect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.isCollapsed,
                  let before = self.gapBeforeInflating,
                  let now = SpacerPlacement.dividerToChevronGap(divider: self.divider, chevron: self.chevron)
            else { return }
            let moved = abs(now - before)
            guard moved > 48 else {
                self.recollapseAttempts = 0
                Log.controller.log("collapse verified (gap moved \(Int(moved))pt)")
                return
            }
            guard self.recollapseAttempts < 2 else {
                Log.controller.error("collapse still not taking effect; leaving the bar open")
                self.expand()
                return
            }
            self.recollapseAttempts += 1
            Log.controller.error("divider was ejected (gap moved \(Int(moved))pt): stale calibration, re-measuring")
            self.calibrator.invalidate()
            self.isCollapsed = false
            self.divider.length = JustHide.dividerExpandedLength
            for spacer in self.spacers { spacer.length = JustHide.spacerIdleLength }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.collapse()
            }
        }
    }

    // MARK: - Auto hide

    private func scheduleAutoHide() {
        autoHideTimer?.invalidate()
        guard Settings.autoHideDelay > 0 else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: Settings.autoHideDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Never yank the bar shut while the pointer is in it: the user is
            // most likely reaching for one of the icons just revealed.
            if MenuBarGeometry.pointerIsInMenuBar {
                self.scheduleAutoHide()
            } else {
                self.collapse()
            }
        }
    }

    @objc private func screensChanged() {
        calibrator.invalidate()
        if isCollapsed {
            // Re-measure against the new geometry rather than reuse a stale length.
            isCollapsed = false
            divider.length = JustHide.dividerExpandedLength
            for spacer in spacers { spacer.length = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.collapse()
            }
        }
    }

    // Deliberately no "grow the pool later" path IN THIS SESSION: an item
    // created after the divider lands on the wrong side of it, so the pool is
    // fixed at launch. What a shortfall does instead is record what the next
    // launch should build, and say so -- because both shortfalls are otherwise
    // silent. The bar collapses, the push falls short, and icons stay visible
    // with nothing anywhere saying why.
    private func noteAnyShortfall(wanted: Int, inZone: Int) {
        if wanted > spacers.count, MenuBarGeometry.widenSpacerPool(to: wanted) {
            Log.controller.error("the push needs \(wanted) spacers but only \(self.spacers.count) exist; widening the pool for the next launch")
            Mechanism.report(advice: "This display arrangement needs more room than JustHide "
                             + "reserved, so some icons are still showing. Restart JustHide to "
                             + "fix it, then drag your icons to the left of the divider once.")
            return
        }
        // The pool is big enough but part of it is not between the divider and
        // the chevron, so its width does nothing. Only re-registering the items
        // can fix that, and only the user can decide to pay for it.
        if inZone < min(wanted, spacers.count) {
            Log.controller.error("\(inZone) of \(self.spacers.count) spacers are in the push zone; \(wanted) are wanted")
            Mechanism.report(advice: "Some of JustHide's items are in the wrong place, so not "
                             + "everything hides. Choose \"Rearrange JustHide's Items\" from its "
                             + "menu to start them off again.")
            return
        }
        Mechanism.report(advice: nil)
    }

    // MARK: - Shortcut

    private func applyShortcut() {
        GlobalHotkey.shared.update { [weak self] in
            guard let self = self else { return }
            self.isCollapsed ? self.expand() : self.collapse()
        }
    }

    @objc private func settingsChanged() {
        JustHide.applyGlyph(to: chevron, concealed: isCollapsed)
        applyShortcut()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        return menu
    }

    /// Rebuilt every time the menu opens: the toggle names the direction it will
    /// go, and the shortcut can change while the app runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let version = UpdateCheck.availableVersion {
            let update = NSMenuItem(title: "Get JustHide \(version)\u{2026}",
                                    action: #selector(openUpdate), keyEquivalent: "")
            update.target = self
            update.attributedTitle = JustHide.menuTitle("Get JustHide \(version)\u{2026}",
                                                        symbol: "arrow.down.circle")
            menu.addItem(update)
            menu.addItem(NSMenuItem.separator())
        }
        // No "tidy spacers" command: moving an item programmatically needs a
        // synthetic cmd-drag, and on macOS 27.0 that is silently ignored (the
        // modifier is seen -- a cmd-click suppresses an item's action -- but the
        // drop never commits). Rearranging instead means giving every one of our
        // items a name it has never had, after which macOS places the group by
        // creation order, which is the one thing here that does work.
        let toggle = NSMenuItem(title: isCollapsed ? "Show Hidden Icons" : "Hide Icons",
                                action: #selector(chevronClicked), keyEquivalent: "")
        toggle.target = self
        toggle.attributedTitle = JustHide.menuTitle(isCollapsed ? "Show Hidden Icons" : "Hide Icons",
                                                    symbol: isCollapsed ? "eye" : "eye.slash")
        if let shortcut = Settings.menuKeyEquivalent {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let rearrange = NSMenuItem(title: "Rearrange JustHide's Items",
                                   action: #selector(rearrangeItems), keyEquivalent: "")
        rearrange.target = self
        rearrange.attributedTitle = JustHide.menuTitle("Rearrange JustHide's Items",
                                                       symbol: "arrow.left.and.right")
        menu.addItem(rearrange)

        let switchItem = NSMenuItem(title: "Use macOS Hiding",
                                    action: #selector(useConcealment), keyEquivalent: "")
        switchItem.target = self
        switchItem.attributedTitle = JustHide.menuTitle("Use macOS Hiding",
                                                        symbol: "arrow.2.squarepath")
        switchItem.isEnabled = AssessmentMode.isAvailable
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit JustHide",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.attributedTitle = JustHide.menuTitle("Quit JustHide", symbol: "door.left.hand.open")
        menu.addItem(quit)
    }

    @objc private func openSettings() {
        PreferencesWindow.shared.show()
    }

    @objc private func openUpdate() {
        UpdateCheck.openReleasePage()
    }

    @objc private func useConcealment() {
        Mechanism.use(.concealment)
    }

    /// Re-registers our items under fresh names and starts again, which puts
    /// them back in divider-spacers-chevron order. The cost is that the group
    /// lands at the far left of the bar, so the user's own icons have to be
    /// cmd-dragged to the left of the divider once -- exactly as on a first
    /// install. Said plainly first, because it cannot be undone from here.
    @objc private func rearrangeItems() {
        let alert = NSAlert()
        alert.messageText = "Rearrange JustHide's items?"
        alert.informativeText = "JustHide will start again with its divider, spacers and symbol "
            + "in the right order. They will appear at the left end of the menu bar, so you will "
            + "need to hold \u{2318} and drag the icons you want hidden to the left of the divider "
            + "once."
        alert.addButton(withTitle: "Rearrange and Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MenuBarGeometry.bumpItemGeneration()
        Mechanism.report(advice: nil)
        Log.controller.log("re-registering our items as generation \(MenuBarGeometry.spacerPool.generation)")
        Mechanism.relaunch()
    }

}
