//
//  MenuBarItems.swift
//  JustHide — a minimal menu bar hider for macOS 27
//
//  Enumerating what is actually in the menu bar.
//
//  macOS has no API for "the menu bar items", but every status item is a real
//  window, and CGWindowListCopyWindowInfo reports windows with their owner and
//  bounds. Status items sit at window level kCGStatusWindowLevel (25); the menu
//  bar itself is 24. Geometry and owner name come through WITHOUT Screen
//  Recording permission -- only window titles and images are gated, and we need
//  neither.
//

import Cocoa

struct MenuBarItem {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bounds: CGRect
    /// Status items live at this window level; the menu bar itself is one below.
    static let statusWindowLevel = Int(CGWindowLevelForKey(.statusWindow))

    var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }

    /// Stable enough to persist a hidden-section membership against: window IDs
    /// are recycled per launch, so identity is the owning app plus where it sits
    /// relative to its own app's other items.
    var persistentKey: String {
        "\(bundleIdentifier ?? ownerName)"
    }
}

enum MenuBarItemLister {
    /// Every status item currently on screen, ordered left to right.
    static func currentItems() -> [MenuBarItem] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info -> MenuBarItem? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == MenuBarItem.statusWindowLevel,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
            return MenuBarItem(windowID: windowID, ownerPID: pid, ownerName: owner, bounds: bounds)
        }
        .sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// Items grouped by the display whose menu bar they are on. Status items are
    /// laid out on one display and mirrored onto the others, so this is expected
    /// to report a single display; it exists to make that visible rather than
    /// assumed.
    static func itemsByDisplay() -> [(screen: NSScreen?, items: [MenuBarItem])] {
        let items = currentItems()
        let screens = NSScreen.screens
        var grouped: [(NSScreen?, [MenuBarItem])] = []
        for screen in screens {
            // CGWindow bounds are top-left origin; NSScreen is bottom-left. Match
            // on x alone, which is enough to attribute an item to a display.
            let onScreen = items.filter { item in
                item.bounds.midX >= screen.frame.minX && item.bounds.midX <= screen.frame.maxX
            }
            if !onScreen.isEmpty { grouped.append((screen, onScreen)) }
        }
        let attributed = Set(grouped.flatMap { $0.1 }.map { $0.windowID })
        let orphans = items.filter { !attributed.contains($0.windowID) }
        if !orphans.isEmpty { grouped.append((nil, orphans)) }
        return grouped.map { (screen: $0.0, items: $0.1) }
    }
}
