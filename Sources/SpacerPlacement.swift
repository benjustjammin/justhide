//
//  SpacerPlacement.swift
//  JustHide
//
//  Where the spacers are, and putting them where they need to be.
//
//  A spacer's width only does work in the zone strictly between the divider and
//  the chevron:
//
//      [icons to hide]  divider |<-- push zone -->| chevron  [always visible]
//
//  Left of the divider it is inside the hidden section, so the OS overflows it
//  along with the icons and its width is lost. Right of the chevron the OS
//  overflows the chevron and the user's visible icons before it reaches the
//  hidden section -- which costs the user the control they need to get their
//  icons back.
//
//  macOS owns placement: writing "NSStatusItem Preferred Position" is ignored for
//  items it has not placed itself (measured: a spacer seeded to 474, bracketed by
//  468 and 500, was placed outside the bracket anyway). A cmd-drag IS honoured,
//  so tidy() performs one.
//

import Cocoa

enum SpacerPlacement {
    /// Our own status items, as seen through Accessibility -- the only route
    /// that reports menu bar items on macOS 27. Matched on x, because an AX frame
    /// is top-left origin while an NSWindow frame is bottom-left, and x is the
    /// only axis that needs to agree.
    static func axItem(for statusItem: NSStatusItem) -> AXMenuBarItem? {
        guard let frame = statusItem.button?.window?.frame else { return nil }
        return AXMenuBar.items(forPID: getpid())
            .min { abs($0.frame.minX - frame.minX) < abs($1.frame.minX - frame.minX) }
            .flatMap { abs($0.frame.minX - frame.minX) <= 8 ? $0 : nil }
    }

    /// Spacers genuinely sitting in the push zone, nearest the chevron first --
    /// on a narrow bar those are the ones the OS keeps longest.
    ///
    /// Must be read while the spacers are deflated: an inflated item that has
    /// been ejected reports coordinates running past its neighbours.
    static func spacersInPushZone(spacers: [NSStatusItem],
                                  divider: NSStatusItem,
                                  chevron: NSStatusItem) -> [NSStatusItem] {
        guard let dividerFrame = divider.button?.window?.frame,
              let chevronFrame = chevron.button?.window?.frame else { return [] }
        return spacers.filter { spacer in
            guard let frame = spacer.button?.window?.frame else { return false }
            return frame.minX >= dividerFrame.maxX - 2 && frame.maxX <= chevronFrame.minX + 2
        }
        .sorted { ($0.button?.window?.frame.minX ?? 0) > ($1.button?.window?.frame.minX ?? 0) }
    }

    /// Gap between the divider's right edge and the chevron. Constant while the
    /// divider is laid out however long it gets; tracks the requested length once
    /// it has been ejected.
    static func dividerToChevronGap(divider: NSStatusItem, chevron: NSStatusItem) -> CGFloat? {
        guard let dividerFrame = divider.button?.window?.frame,
              let chevronFrame = chevron.button?.window?.frame else { return nil }
        return dividerFrame.maxX - chevronFrame.minX
    }

    /// macOS parks an unplaced status window off the menubar row, so the
    /// chevron's own frame says whether it survived a collapse.
    static func chevronIsOnMenuBarRow(_ chevron: NSStatusItem) -> Bool {
        guard let primary = NSScreen.screens.first,
              let frame = chevron.button?.window?.frame else { return false }
        return frame.minY >= primary.frame.maxY - 60
    }

    /// Drags every spacer into the push zone. Call with the bar EXPANDED, off the
    /// main thread (the drag sleeps between synthetic events).
    static func tidy(spacers: [NSStatusItem], divider: NSStatusItem, chevron: NSStatusItem) {
        guard ItemMover.hasAccessibilityPermission else {
            Log.sections.error("cannot tidy spacers without Accessibility permission")
            return
        }
        for (index, spacer) in spacers.enumerated() {
            guard let item = axItem(for: spacer),
                  let chevronItem = axItem(for: chevron) else {
                Log.sections.error("spacer \(index) or the chevron is not visible via AX; skipping")
                continue
            }
            // Left of the chevron puts it in the zone; doing them in order walks
            // the group into place one at a time.
            let moved = ItemMover.move(item, to: .leftOf(chevronItem))
            Log.sections.log("spacer \(index) \(moved ? "placed" : "could not be placed")")
        }
        let placed = spacersInPushZone(spacers: spacers, divider: divider, chevron: chevron).count
        Log.sections.log("tidy finished: \(placed) of \(spacers.count) spacers in the push zone")
    }
}
