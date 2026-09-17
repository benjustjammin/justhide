//
//  main.swift
//  JustHide
//
//  Modes:
//    Nook              run normally (menu bar hider)
//    Nook --width      use the legacy layout-based hiding instead
//    Nook --list       print every status item found, and exit
//    Nook --selftest   prove the move primitive works, using only Nook's OWN
//                      items so nothing of the user's is disturbed, and exit
//
//  --list needs no permissions at all. --selftest needs Accessibility, and is
//  deliberately part of this bundle rather than a separate tool so the grant it
//  prompts for is the same one the real app uses.
//

import Cocoa

let arguments = Set(CommandLine.arguments.dropFirst())

// MARK: - --list

if arguments.contains("--list") {
    print("Screens:")
    for (index, screen) in NSScreen.screens.enumerated() {
        let region = screen.auxiliaryTopRightArea.map {
            "statusRegion \(Int($0.origin.x))..\(Int($0.maxX))"
        } ?? "no notch"
        print(String(format: "  [%d] %@ %.0fx%.0f at x=%.0f  %@",
                     index, screen.localizedName, screen.frame.width, screen.frame.height,
                     screen.frame.origin.x, region))
    }
    print("\nStatus items (level \(MenuBarItem.statusWindowLevel)), left to right:")
    let groups = MenuBarItemLister.itemsByDisplay()
    if groups.isEmpty { print("  none found") }
    for group in groups {
        print("  display: \(group.screen?.localizedName ?? "unattributed")")
        for item in group.items {
            print(String(format: "    x %6.0f..%-6.0f w %4.0f  pid %-6d  %@",
                         item.bounds.minX, item.bounds.maxX, item.bounds.width,
                         item.ownerPID, item.ownerName))
        }
    }
    print("\nStatus items via the window list (macOS 26 and earlier):")
    let windowListItems = MenuBarItemLister.currentItems()
    if windowListItems.isEmpty {
        print("  none -- expected on macOS 27: the Window Server composites the bar,")
        print("  so per-app status items are no longer separate windows.")
    }
    for item in windowListItems {
        print(String(format: "    x %6.0f..%-6.0f  pid %-6d  %@",
                     item.bounds.minX, item.bounds.maxX, item.ownerPID, item.ownerName))
    }

    print("\nStatus items via Accessibility (macOS 27):")
    if !ItemMover.hasAccessibilityPermission {
        print("  Accessibility permission NOT granted -- required even to READ these on 27.")
        print("  Prompting; grant it to Nook, then run --list again.")
        ItemMover.requestAccessibilityPermission()
    } else {
        let axItems = AXMenuBar.currentItems()
        if axItems.isEmpty { print("  none found") }
        for item in axItems {
            print(String(format: "    x %6.0f..%-6.0f w %4.0f  %@%@",
                         item.frame.minX, item.frame.maxX, item.frame.width,
                         item.ownerName, item.title.map { " (\($0))" } ?? ""))
        }
    }

    print("\nAccessibility trusted: \(ItemMover.hasAccessibilityPermission)")
    exit(0)
}

// MARK: - --apps

// What the "add an app" list in Settings would offer, and why. Useful when an app
// that is plainly in the bar does not turn up in that list.
if arguments.contains("--apps") {
    // Careful reading this: a process started from a terminal inherits THAT
    // terminal's Accessibility grant, so this can say true while the app itself
    // has none. The app's own state is the one in Settings.
    print("Accessibility trusted: \(AXIsProcessTrusted()) (this process; a terminal's grant is inherited)")
    print("Hidden: \(Settings.hiddenBundleIDs.sorted().joined(separator: ", "))")
    let candidates = MenuBarApps.candidates()
    for (title, group) in [("In your menu bar now", candidates.inBarNow),
                           ("Seen in your menu bar before", candidates.seenBefore)] {
        print("\n\(title):")
        if group.isEmpty { print("  (none)") }
        for app in group {
            let icon = MenuBarApps.icon(for: app.bundleID) == nil ? "  (no icon)" : ""
            print("  \(app.name)  [\(app.bundleID)]\(icon)")
        }
    }
    exit(0)
}

// MARK: - --trydrag

// Works through the delivery strategies in order and reports which, if any,
// actually reorders two of Nook's OWN items. Nothing of the user's is touched.
//
// Our own items are read through AppKit, never through AX. Querying AX against
// your own process needs the accessibility server to call back into your main
// thread, and doing that while AppKit is still laying status items out made the
// items vanish from the bar entirely (measured: present at poll 0, gone by poll
// 4, nothing rendered). AX is for OTHER apps' items.
final class DragMatrix: NSObject, NSApplicationDelegate {
    // Retained deliberately: a status item held only in a local is deallocated
    // when the function returns and its icon disappears from the bar.
    private var itemA: NSStatusItem?
    private var itemB: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard ItemMover.hasAccessibilityPermission else {
            print("Accessibility not granted; run --grant first.")
            exit(1)
        }
        let a = NSStatusBar.system.statusItem(withLength: 26)
        a.button?.title = "A"
        let b = NSStatusBar.system.statusItem(withLength: 26)
        b.button?.title = "B"
        itemA = a
        itemB = b
        waitForPlacement(attempt: 0)
    }

    /// CGEvent coordinates are top-left origin from the primary display; an
    /// NSWindow frame is bottom-left. Only the conversion of the midpoint matters.
    private func eventPoint(_ item: NSStatusItem?) -> CGPoint? {
        guard let frame = item?.button?.window?.frame,
              let primary = NSScreen.screens.first else { return nil }
        return CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
    }

    private func minX(_ item: NSStatusItem?) -> CGFloat? {
        item?.button?.window?.frame.minX
    }

    private func waitForPlacement(attempt: Int) {
        // A status item reports a placeholder position until AppKit lays it out.
        if let a = minX(itemA), let b = minX(itemB), a > 100, b > 100 {
            return run()
        }
        guard attempt < 20 else {
            print("FAIL: our items never reached a real position (A=\(minX(itemA) ?? -1), B=\(minX(itemB) ?? -1))")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForPlacement(attempt: attempt + 1)
        }
    }

    private func run() {
        var strategies: [ItemMover.Strategy] = [
            .init(target: .hidTap, shape: .warpDrag),
            .init(target: .hidTap, shape: .warpDrag, realCommandKey: true),
            .init(target: .sessionTap, shape: .warpDrag),
        ]
        print(String(format: "start: A at %.0f, B at %.0f", minX(itemA) ?? -1, minX(itemB) ?? -1))

        for strategy in strategies {
            // Whichever is currently on the right gets asked to move left of the other.
            let aIsRight = (minX(itemA) ?? 0) > (minX(itemB) ?? 0)
            let mover = aIsRight ? itemA : itemB
            let anchor = aIsRight ? itemB : itemA
            guard let from = eventPoint(mover), let anchorFrame = anchor?.button?.window?.frame,
                  let primary = NSScreen.screens.first else { continue }
            let before = minX(mover) ?? 0
            let to = CGPoint(x: anchorFrame.minX - 1, y: primary.frame.maxY - anchorFrame.midY)

            ItemMover.performDrag(from: from, to: to, strategy: strategy)
            Thread.sleep(forTimeInterval: 0.6)

            let after = minX(mover) ?? before
            let moved = abs(after - before) > 4
            print(String(format: "%-24@ %.0f -> %.0f  %@", strategy.description as NSString,
                         before, after, moved ? "MOVED" : "no change"))
            if moved {
                print("\nWORKING STRATEGY: \(strategy)")
                exit(0)
            }
        }
        print("\nNo strategy moved an item; synthetic cmd-drag does not reorder items here.")
        exit(1)
    }
}

if arguments.contains("--trydrag") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let matrix = DragMatrix()
    app.delegate = matrix
    app.run()
}

// MARK: - --tryclick

// Discriminator: does a synthetic mouse event reach the menu bar at all on this
// OS? Clicks JustHide's own item and reports whether its action fired. If a plain
// click works but a cmd-drag does not, the problem is the drag. If neither
// works, posted events do not reach the bar and no Accessibility-based mover can.
final class ClickTest: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var fired = false

    @objc private func clicked() {
        fired = true
        print("ACTION FIRED: the synthetic click reached the item.")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: 30)
        statusItem.button?.title = "C"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        item = statusItem
        waitThenClick(attempt: 0)
    }

    private func waitThenClick(attempt: Int) {
        guard let frame = item?.button?.window?.frame, frame.minX > 100,
              let primary = NSScreen.screens.first else {
            guard attempt < 20 else { print("FAIL: item never placed"); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.waitThenClick(attempt: attempt + 1)
            }
            return
        }
        let point = CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        print(String(format: "clicking own item at %.0f,%.0f", point.x, point.y))

        guard let source = CGEventSource(stateID: .hidSystemState) else { exit(1) }
        let restore = NSEvent.mouseLocation
        // With --cmd the click carries Command. A cmd-click on a status item is
        // the gesture that PICKS IT UP rather than activating it, so if the
        // action still fires, the bar is not seeing our modifier.
        let withCommand = CommandLine.arguments.contains("--cmd")
        print(withCommand ? "clicking WITH command" : "clicking without command")
        CGWarpMouseCursorPosition(point)
        Thread.sleep(forTimeInterval: 0.1)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let event = CGEvent(mouseEventSource: source, mouseType: type,
                                   mouseCursorPosition: point, mouseButton: .left) {
                event.flags = withCommand ? .maskCommand : []
                event.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        CGWarpMouseCursorPosition(CGPoint(x: restore.x, y: primary.frame.maxY - restore.y))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.fired {
                print("NO ACTION: synthetic clicks do not reach the menu bar.")
            }
            exit(self.fired ? 0 : 1)
        }
    }
}

if arguments.contains("--tryclick") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let test = ClickTest()
    app.delegate = test
    app.run()
}

// MARK: - --tryassert

// Holds an assessment-mode assertion that conceals the named bundle IDs, and
// keeps JustHide's own item on screen to see whether a locally-signed build can
// allowlist itself. Reveals again on exit.
//
//   Nook --tryassert com.example.one com.example.two
final class AssertTest: NSObject, NSApplicationDelegate {
    private var marker: NSStatusItem?
    private var token: AssessmentMode.Token?

    func applicationDidFinishLaunching(_ note: Notification) {
        print("assessment mode available: \(AssessmentMode.isAvailable)")
        guard AssessmentMode.isAvailable else { exit(1) }

        let item = NSStatusBar.system.statusItem(withLength: 30)
        item.button?.title = "N"
        marker = item

        let targets = Set(CommandLine.arguments.dropFirst().filter { $0.contains(".") })
        guard !targets.isEmpty else {
            print("give one or more bundle identifiers to conceal")
            exit(1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AssessmentMode.conceal(allowing: AssessmentMode.allowlist(excluding: targets)) { result in
                switch result {
                case let .success(token):
                    self.token = token
                    print("CONCEALED. JustHide's own item is \(self.marker?.button?.window?.frame.minX ?? -1) (x)")
                    print("holding for 12s, then revealing...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                        token.invalidate()
                        print("REVEALED (assertion invalidated)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
                    }
                case let .failure(error):
                    print("FAILED: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
    }
}

if arguments.contains("--tryassert") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let test = AssertTest()
    app.delegate = test
    app.run()
}

// MARK: - --grant

// Prompts for Accessibility and then WAITS, polling until it is granted. Exiting
// straight after prompting can take the system dialog down with it.
if arguments.contains("--grant") {
    if ItemMover.hasAccessibilityPermission {
        print("Accessibility is already granted.")
        exit(0)
    }
    print("Requesting Accessibility for JustHide...")
    print("Approve the dialog, or enable Nook in System Settings > Privacy & Security > Accessibility.")
    ItemMover.requestAccessibilityPermission()
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
        if ItemMover.hasAccessibilityPermission {
            print("GRANTED.")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 1)
    }
    print("Timed out waiting for the grant.")
    exit(1)
}

// MARK: - --selftest

// Runs inside a real app session because it needs status items of its own.
final class SelfTest: NSObject, NSApplicationDelegate {
    private var left: NSStatusItem?
    private var right: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard ItemMover.hasAccessibilityPermission else {
            print("Accessibility permission is NOT granted.")
            print("Grant it to Nook in System Settings > Privacy & Security > Accessibility,")
            print("then run --selftest again. Prompting now...")
            ItemMover.requestAccessibilityPermission()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
            return
        }

        // Two of our own items: A created first sits to the RIGHT of B.
        let a = NSStatusBar.system.statusItem(withLength: 26)
        a.button?.title = "A"
        let b = NSStatusBar.system.statusItem(withLength: 26)
        b.button?.title = "B"
        right = a
        left = b

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        // Our own two items, found through the same AX route the app uses for
        // everyone else's. Titled A and B so the log is readable.
        let mine = AXMenuBar.items(forPID: getpid()).sorted { $0.frame.minX < $1.frame.minX }
        print("JustHide's own items visible via AX: \(mine.count)")
        for item in mine {
            print(String(format: "  x %.0f..%.0f  %@", item.frame.minX, item.frame.maxX, item.title ?? "(untitled)"))
        }
        guard mine.count >= 2 else {
            print("FAIL: need two of our own items to test with; a full menu bar can")
            print("      refuse placement of new items entirely.")
            exit(1)
        }
        let leftItem = mine[0]
        let rightItem = mine[mine.count - 1]
        print(String(format: "before: left at %.0f, right at %.0f", leftItem.frame.minX, rightItem.frame.minX))

        // Ask for the right-hand one to go to the left of the left-hand one:
        // an unambiguous order flip, easy to verify.
        let moved = ItemMover.move(rightItem, to: .leftOf(leftItem))

        guard let newRight = AXMenuBar.currentFrame(of: rightItem.element),
              let newLeft = AXMenuBar.currentFrame(of: leftItem.element) else {
            print("FAIL: items missing after the move.")
            exit(1)
        }
        print(String(format: "after:  moved item at %.0f, other at %.0f", newRight.minX, newLeft.minX))
        let flipped = newRight.minX < newLeft.minX
        print(moved && flipped
              ? "PASS: synthetic cmd-drag reorders status items on macOS 27."
              : "FAIL: the drag did not change the order.")
        exit(moved && flipped ? 0 : 1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if arguments.contains("--selftest") {
    let test = SelfTest()
    app.delegate = test
    app.run()
} else if arguments.contains("--width") {
    // Legacy layout-based mechanism: inflates a divider so items overflow. Works
    // without any private API, at the cost of a gap in the bar and icons sliding
    // on a wider second display.
    let controller = WidthController()
    app.delegate = controller
    app.run()
} else if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != getpid() }) {
    // Opening the app while it is already running -- double-clicking it in
    // Finder, most likely -- used to add a second chevron to the bar, each with
    // its own assertion. Open Settings in the copy that is already there instead.
    DistributedNotificationCenter.default().postNotificationName(
        .justHideShowSettings, object: nil, userInfo: nil, deliverImmediately: true)
    print("JustHide is already running (pid \(running.processIdentifier)); asked it to open Settings.")
    exit(0)
} else {
    let controller = AssertionController()
    app.delegate = controller
    app.run()
}
