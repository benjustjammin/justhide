//
//  MenuBarItemShortcuts.swift
//  JustHide
//
//  Opening a hidden app's menu from the keyboard, without showing its icon.
//
//  Hiding an icon normally costs you access to it: to use the thing you have to
//  bring it back first. It turns out not to have to. Measured on 27.0 (26A428):
//  `AXUIElementPerformAction(item, kAXPressAction)` opens another app's status
//  item -- and it works on an item that is CONCEALED by an assessment-mode
//  assertion, with nothing revealed and no flicker. Verified on both kinds of
//  item: iStat Menus, whose readouts are panels, and Clop, whose item is a
//  classic NSMenu, both while hidden.
//
//  That is the opposite of MOVING an item, which stays blocked (see
//  AXMenuBarItems). And it does not extend to macOS's OWN items: while an
//  assertion is held the clock does not answer a press, which is assessment
//  mode's doing rather than Accessibility's, and is what the clock option in
//  Settings exists to work around.
//
//  Three measured details shape everything below:
//
//  1. THE RETURN CODE LIES. Clop's press returned -25204 (kAXErrorCannotComplete)
//     and opened the menu anyway; a later press on the same item returned 0.
//     Most likely the modal menu tracking loop stops the call acknowledging.
//     Nothing here branches on it.
//  2. PRESSING AGAIN DOES NOT CLOSE an NSMenu-style item. iStat's panel toggles
//     shut, Clop's menu stays up. So "off" is Escape, not a second press.
//  3. AN OPEN ITEM IS VISIBLE IN THE WINDOW LIST, which is how this tells the
//     two cases apart: while open, the owning app has a window at layer >= 20
//     (iStat's panel 24, Clop's menu 101); closed, it has none. Ordinary app
//     windows sit at layer 0, so the test does not catch those.
//

import Cocoa
import ApplicationServices
import Carbon.HIToolbox

/// One status item, as far as a shortcut is concerned.
struct MenuBarItemRef: Equatable {
    let bundleID: String
    /// Whatever the app publishes that tells this item from its siblings, from
    /// the first of `AXIdentifier`, `AXDescription`, `AXHelp`, `AXTitle` that is
    /// not empty. Apps differ wildly in which one they fill in:
    ///   - iStat Menus: AXIdentifier "com.bjango.istatmenus.memory" and friends
    ///   - Vorssaint:   AXHelp only -- "CPU", "GPU" -- everything else blank
    ///   - Clop:        AXTitle "MenubarIconClassic", one item only
    /// nil means the app publishes nothing at all, and its items cannot be told
    /// apart except by position, which is not usable (see the note below).
    let identity: String?
    /// What to call it in the list.
    let label: String
}

/// What a shortcut points at.
///
/// Two cases rather than one because most apps own a single item and never name
/// it, and refusing those a shortcut would rule out most of the menu bar. An
/// app with SEVERAL items has to name them: there is no other way to say which
/// one is meant, and the obvious fallback -- remember the position -- is a trap.
/// The AX children come back in an order that is not the on-screen order (iStat
/// returned memory, cpu, disks while the bar reads memory, disks, cpu), so an
/// index would quietly drift onto the wrong readout.
enum MenuBarItemTarget: Hashable {
    /// The app's only item, whatever it turns out to be called.
    case onlyItem(bundleID: String)
    /// One named item belonging to an app that owns several.
    case item(bundleID: String, identity: String)

    var bundleID: String {
        switch self {
        case let .onlyItem(bundleID): return bundleID
        case let .item(bundleID, _): return bundleID
        }
    }

    /// A bundle identifier cannot contain "#", so it is safe as a separator.
    var storageKey: String {
        switch self {
        case let .onlyItem(bundleID): return bundleID
        case let .item(bundleID, identity): return "\(bundleID)#\(identity)"
        }
    }

    init(storageKey: String) {
        let parts = storageKey.split(separator: "#", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            self = .item(bundleID: parts[0], identity: parts[1])
        } else {
            self = .onlyItem(bundleID: storageKey)
        }
    }
}

// MARK: - Finding out what an app owns

enum MenuBarItemCatalogue {
    private static let knownKey = "knownMenuBarItems"

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = copy(element, kAXPositionAttribute),
              let sizeRef = copy(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Every status item one app exposes, left to right.
    ///
    /// Two levels, because one is not enough: some apps hang their items
    /// directly off AXExtrasMenuBar (Clop, iStat) while others wrap each one in
    /// an AXGroup with the AXHostingView subrole and put the real item inside
    /// (MenuBarAgent does this with the clock). Enumerating only the top level
    /// silently misses the second kind.
    static func discover(bundleID: String) -> [MenuBarItemRef] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }), app.processIdentifier > 0 else { return [] }

        guard let extrasRef = copy(AXUIElementCreateApplication(app.processIdentifier),
                                   "AXExtrasMenuBar"),
              CFGetTypeID(extrasRef) == AXUIElementGetTypeID(),
              let children = copy(extrasRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return [] }

        let appName = app.localizedName ?? bundleID
        var found: [(ref: MenuBarItemRef, x: CGFloat)] = []

        for child in children {
            // A hosting group has no identity of its own; the item inside it has.
            let candidates: [AXUIElement]
            if naming(of: child).isEmpty {
                candidates = (copy(child, kAXChildrenAttribute) as? [AXUIElement]) ?? [child]
            } else {
                candidates = [child]
            }

            for candidate in candidates {
                let names = naming(of: candidate)
                let x = frame(of: candidate)?.minX ?? frame(of: child)?.minX ?? 0
                found.append((MenuBarItemRef(bundleID: bundleID,
                                             identity: names.first,
                                             label: labelFrom(names) ?? appName),
                              x))
            }
        }
        return found.sorted { $0.x < $1.x }.map(\.ref)
    }

    /// Every attribute worth reading, most identifying first. Kept as one list
    /// so discovery and pressing agree about what counts as a name.
    static let namingAttributes = ["AXIdentifier", kAXDescriptionAttribute,
                                   kAXHelpAttribute, kAXTitleAttribute]

    /// The non-empty names this element publishes, in preference order.
    private static func naming(of element: AXUIElement) -> [String] {
        namingAttributes.compactMap { attribute in
            guard let value = copy(element, attribute) as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    /// A human label, preferring something written for a person to read over an
    /// identifier written for a machine.
    private static func labelFrom(_ names: [String]) -> String? {
        let readable = names.filter { !$0.contains(".") || $0.contains(" ") }
        return readable.first ?? names.first
    }

    /// What this app owned the last time anyone looked. An app that is not
    /// running exposes nothing at all, and a shortcut should not vanish from
    /// Settings just because the app is closed.
    static func remembered(bundleID: String) -> [MenuBarItemRef] {
        guard let store = UserDefaults.standard.dictionary(forKey: knownKey),
              let entries = store[bundleID] as? [[String: String]] else { return [] }
        return entries.map {
            MenuBarItemRef(bundleID: bundleID,
                           identity: $0["id"],
                           label: $0["label"] ?? bundleID)
        }
    }

    static func remember(_ items: [MenuBarItemRef], for bundleID: String) {
        guard !items.isEmpty else { return }
        var store = UserDefaults.standard.dictionary(forKey: knownKey) ?? [:]
        store[bundleID] = items.map { item -> [String: String] in
            var entry = ["label": item.label]
            if let identity = item.identity { entry["id"] = identity }
            return entry
        }
        UserDefaults.standard.set(store, forKey: knownKey)
    }

    /// The list Settings shows: what is there now if the app is running and
    /// Accessibility is granted, otherwise what was there last time.
    static func items(for bundleID: String) -> [MenuBarItemRef] {
        let live = discover(bundleID: bundleID)
        if !live.isEmpty {
            remember(live, for: bundleID)
            return live
        }
        return remembered(bundleID: bundleID)
    }

    /// Whether this app is running right now, which is what decides if a
    /// shortcut can do anything.
    static func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

// MARK: - Pressing one

enum MenuBarItemPress {
    /// Opens the item, or closes it if it is already open.
    ///
    /// Returns false when there was nothing to press -- the app is not running,
    /// Accessibility is missing, or the named item is gone -- so a shortcut can
    /// say so rather than appearing to do nothing.
    @discardableResult
    static func toggle(_ target: MenuBarItemTarget) -> Bool {
        guard AXIsProcessTrusted() else {
            Log.controller.error("shortcut ignored: Accessibility is needed to press a menu bar item")
            return false
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == target.bundleID
        }), app.processIdentifier > 0 else {
            Log.controller.log("shortcut ignored: \(target.bundleID) is not running")
            return false
        }

        // Closing first, because a second press would not do it (Clop's menu
        // stayed open through one) and because the element cannot be pressed
        // while its own menu is tracking anyway.
        if isShowing(pid: app.processIdentifier) {
            sendEscape()
            Log.controller.log("closed \(target.bundleID)")
            return true
        }

        guard let element = element(for: target, pid: app.processIdentifier) else {
            Log.controller.log("shortcut ignored: no matching item in \(target.bundleID)")
            return false
        }
        // The result is deliberately discarded: it is not a reliable signal
        // (see the note at the top of this file).
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        Log.controller.log("pressed \(target.storageKey)")
        return true
    }

    /// Measured on 27.0: an open status item panel or menu is a window owned by
    /// that app at layer 20 or above (iStat's panel 24, Clop's menu 101), and
    /// there is none while it is closed. Only the owner and the layer are read;
    /// window NAMES are the part that would need Screen Recording.
    static func isShowing(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = window[kCGWindowLayer as String] as? Int else { return false }
            return layer >= 20
        }
    }

    private static func element(for target: MenuBarItemTarget, pid: pid_t) -> AXUIElement? {
        guard let extrasRef = copy(AXUIElementCreateApplication(pid), "AXExtrasMenuBar"),
              CFGetTypeID(extrasRef) == AXUIElementGetTypeID(),
              let children = copy(extrasRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        // Both levels again, for the same reason as discovery. Searching by
        // identifier can look anywhere, since only one element will match.
        var everything: [AXUIElement] = []
        // Counting, though, has to avoid seeing a wrapper and the item inside it
        // as two items. Measured: a hosting group advertises no actions at all,
        // so this makes no difference today -- but an app that pressed on both
        // levels would otherwise look ambiguous and be refused.
        var candidates: [AXUIElement] = []
        for child in children {
            everything.append(child)
            let grandchildren = (copy(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            everything.append(contentsOf: grandchildren)
            let pressableInside = grandchildren.filter { canPress($0) }
            candidates.append(contentsOf: pressableInside.isEmpty ? [child] : pressableInside)
        }

        switch target {
        case .onlyItem:
            // Only when there really is one. If the app has grown a second item
            // since the shortcut was set, pressing a guess would be worse than
            // doing nothing and saying so.
            let pressable = candidates.filter { canPress($0) }
            guard pressable.count == 1 else {
                if pressable.count > 1 {
                    Log.controller.log("\(target.bundleID) now owns \(pressable.count) items; "
                                       + "the shortcut no longer says which one it meant")
                }
                return nil
            }
            return pressable[0]
        case let .item(_, identity):
            // Matched against ANY of the naming attributes rather than the one
            // it happened to come from, so a stored key keeps working whichever
            // attribute the app fills in.
            return everything.first { element in
                MenuBarItemCatalogue.namingAttributes.contains { attribute in
                    copy(element, attribute) as? String == identity
                }
            }
        }
    }

    private static func canPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return false }
        return names.contains(kAXPressAction as String)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// Escape rather than a second press: measured, a press does not dismiss a
    /// menu that is already tracking.
    private static func sendEscape() {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}

extension GlobalHotkey {
    /// Registers every item shortcut the user has set. Called wherever the
    /// show/hide shortcut is applied, so a settings change rebuilds both.
    func applyItemShortcuts() {
        Settings.pruneItemShortcuts()
        let bindings = Settings.itemShortcuts.map { target, shortcut in
            (target: target, shortcut: shortcut, action: {
                // A beep rather than nothing when there is nothing to press:
                // the app has been quit, or Accessibility was revoked. Silence
                // would look like a broken shortcut.
                if !MenuBarItemPress.toggle(target) { NSSound.beep() }
            })
        }
        updateItemShortcuts(bindings)
    }
}

// MARK: - Storage

extension Settings {
    private static let itemShortcutsKey = "itemShortcuts"

    /// Shortcuts that open one menu bar item, keyed by what they point at.
    ///
    /// Kept apart from the show/hide shortcut, which is a single fixed pair of
    /// defaults keys and means something different.
    static var itemShortcuts: [MenuBarItemTarget: Shortcut] {
        get {
            guard let store = UserDefaults.standard.dictionary(forKey: itemShortcutsKey)
            else { return [:] }
            var result: [MenuBarItemTarget: Shortcut] = [:]
            for (key, value) in store {
                guard let pair = value as? [Int], pair.count == 2, pair[1] != 0 else { continue }
                result[MenuBarItemTarget(storageKey: key)] = Shortcut(keyCode: pair[0],
                                                                      modifierFlags: UInt(pair[1]))
            }
            return result
        }
        set {
            let store = newValue.reduce(into: [String: [Int]]()) { store, entry in
                store[entry.key.storageKey] = [entry.value.keyCode, Int(entry.value.modifierFlags)]
            }
            UserDefaults.standard.set(store, forKey: itemShortcutsKey)
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    /// Drops shortcuts pointing at apps that are no longer in the list.
    ///
    /// Without this, taking an app out of the list leaves its shortcut stored
    /// and REGISTERED while no row anywhere shows it -- an invisible global
    /// hotkey the user cannot see or remove, holding a combination against
    /// every other app. Found the hard way: Ben removed AlDente and ⌃⌥⇧⌘B
    /// stayed live with nothing in Settings to clear it.
    ///
    /// Writes only when something actually changed, so calling it from a
    /// settings-changed handler cannot loop.
    @discardableResult
    static func pruneItemShortcuts() -> [Shortcut] {
        let kept = listedBundleIDs
        let all = itemShortcuts
        let orphans = all.filter { !kept.contains($0.key.bundleID) }
        guard !orphans.isEmpty else { return [] }
        itemShortcuts = all.filter { kept.contains($0.key.bundleID) }
        Log.controller.log("dropped \(orphans.count) shortcut(s) for apps no longer listed")
        return Array(orphans.values)
    }

    /// How a shortcut reads, e.g. "⌥⌘R".
    static func description(of shortcut: Shortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
        var text = ""
        if flags.contains(.control) { text += "\u{2303}" }
        if flags.contains(.option) { text += "\u{2325}" }
        if flags.contains(.shift) { text += "\u{21E7}" }
        if flags.contains(.command) { text += "\u{2318}" }
        return text + (KeyNames.name(for: shortcut.keyCode) ?? "?")
    }
}
