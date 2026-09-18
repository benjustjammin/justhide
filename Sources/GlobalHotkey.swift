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

final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (() -> Void)?
    private static let identifier: UInt32 = 0x4A48   // 'JH'

    /// Registers the shortcut held in Settings, replacing any previous one.
    /// Passing no shortcut simply unregisters.
    func update(onPress: @escaping () -> Void) {
        self.onPress = onPress
        unregister()

        guard let shortcut = Settings.hotkey else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == GlobalHotkey.identifier else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.onPress?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(Self.identifier), id: Self.identifier)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                         UInt32(shortcut.carbonModifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status == noErr {
            Log.controller.log("registered shortcut \(Settings.hotkeyDescription)")
        } else {
            // Most often because another app already owns the combination.
            Log.controller.error("could not register shortcut \(Settings.hotkeyDescription) (status \(status))")
            reference = nil
        }
        _ = hotKeyID
    }

    private func unregister() {
        if let reference = reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if let handler = handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
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
        guard let shortcut = hotkey else { return "None" }
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
        var text = ""
        if flags.contains(.control) { text += "\u{2303}" }
        if flags.contains(.option) { text += "\u{2325}" }
        if flags.contains(.shift) { text += "\u{21E7}" }
        if flags.contains(.command) { text += "\u{2318}" }
        return text + (KeyNames.name(for: shortcut.keyCode) ?? "?")
    }

    /// Whether to reveal when the pointer rests in the menu bar.
    static var hoverToReveal: Bool {
        get { UserDefaults.standard.bool(forKey: "hoverToReveal") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hoverToReveal")
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
