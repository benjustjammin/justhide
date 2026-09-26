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
//  A click opens JustHide's own menu of Focus modes, under its own icon, with
//  nothing revealed and nothing else opening first. The modes come from the
//  Focus database, which needs Full Disk Access; switching goes through one
//  shortcut, "JustHide Focus", that JustHide adds to Shortcuts once (see
//  FocusShortcut and tools/make-focus-shortcut.py). No app can switch Focus
//  itself: the Focus service rejects every caller without Apple's
//  entitlement, even one run inside Apple's own perl (measured on 27.2).
//  This replaced opening the modes through Control Centre, which flashed
//  Control Centre first and reopened on a second click (issue #1).
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
        FocusShortcut.refresh {
            let modes = FocusModes.read()
            Log.controller.log("Focus: \(modes.map { "\($0.count) modes: " + $0.map(\.name).joined(separator: ", ") } ?? "no Full Disk Access", privacy: .public); shortcut \(FocusShortcut.isInstalled.map { $0 ? "installed" : "missing" } ?? "unknown", privacy: .public)")
        }
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

    // MARK: - The menu

    /// Our own menu, rebuilt on every click so the modes, the tick and what
    /// is missing are always current.
    @objc private func clicked() {
        guard let item = item else { return }
        FocusShortcut.refresh()
        item.menu = menu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let modes = FocusModes.read()
        let active = focus?.identifier
        var listed = modes ?? []
        // Without the database the Focus that is on is still known from the
        // log, so it can at least be turned off.
        if let focus = focus, !listed.contains(where: { $0.identifier == focus.identifier }) {
            listed.insert(FocusModes.Mode(identifier: focus.identifier,
                                          name: focus.name ?? "Focus", symbol: focus.symbol), at: 0)
        }
        for mode in listed {
            let row = NSMenuItem(title: mode.name, action: #selector(modeChosen(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = mode
            row.state = mode.identifier == active ? .on : .off
            row.attributedTitle = Self.title(mode.name, symbol: FocusSymbol.image(for: mode.symbol)
                                             ?? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil))
            menu.addItem(row)
        }
        if !listed.isEmpty { menu.addItem(.separator()) }

        if modes == nil {
            menu.addItem(action("Allow Full Disk Access to List Your Focuses\u{2026}",
                                #selector(openFullDiskAccess)))
        }
        if FocusShortcut.isInstalled == false {
            menu.addItem(action("Add the JustHide Focus Shortcut\u{2026}", #selector(addShortcut)))
        }
        menu.addItem(action("Focus Settings\u{2026}", #selector(openFocusSettings)))
        return menu
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        row.target = self
        return row
    }

    /// macOS 27 does not draw NSMenuItem.image, so the symbol goes into the
    /// title as an attachment (see JustHide.menuTitle).
    private static func title(_ text: String, symbol: NSImage?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let symbol = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            // Centred on the text, and a fixed slot so the names line up.
            let size = symbol.size
            attachment.bounds = NSRect(x: (18 - size.width) / 2, y: -3, width: size.width, height: size.height)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: "  "))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }

    @objc private func modeChosen(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? FocusModes.Mode else { return }
        let turnOn = mode.identifier != focus?.identifier
        guard FocusShortcut.isInstalled != false else {
            offerShortcut()
            return
        }
        // The icon follows from the log when the change lands, so nothing is
        // drawn ahead of it here.
        FocusShortcut.set(mode.name, on: turnOn) { [weak self] problem in
            guard let problem = problem else { return }
            if problem == .missing { self?.offerShortcut() } else { NSSound.beep() }
        }
    }

    private func offerShortcut() {
        let alert = NSAlert()
        alert.messageText = "Add the JustHide Focus shortcut?"
        alert.informativeText = "macOS only lets apps switch Focus through Shortcuts, so JustHide "
            + "uses one small shortcut, \u{201C}JustHide Focus\u{201D}, for every mode. Shortcuts "
            + "will ask you to add it. The first time it runs, macOS asks whether JustHide may run "
            + "it; choose Always Allow."
        alert.addButton(withTitle: "Add Shortcut\u{2026}")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { FocusShortcut.install() }
    }

    @objc private func addShortcut() { offerShortcut() }

    @objc private func openFullDiskAccess() { FocusModes.openFullDiskAccessSettings() }

    @objc private func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}


/// Every Focus the user has, from the Focus database. Needs Full Disk Access:
/// ~/Library/DoNotDisturb is protected, and JustHide only ever reads it.
enum FocusModes {
    struct Mode {
        let identifier: String
        let name: String
        let symbol: String?
    }

    private static let path = NSHomeDirectory() + "/Library/DoNotDisturb/DB/ModeConfigurations.json"

    /// Nil when the file cannot be read, which in practice means Full Disk
    /// Access has not been given.
    static func read() -> [Mode]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // Walked generically for anything that looks like a mode -- a name, an
        // identifier -- rather than tied to one layout of a private file.
        var found: [String: Mode] = [:]
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let identifier = dict["modeIdentifier"] as? String, let name = dict["name"] as? String,
                   !name.isEmpty, found[identifier] == nil {
                    found[identifier] = Mode(identifier: identifier, name: name,
                                             symbol: dict["symbolImageName"] as? String)
                }
                dict.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        // Do Not Disturb first, as in Apple's menu, then by name.
        return found.values.sorted {
            let first = $0.identifier == "com.apple.donotdisturb.mode.default"
            let second = $1.identifier == "com.apple.donotdisturb.mode.default"
            if first != second { return first }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static var isReadable: Bool { read() != nil }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The one shortcut that switches Focus. Its input is a mode's name to turn it
/// on, or "off:" and the name to turn it off -- one shortcut for every mode,
/// new ones included, because Set Focus takes the mode as text. Shipped
/// signed in Resources; tools/make-focus-shortcut.py says how it is made.
enum FocusShortcut {
    static let name = "JustHide Focus"

    enum Problem { case missing, failed }

    /// Whether Shortcuts has it: nil until the first look.
    private(set) static var isInstalled: Bool?

    /// Looks again in the background; `shortcuts list` takes a moment, so the
    /// answer is for the next time it is needed. Runs by NAME, so a user who
    /// chose "Keep Both" on a re-import still has one that works.
    static func refresh(then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, output, _) = run(["list"])
            let installed = status == 0
                ? output.split(separator: "\n").contains { $0 == Substring(name) }
                : nil
            DispatchQueue.main.async {
                if let installed = installed { isInstalled = installed }
                done?()
            }
        }
    }

    static func set(_ mode: String, on: Bool, completion: @escaping (Problem?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let input = FileManager.default.temporaryDirectory
                .appendingPathComponent("justhide-focus-\(UUID().uuidString).txt")
            try? Data(((on ? "" : "off:") + mode).utf8).write(to: input)
            defer { try? FileManager.default.removeItem(at: input) }
            let (status, _, errors) = run(["run", name, "-i", input.path])
            let problem: Problem?
            if status == 0 {
                problem = nil
            } else if errors.localizedCaseInsensitiveContains("couldn\u{2019}t find")
                        || errors.localizedCaseInsensitiveContains("couldn't find")
                        || errors.localizedCaseInsensitiveContains("not found") {
                problem = .missing
            } else {
                problem = .failed
            }
            if problem != nil {
                Log.controller.error("Focus: shortcut failed (\(status)): \(errors, privacy: .public)")
            } else {
                Log.controller.log("Focus: \(on ? "turned on" : "turned off", privacy: .public) \(mode, privacy: .public)")
            }
            DispatchQueue.main.async {
                if problem == .missing { isInstalled = false }
                completion(problem)
            }
        }
    }

    /// Opens the shipped file, and Shortcuts asks the user to add it; then
    /// watches for it to arrive, so the menu and Settings catch up by
    /// themselves.
    static func install() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "shortcut") else {
            Log.controller.error("Focus: the shortcut is missing from the app bundle")
            return
        }
        NSWorkspace.shared.open(url)
        watchForInstall(attempt: 0)
    }

    private static func watchForInstall(attempt: Int) {
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            refresh {
                if isInstalled != true { watchForInstall(attempt: attempt + 1) }
            }
        }
    }

    private static func run(_ arguments: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (-1, "", "could not start shortcuts") }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
