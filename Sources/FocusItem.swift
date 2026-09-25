//
//  FocusItem.swift
//  JustHide
//
//  JustHide's own Focus item: the current Focus, with its own symbol.
//
//  Same reason as Now Playing: while any concealment assertion is held, macOS
//  hides its own Focus icon, fixed policy for every unentitled caller. This
//  one lives in JustHide's bundle, which the assertion always allows.
//
//  Where the state comes from, every other source having been tried and
//  refused on 27.0 (2026-09-24): the public Focus Status API reports "not
//  focused" to an app without Apple's communication entitlement; the
//  DoNotDisturb XPC services demand a private entitlement; nothing is
//  broadcast when Focus changes; and Accessibility loses Apple's Focus icon
//  the moment anything is concealed. What is left is macOS's own Focus store
//  on disk, which needs Full Disk Access -- so this item needs it, and says
//  so, rather than guessing without it.
//
//  The symbol is DYNAMIC: each Focus, a user's own included, names its symbol
//  in the store. Several of Apple's are private SF Symbols (Personal is
//  `emoji.face.grinning`), which the public lookup does not find; they load
//  from the private glyph bundle through the public bundle-symbol API.
//
//  A click opens Apple's Focus modes through Control Centre: its menu extra,
//  then its Focus module, both pressed through Accessibility, which works
//  while icons are concealed. There is no public way for an app to switch
//  Focus, so Apple's own controls are the honest version. Apple's dropdown
//  proper is out of reach -- see clicked().
//

import Cocoa

/// A Focus that is on.
struct FocusState: Equatable {
    let identifier: String
    let name: String?
    let symbol: String?
}

enum FocusStore {
    enum Reading: Equatable {
        case unreadable     // no Full Disk Access, or no store
        case off
        case on(FocusState)
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB")
    }

    /// The Focus the store says is on.
    ///
    /// Assertions.json holds the Focuses switched on, each record naming its
    /// mode by identifier; ModeConfigurations.json maps identifiers to the
    /// name and symbol the user sees. Walked generically rather than by fixed
    /// paths: the layout is private, and a shape we did not expect should read
    /// as "off", never crash.
    static func read() -> Reading {
        guard let assertions = json("Assertions.json") else { return .unreadable }
        var records: [[String: Any]] = []
        collect(assertions, key: "storeAssertionRecords", into: &records)
        let active = records
            .compactMap { record -> (id: String, start: Double)? in
                guard let details = record["assertionDetails"] as? [String: Any],
                      let id = details["assertionDetailsModeIdentifier"] as? String
                else { return nil }
                return (id, record["assertionStartDateTimestamp"] as? Double ?? 0)
            }
            .max { $0.start < $1.start }
        guard let modeID = active?.id else { return .off }
        let mode = json("ModeConfigurations.json").flatMap { findMode(modeID, in: $0) }
        return .on(FocusState(identifier: modeID, name: mode?["name"] as? String,
                              symbol: mode?["symbolImageName"] as? String))
    }

    /// The Focus's own symbol, public or private; nil if neither has it.
    static func image(for symbol: String?) -> NSImage? {
        guard let symbol = symbol else { return nil }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { return image }
        guard let bundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")
        else { return nil }
        return NSImage(symbolName: symbol, bundle: bundle, variableValue: 0)
    }

    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func json(_ file: String) -> Any? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Every array stored under `key`, anywhere in the tree, flattened.
    private static func collect(_ node: Any, key: String, into found: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            for (k, value) in dict {
                if k == key, let array = value as? [[String: Any]] { found += array }
                collect(value, key: key, into: &found)
            }
        } else if let array = node as? [Any] {
            array.forEach { collect($0, key: key, into: &found) }
        }
    }

    /// The "mode" dictionary of the configuration keyed by `id`.
    private static func findMode(_ id: String, in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let configuration = dict[id] as? [String: Any] {
                return configuration["mode"] as? [String: Any] ?? configuration
            }
            for value in dict.values {
                if let mode = findMode(id, in: value) { return mode }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let mode = findMode(id, in: value) { return mode }
            }
        }
        return nil
    }
}

final class FocusItem: NSObject {
    static let shared = FocusItem()

    private var item: NSStatusItem?
    private var timer: Timer?
    private(set) var reading: FocusStore.Reading?

    /// Every two seconds while switched on: two small files, and there is no
    /// change notification to wait for instead.
    private static let pollInterval: TimeInterval = 2

    func apply() {
        guard Settings.showsFocus else {
            timer?.invalidate()
            timer = nil
            reading = nil
            remove()
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
        poll(force: true)
    }

    private func poll(force: Bool = false) {
        let now = FocusStore.read()
        guard force || now != reading else { return }
        if now != reading {
            Log.controller.log("Focus: \(Self.describe(now))")
        }
        reading = now
        update()
    }

    private func update() {
        let focus: FocusState?
        switch reading {
        case .on(let state)?: focus = state
        case .off?: focus = nil
        // Without Full Disk Access there is nothing true to show, so nothing
        // is shown; Settings says why.
        case .unreadable?, nil: remove(); return
        }
        guard focus != nil || Settings.focusAppearance == .always else {
            remove()
            return
        }
        let item = self.item ?? create()
        draw(item, focus: focus)
        NotificationCenter.default.post(name: .justHideOwnItemsChanged, object: nil)
    }

    private func create() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        // One autosave name for life, so it returns to the same slot each time
        // it comes back (see NowPlayingItem).
        item.autosaveName = "focus"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        self.item = item
        return item
    }

    private func remove() {
        guard let item = item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        NotificationCenter.default.post(name: .justHideOwnItemsChanged, object: nil)
    }

    private func draw(_ item: NSStatusItem, focus: FocusState?) {
        guard let button = item.button else { return }
        // The Focus's own symbol; a moon when it has none we can load, and an
        // outline moon for "none on" in Always mode.
        let symbol = focus.flatMap { FocusStore.image(for: $0.symbol) }
            ?? NSImage(systemSymbolName: focus == nil ? "moon" : "moon.fill", accessibilityDescription: nil)
        let image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? symbol
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        let name = focus.map { $0.name ?? "A Focus" }
        button.setAccessibilityLabel(name.map { "Focus: \($0)" } ?? "Focus: off")
        button.toolTip = name.map { "\($0) Focus is on" } ?? "No Focus is on"
    }

    /// Opens Apple's Focus modes. Apple's own dropdown can only be had by
    /// pressing Apple's own icon, which is concealed while anything is hidden
    /// and gone altogether once set to "Don't Show" -- and standing the
    /// assertion down to reach it flashes every hidden icon. So it always goes
    /// through Control Centre, which works while concealed: one consistent
    /// oddity (Control Centre shows first, then its Focus modes) rather than
    /// several that depend on settings. Ben's call, 2026-09-25.
    @objc private func clicked() {
        guard AXIsProcessTrusted() else {
            NSSound.beep()
            Log.controller.error("Focus: opening the Focus modes needs Accessibility")
            return
        }
        Self.openThroughControlCentre()
    }

    /// Control Centre, then its Focus module once its window exists.
    static func openThroughControlCentre() {
        guard let controlCentre = menuExtra("com.apple.menuextra.controlcenter") else { return }
        AXUIElementPerformAction(controlCentre, kAXPressAction as CFString)
        pressFocusModule(attempt: 0)
    }

    private static func pressFocusModule(attempt: Int) {
        // Up to three seconds: Control Centre was measured to take 0.8s, but a
        // 1.2s limit still missed once on a busy machine.
        guard attempt < 20 else {
            Log.controller.error("Focus: Control Centre opened but its Focus module was not found")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let module = controlCentreElement(identifier: "module-FocusModes") {
                AXUIElementPerformAction(module, kAXPressAction as CFString)
            } else {
                pressFocusModule(attempt: attempt + 1)
            }
        }
    }

    private static func menuExtra(_ identifier: String) -> AXUIElement? {
        guard let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(agent.processIdentifier),
                                            "AXExtrasMenuBar" as CFString, &value) == .success,
              let bar = value else { return nil }
        return find(identifier, in: bar as! AXUIElement, depth: 3)
    }

    private static func controlCentreElement(identifier: String) -> AXUIElement? {
        guard let cc = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter").first else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(cc.processIdentifier),
                                            kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            // Deep, and only as deep as Control Centre's window goes: the probe
            // that proved this route walked the whole tree.
            if let found = find(identifier, in: window, depth: 16) { return found }
        }
        return nil
    }

    private static func find(_ identifier: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &value) == .success,
           value as? String == identifier { return element }
        guard depth > 0,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let found = find(identifier, in: child, depth: depth - 1) { return found }
        }
        return nil
    }

    private static func describe(_ reading: FocusStore.Reading) -> String {
        switch reading {
        case .unreadable: return "store not readable (Full Disk Access?)"
        case .off: return "off"
        case .on(let state): return "\(state.name ?? "?") (\(state.identifier), symbol \(state.symbol ?? "none"))"
        }
    }
}
