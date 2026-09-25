//
//  TimeMachineItem.swift
//  JustHide
//
//  JustHide's own Time Machine item, so Time Machine can hide with the rest.
//
//  Apple's Time Machine icon cannot be concealed: it is a legacy menu extra
//  drawn by SystemUIServer, and an assertion leaves it on screen whatever the
//  allowlist says (measured 2026-09-23; GitHub issue #1 asked for exactly
//  this). What CAN be done, found in Pelmet's AppleMenuExtras.swift and
//  written afresh here, is switch Apple's icon off through the same private
//  calls System Settings uses -- CoreMenuExtraRemoveMenuExtra and
//  CoreMenuExtraAddMenuExtra in SystemUIPlugin.framework, which SystemUIServer
//  honours at once where a hand-written defaults key is ignored -- and draw a
//  Time Machine item of our own. Ours is JustHide's, so it goes where JustHide
//  says: by default it shows while icons are revealed and goes when they hide,
//  like any hidden app.
//
//  Apple's icon is switched off only while ours is on, and only switched back
//  on if it was on when we took it; someone who has it off stays that way.
//
//  State needs no permission: `tmutil status` for a backup in progress, and
//  the com.apple.TimeMachine preferences domain for the destinations and the
//  latest backup. `tmutil latestbackup` is avoided: it mounts the
//  destination, which can hang for a long time on an unreachable disk.
//

import Cocoa

final class TimeMachineItem: NSObject, NSMenuDelegate {
    static let shared = TimeMachineItem()

    private var item: NSStatusItem?
    private var timer: Timer?
    private var status = Status()
    /// Set by the controller: icons hidden right now.
    private var concealed = false

    struct Status: Equatable {
        var running = false
        /// 0...1 once tmutil reports one.
        var percent: Double?
        var phase: String?
    }

    /// Set while JustHide is the one that switched Apple's icon off.
    private static let restoreKey = "timeMachineRestoreApple"

    // MARK: - Visibility

    /// Called by the controller BEFORE an assertion goes up and after one comes
    /// down, so the item is gone before a secondary display's copy freezes.
    func setConcealed(_ concealed: Bool) {
        guard concealed != self.concealed else { return }
        self.concealed = concealed
        update()
    }

    /// What the option was last time, so Apple's icon is switched only when
    /// the option is: turned on, Apple's goes; turned off, it comes back.
    /// Nothing at launch, and nothing on other settings changes -- someone who
    /// switches Apple's back on in System Settings is not fought.
    private lazy var appliedOn = Settings.showsTimeMachine

    func apply() {
        let on = Settings.showsTimeMachine
        if on != appliedOn {
            on ? AppleTimeMachineIcon.retire() : AppleTimeMachineIcon.restore()
            appliedOn = on
        }
        if on {
            if timer == nil { poll() }
        } else {
            timer?.invalidate()
            timer = nil
        }
        update()
    }

    private func update() {
        let wanted = Settings.showsTimeMachine
            && (Settings.timeMachineAppearance == .always || !concealed)
        guard wanted else {
            remove()
            return
        }
        let item = self.item ?? create()
        draw(item)
    }

    private func create() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        // One autosave name for life, so it returns to the same slot every
        // time it comes back (see NowPlayingItem).
        item.autosaveName = "timemachine"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        return item
    }

    private func remove() {
        guard let item = item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func draw(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        let name = status.running
            ? "clock.arrow.trianglehead.2.counterclockwise.rotate.90"
            : "clock.arrow.trianglehead.counterclockwise.rotate.90"
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                     ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(status.running ? "Time Machine: backing up" : "Time Machine")
    }

    // MARK: - State

    /// Slowly while idle, every couple of seconds while a backup runs.
    private func poll() {
        timer?.invalidate()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Self.readStatus()
            DispatchQueue.main.async {
                guard let self = self, Settings.showsTimeMachine else { return }
                if now != self.status {
                    self.status = now
                    self.update()
                }
                self.timer = Timer.scheduledTimer(withTimeInterval: now.running ? 2 : 30,
                                                  repeats: false) { [weak self] _ in self?.poll() }
            }
        }
    }

    /// `tmutil status` prints an old-style plist: `Running = 1;`,
    /// `Percent = "0.42";` (-1 while preparing), `BackupPhase = Copying;`.
    private static func readStatus() -> Status {
        let text = run("/usr/bin/tmutil", ["status"])
        func value(_ key: String) -> String? {
            guard let range = text.range(of: #"\b"# + key + #" = "?([^";\n]*)"?;"#,
                                         options: .regularExpression) else { return nil }
            let found = String(text[range])
            return found.components(separatedBy: " = ").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
        }
        var status = Status()
        status.running = value("Running") == "1"
        if let percent = value("Percent").flatMap(Double.init), percent >= 0 { status.percent = percent }
        status.phase = value("BackupPhase")
        return status
    }

    private static var destinations: [[String: Any]] {
        CFPreferencesCopyValue("Destinations" as CFString, "com.apple.TimeMachine" as CFString,
                               kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [[String: Any]] ?? []
    }

    private static var latestBackup: Date? {
        destinations.compactMap { ($0["SnapshotDates"] as? [Date])?.max() }.max()
    }

    // MARK: - Menu

    /// Rebuilt each time it opens, so it says what is true now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let configured = !Self.destinations.isEmpty
        menu.addItem(disabled(statusLine(configured: configured)))
        menu.addItem(.separator())
        if configured {
            if status.running {
                menu.addItem(action("Stop Backing Up", #selector(stopBackup)))
            } else {
                menu.addItem(action("Back Up Now", #selector(startBackup)))
            }
            menu.addItem(action("Browse Time Machine Backups", #selector(browse)))
            menu.addItem(.separator())
        }
        menu.addItem(action(configured ? "Open Time Machine Settings\u{2026}" : "Set Up Time Machine\u{2026}",
                            #selector(openSettings)))
    }

    private func statusLine(configured: Bool) -> String {
        guard configured else { return "Time Machine Is Not Set Up" }
        if status.running {
            if let percent = status.percent {
                return "Backing Up\u{2026} \(Int((percent * 100).rounded()))%"
            }
            return status.phase == "Finishing" ? "Finishing Backup\u{2026}" : "Preparing Backup\u{2026}"
        }
        guard let latest = Self.latestBackup else { return "No Backups Yet" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Latest Backup: \(formatter.string(from: latest))"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func startBackup() {
        runDetached(["startbackup"])
    }

    @objc private func stopBackup() {
        runDetached(["stopbackup"])
    }

    /// The backup starts on its own time; the next poll, brought forward,
    /// picks the change up.
    private func runDetached(_ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = Self.run("/usr/bin/tmutil", arguments)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.poll() }
        }
    }

    @objc private func browse() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Time Machine.app"))
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Apple's icon

    /// Apple's Time Machine menu extra, switched the way System Settings
    /// switches it.
    enum AppleTimeMachineIcon {
        private typealias Get = @convention(c) (CFString, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        private typealias Add = @convention(c) (CFURL, Int32, Int32, Int32, Int32, Int32) -> Int32
        private typealias Remove = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32

        private static let identifier = "com.apple.menuextra.TimeMachine"
        private static let bundle = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/TimeMachine.menu")
        private static let plugin = dlopen("/System/Library/PrivateFrameworks/SystemUIPlugin.framework/SystemUIPlugin",
                                           RTLD_LAZY)

        private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let plugin = plugin, let found = dlsym(plugin, name) else { return nil }
            return unsafeBitCast(found, to: type)
        }

        /// The loaded extra, or nil while Apple's icon is switched off.
        private static var handle: UnsafeMutableRawPointer? {
            guard let get = symbol("CoreMenuExtraGetMenuExtra", as: Get.self) else { return nil }
            var handle: UnsafeMutableRawPointer?
            guard get(identifier as CFString, &handle) == 0 else { return nil }
            return handle
        }

        static var isShown: Bool { handle != nil }

        /// Switches Apple's icon off if it is on, and remembers doing so.
        static func retire() {
            guard let handle = handle,
                  let remove = symbol("CoreMenuExtraRemoveMenuExtra", as: Remove.self) else { return }
            let result = remove(handle, 0)
            Log.controller.log("Time Machine: switched Apple's icon off (\(result))")
            if result == 0 { UserDefaults.standard.set(true, forKey: TimeMachineItem.restoreKey) }
        }

        /// Puts Apple's icon back, but only if JustHide took it away.
        static func restore() {
            guard UserDefaults.standard.bool(forKey: TimeMachineItem.restoreKey) else { return }
            UserDefaults.standard.removeObject(forKey: TimeMachineItem.restoreKey)
            guard handle == nil, let add = symbol("CoreMenuExtraAddMenuExtra", as: Add.self) else { return }
            let result = add(bundle as CFURL, 0, 0, 0, 0, 0)
            Log.controller.log("Time Machine: switched Apple's icon back on (\(result))")
        }
    }
}
