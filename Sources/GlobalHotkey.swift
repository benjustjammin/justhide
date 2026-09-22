//
//  GlobalHotkey.swift
//  JustHide
//
//  A system-wide keyboard shortcut to show and hide, which is the one thing
//  Hidden Bar's settings had that is genuinely missed.
//
//  Carbon's RegisterEventHotKey rather than an NSEvent global monitor: it needs
//  no permission at all, where monitoring keyboard events globally requires
//  Accessibility, and it does not see any keystroke other than the one
//  registered.
//

import Cocoa
import Carbon.HIToolbox

/// Every shortcut JustHide owns: the one that shows and hides, and one per menu
/// bar item the user has bound (see MenuBarItemShortcuts).
///
/// One Carbon event handler serves the lot, with each registration identified by
/// the `id` field of its EventHotKeyID and looked up in a table when it fires.
/// Installing a handler per shortcut would work too, but they would all be
/// called for every hotkey and each would have to filter.
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private struct Registration {
        let shortcut: Settings.Shortcut
        let action: () -> Void
        /// nil while suspended for recording, or when Carbon refused it.
        var reference: EventHotKeyRef?
    }

    private var handler: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var suspended = false
    /// Shortcuts Carbon would not take, nearly always because another app got
    /// there first. Settings shows these back rather than leaving a row looking
    /// bound to something that never fires.
    private(set) var rejected: Set<MenuBarItemTarget> = []
    /// 'JH'. The toggle keeps a fixed id; item shortcuts are numbered after it.
    private static let toggleID: UInt32 = 0x4A48
    private var nextItemID: UInt32 = GlobalHotkey.toggleID + 1

    /// Registers the show/hide shortcut held in Settings, replacing any
    /// previous one. No shortcut simply unregisters.
    func update(onPress: @escaping () -> Void) {
        unregister(id: Self.toggleID)
        guard let shortcut = Settings.hotkey else { return }
        if register(shortcut, id: Self.toggleID, action: onPress) {
            Log.controller.log("registered shortcut \(Settings.hotkeyDescription)")
        } else {
            Log.controller.error("could not register shortcut \(Settings.hotkeyDescription)")
        }
    }

    /// Replaces every item shortcut in one go. Simpler than tracking which one
    /// changed, and the whole set is rebuilt whenever Settings posts a change.
    func updateItemShortcuts(_ bindings: [(target: MenuBarItemTarget,
                                           shortcut: Settings.Shortcut,
                                           action: () -> Void)]) {
        for id in registrations.keys where id != Self.toggleID {
            unregister(id: id)
        }
        nextItemID = Self.toggleID + 1
        rejected = []
        var registered = 0
        for binding in bindings {
            if register(binding.shortcut, id: nextItemID, action: binding.action) {
                registered += 1
            } else {
                // Nearly always because another app already owns the
                // combination. Settings shows this back to the user.
                rejected.insert(binding.target)
                Log.controller.error("could not register item shortcut "
                                     + "\(Settings.description(of: binding.shortcut))")
            }
            nextItemID += 1
        }
        if registered > 0 {
            Log.controller.log("registered \(registered) item shortcut(s)")
        }
    }

    /// Takes every shortcut down for as long as one is being recorded.
    ///
    /// Without this a combination that is already bound never reaches the
    /// recorder at all: Carbon gets the keystroke first and fires whatever owns
    /// it, so pressing the shortcut you are trying to reassign silently runs it
    /// instead. Measured -- pressing ⌥⌘R over the recorder opened the panel
    /// ⌥⌘R was already bound to, and the recorder just sat there waiting.
    func suspendForRecording() {
        guard !suspended else { return }
        suspended = true
        for (id, registration) in registrations {
            if let reference = registration.reference { UnregisterEventHotKey(reference) }
            registrations[id]?.reference = nil
        }
    }

    func resumeAfterRecording() {
        guard suspended else { return }
        suspended = false
        for (id, registration) in registrations where registration.reference == nil {
            registrations[id]?.reference = carbonRegister(registration.shortcut, id: id)
        }
    }

    /// Whether a combination is already taken by one of ours, so Settings can
    /// refuse a duplicate rather than register a shortcut that never fires.
    func isTaken(_ shortcut: Settings.Shortcut, excluding target: MenuBarItemTarget?) -> Bool {
        if Settings.hotkey == shortcut { return true }
        return Settings.itemShortcuts.contains { $0.key != target && $0.value == shortcut }
    }

    private func register(_ shortcut: Settings.Shortcut, id: UInt32,
                          action: @escaping () -> Void) -> Bool {
        // While recording, remember the binding but leave the keys free: the
        // recorder needs to see them. resumeAfterRecording puts them back.
        guard !suspended else {
            registrations[id] = Registration(shortcut: shortcut, action: action, reference: nil)
            return true
        }
        guard let reference = carbonRegister(shortcut, id: id) else { return false }
        registrations[id] = Registration(shortcut: shortcut, action: action, reference: reference)
        return true
    }

    private func carbonRegister(_ shortcut: Settings.Shortcut, id: UInt32) -> EventHotKeyRef? {
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(Self.toggleID), id: id)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                         UInt32(shortcut.carbonModifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &reference)
        return status == noErr ? reference : nil
    }

    private func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.reference)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            guard let action = hotkey.registrations[pressed.id]?.action else { return noErr }
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

extension Settings {
    struct Shortcut: Equatable {
        let keyCode: Int
        /// NSEvent modifier flags, stored raw so the UI can render them.
        let modifierFlags: UInt

        var carbonModifiers: Int {
            let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            return carbon
        }
    }

    /// Everything a menu item needs to SHOW this shortcut in its right-hand
    /// column. Display only: the working registration is the Carbon one above,
    /// and a menu key equivalent fires only while the menu is open. nil for a
    /// key with no character a menu can render.
    static var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let shortcut = hotkey else { return nil }
        let modifiers = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
        if let key = menuKeys[shortcut.keyCode] { return (key, modifiers) }
        // Letters, digits and punctuation, read from the current layout so a
        // non-US keyboard shows what its user actually pressed.
        guard let name = KeyNames.name(for: shortcut.keyCode), name.count == 1 else { return nil }
        return (name.lowercased(), modifiers)
    }

    /// The keys a menu spells with a function-key code or a control character
    /// rather than the character itself.
    private static let menuKeys: [Int: String] = [
        kVK_Space: " ", kVK_Return: "\r", kVK_Tab: "\t", kVK_Escape: "\u{1B}",
        kVK_Delete: "\u{8}",
        kVK_LeftArrow: functionKey(NSLeftArrowFunctionKey),
        kVK_RightArrow: functionKey(NSRightArrowFunctionKey),
        kVK_UpArrow: functionKey(NSUpArrowFunctionKey),
        kVK_DownArrow: functionKey(NSDownArrowFunctionKey),
    ]

    private static func functionKey(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(UInt16(code)) else { return "" }
        return String(scalar)
    }

    private static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    private static let hotkeyModifiersKey = "hotkeyModifiers"

    static var hotkey: Shortcut? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: hotkeyKeyCodeKey) != nil else { return nil }
            let code = defaults.integer(forKey: hotkeyKeyCodeKey)
            let modifiers = UInt(defaults.integer(forKey: hotkeyModifiersKey))
            // A shortcut with no modifiers would swallow a plain keystroke.
            guard modifiers != 0 else { return nil }
            return Shortcut(keyCode: code, modifierFlags: modifiers)
        }
        set {
            let defaults = UserDefaults.standard
            if let shortcut = newValue {
                defaults.set(shortcut.keyCode, forKey: hotkeyKeyCodeKey)
                defaults.set(Int(shortcut.modifierFlags), forKey: hotkeyModifiersKey)
            } else {
                defaults.removeObject(forKey: hotkeyKeyCodeKey)
                defaults.removeObject(forKey: hotkeyModifiersKey)
            }
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    /// The shortcut as a user would read it, e.g. "⌥⌘H".
    static var hotkeyDescription: String {
        hotkey.map { description(of: $0) } ?? "None"
    }

    /// Whether to reveal when the pointer rests in the menu bar.
    static var hoverToReveal: Bool {
        get { UserDefaults.standard.bool(forKey: "hoverToReveal") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hoverToReveal")
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }

    /// Whether the "Good to know" notes are open. Closed by default: they are
    /// reference material, read once, and in one column they are the biggest
    /// thing in the window.
    static var showsGoodToKnow: Bool {
        get { UserDefaults.standard.bool(forKey: "showGoodToKnow") }
        set { UserDefaults.standard.set(newValue, forKey: "showGoodToKnow") }
    }

    /// Whether clicking the clock should briefly lift concealment so that
    /// Notification Centre opens, and put it back when the panel closes.
    ///
    /// Off by default: anyone who reaches Notification Centre by swiping wants
    /// nothing to do with it, and anyone who clicks the clock wants it badly.
    /// Driven by the click rather than by hovering -- hover was the first
    /// attempt and brought the icons back every time the pointer crossed the
    /// top right corner, which is constantly.
    static var clockClickThrough: Bool {
        get { UserDefaults.standard.bool(forKey: "clockClickThrough") }
        set {
            UserDefaults.standard.set(newValue, forKey: "clockClickThrough")
            NotificationCenter.default.post(name: .justHideSettingsChanged, object: nil)
        }
    }
}

/// Just enough of a key-code table to render a shortcut. Only the keys someone
/// would plausibly bind, plus letters and digits.
enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}",
        kVK_Escape: "\u{238B}", kVK_Delete: "\u{232B}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}",
        kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
    ]

    static func name(for keyCode: Int) -> String? {
        if let name = special[keyCode] { return name }
        // Letters and digits come back from the current layout, so a shortcut
        // reads correctly on a non-US keyboard.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let result = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
