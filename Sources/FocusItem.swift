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
//  Where the state comes from: the unified log. donotdisturbd keeps its
//  state for entitled clients only, the public Focus Status API reports "not
//  focused" to an app without Apple's communication entitlement, nothing is
//  broadcast on a change, and the Focus database needs Full Disk Access --
//  but donotdisturbd narrates every transition to the log at default level,
//  mode name and symbol in the clear, and any user can read that. Found in
//  Pelmet's FocusStatus.swift and verified here (2026-09-25) from a Terminal
//  with no Full Disk Access; it also carries Focuses started by a schedule or
//  an automation, which the database route could miss. One `log stream`
//  child follows it while the option is on, and `log show` reads the last
//  transition at start.
//
//  The symbol is DYNAMIC: each Focus, a user's own included, names its symbol
//  in the log line. Several of Apple's are private SF Symbols (Personal is
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

/// Follows donotdisturbd's transitions in the unified log.
final class FocusLog {
    static let shared = FocusLog()

    /// Called on the main queue with each transition: the Focus now on, or nil.
    var onChange: ((FocusState?) -> Void)?

    private var stream: Process?
    private var wanted = false
    private var restarts = 0
    private var buffer = Data()
    private var terminationObserver: NSObjectProtocol?

    private static let predicate = #"process == "donotdisturbd" AND category == "ServiceProvider" "#
        + #"AND eventMessage BEGINSWITH "Did receive state update""#

    func start() {
        guard !wanted else { return }
        wanted = true
        restarts = 0
        Self.reapOrphans()
        // A Process outlives its parent, so the stream goes when we do.
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.stop() }
        }
        readLast()
        startStream()
    }

    func stop() {
        wanted = false
        stream?.terminationHandler = nil
        stream?.terminate()
        stream = nil
    }

    /// The most recent transition, so a Focus already on at launch shows. A
    /// week back: a Focus left on longer than that with no transition at all
    /// reads as off until the next one, which is a fair trade for not
    /// scanning the whole log.
    private func readLast() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = Self.run("/usr/bin/log", ["show", "--last", "7d", "--style", "compact",
                                                   "--predicate", Self.predicate])
            let last = output.split(separator: "\n").last { Self.isTransition(String($0)) }
            let state = last.map { Self.parse(String($0)) } ?? nil
            DispatchQueue.main.async {
                // A stream line may have landed first; it is newer.
                guard let self = self, self.wanted, !self.sawStreamLine else { return }
                self.onChange?(state)
            }
        }
    }

    private var sawStreamLine = false

    private func startStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.received(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.streamEnded() }
        }
        do {
            try process.run()
            stream = process
        } catch {
            Log.controller.error("Focus: could not start log stream: \(error.localizedDescription)")
        }
    }

    /// Restarted a few times with a growing pause, then left alone.
    private func streamEnded() {
        stream = nil
        guard wanted, restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts * 2)) { [weak self] in
            guard let self = self, self.wanted, self.stream == nil else { return }
            self.startStream()
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard Self.isTransition(line) else { continue }
            sawStreamLine = true
            onChange?(Self.parse(line))
        }
    }

    /// A real transition, from donotdisturbd itself. `log stream` opens with
    /// a header that quotes the predicate -- "Did receive state update" and
    /// all -- which was read as a transition with no mode, i.e. "off", and
    /// then outranked the true state from `log show` (seen 2026-09-25).
    private static func isTransition(_ line: String) -> Bool {
        line.contains("donotdisturbd[") && line.contains("Did receive state update")
    }

    /// One transition line. It describes the new state AND the previous one,
    /// so only the part before "previousState:" is read. Off is
    /// `activeModeIdentifier: (null)`; on names the mode, e.g.
    /// `mode: <DNDMode ...; name: Work; modeIdentifier: com.apple.focus.work;
    /// symbolImageName: building.2.fill; ...>`.
    static func parse(_ line: String) -> FocusState? {
        let state = line.components(separatedBy: "previousState:").first ?? line
        guard let identifier = capture(#"activeModeIdentifier: ([^>;\s]+)"#, in: state),
              identifier != "(null)" else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        let name = capture(#"name: ([^;]*); modeIdentifier: "# + escaped + ";", in: state)
        let symbol = capture(#"modeIdentifier: "# + escaped + #"; symbolImageName: ([^;]*);"#, in: state)
        return FocusState(identifier: identifier, name: name,
                          symbol: symbol == "(null)" ? nil : symbol)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// A stream left behind by a copy of JustHide that crashed: re-parented
    /// to launchd, still running our predicate. Ours are recognised by both.
    private static func reapOrphans() {
        let listing = run("/bin/ps", ["-Ao", "pid=,ppid=,command="])
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1",
                  fields[2].hasPrefix("/usr/bin/log stream"), fields[2].contains("donotdisturbd"),
                  let pid = Int32(fields[0]) else { continue }
            kill(pid, SIGTERM)
            Log.controller.log("Focus: stopped a log stream left behind by an earlier run")
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !errorData.isEmpty {
            Log.controller.error("Focus: \(path) exited \(process.terminationStatus): \(String(decoding: errorData.prefix(300), as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum FocusSymbol {
    /// The Focus's own symbol, public or private; nil if neither has it.
    static func image(for symbol: String?) -> NSImage? {
        guard let symbol = symbol else { return nil }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) { return image }
        guard let bundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle")
        else { return nil }
        return NSImage(symbolName: symbol, bundle: bundle, variableValue: 0)
    }
}

final class FocusItem: NSObject {
    static let shared = FocusItem()

    private var item: NSStatusItem?
    /// The Focus on now, or nil; known once the log has been read.
    private var focus: FocusState?
    private var known = false

    func apply() {
        guard Settings.showsFocus else {
            FocusLog.shared.stop()
            known = false
            focus = nil
            remove()
            return
        }
        FocusLog.shared.onChange = { [weak self] state in
            guard let self = self else { return }
            if !self.known || state != self.focus {
                Log.controller.log("Focus: \(state.map { "\($0.name ?? "?") (\($0.identifier), symbol \($0.symbol ?? "none"))" } ?? "off")")
            }
            self.known = true
            self.focus = state
            self.update()
        }
        FocusLog.shared.start()
        if known { update() }
    }

    private func update() {
        guard Settings.showsFocus, known,
              focus != nil || Settings.focusAppearance == .always else {
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
        let symbol = focus.flatMap { FocusSymbol.image(for: $0.symbol) }
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
}
