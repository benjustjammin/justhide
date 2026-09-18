//
//  Mechanism.swift
//  JustHide
//
//  Which way JustHide is hiding icons, and what to do when that way stops
//  working.
//
//  There are two mechanisms. Concealment (AssessmentMode) is the one worth
//  having; the width trick (WidthController) is the fallback for a system where
//  concealment is missing or refuses. Concealment is private API, so "missing"
//  is a real possibility at any macOS update -- which is the whole reason the
//  fallback is still in the app.
//
//  What this type exists for: until now a failure went to the log and nowhere
//  else. The chevron kept its usual glyph, clicking it did nothing, and the
//  fallback was reachable only by knowing to relaunch with --width. So the
//  state lives here, where the menu and the Settings window can both read it,
//  and switching mechanism is a button rather than a launch argument.
//

import Cocoa

enum Mechanism {
    enum Kind: String {
        case concealment
        case width

        /// For the log and for Settings. Deliberately plain: the user did not
        /// choose between these on the way in and should not need the words
        /// "assessment mode" to understand the choice on the way out.
        var label: String {
            switch self {
            case .concealment: return "macOS hiding"
            case .width: return "the older method"
            }
        }
    }

    private static let preferredKey = "mechanism"

    /// The mechanism to use at launch. Remembered, so switching sticks.
    static var preferred: Kind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: preferredKey),
                  let kind = Kind(rawValue: raw) else { return .concealment }
            return kind
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferredKey) }
    }

    /// What is actually running, set by main.swift once the mode is settled.
    /// Not the same as `preferred`: --width overrides for one launch only.
    static var current: Kind = .concealment

    /// Why hiding is not working, in the user's words, or nil while it is.
    private(set) static var failure: String?

    /// Something the fallback wants to tell the user that is not a failure --
    /// currently only the one case where its items had to be re-registered and
    /// the user's icons need dragging past the divider once.
    private(set) static var advice: String?

    /// An error description with a full stop, so the sentence after it reads as
    /// a separate one.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    static func report(failure: String?) {
        guard failure != self.failure else { return }
        self.failure = failure
        if let failure = failure {
            Log.controller.error("hiding is not working: \(failure)")
        }
        NotificationCenter.default.post(name: .justHideMechanismChanged, object: nil)
    }

    static func report(advice: String?) {
        guard advice != self.advice else { return }
        self.advice = advice
        NotificationCenter.default.post(name: .justHideMechanismChanged, object: nil)
    }

    /// Switches mechanism and starts again. A mechanism cannot be swapped in a
    /// running process: each owns its own status items, and the width trick's
    /// items have to be created in a particular order before anything else
    /// touches the bar (see WidthController).
    static func use(_ kind: Kind) {
        guard !(kind == current && kind == preferred) else { return }
        preferred = kind
        report(failure: nil)
        Log.controller.log("switching to \(kind.label) and restarting")
        relaunch()
    }

    /// Starts JustHide again and quits this copy. The new copy is launched by a
    /// detached shell after a pause so that it appears once this one has gone:
    /// started any sooner it would find this copy still running and just hand
    /// over to it (see main.swift).
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundleURL.path)\""]
        do {
            try task.run()
        } catch {
            Log.controller.error("could not relaunch: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// The offer made when a click on the chevron did not hide anything. Shown
    /// at the moment it happens, because that is when the user is looking -- a
    /// notice in a window they have no reason to open explains nothing.
    static func offerFallback(detail: String) {
        guard current == .concealment else { return }
        let alert = NSAlert()
        alert.messageText = "JustHide could not hide your icons"
        alert.informativeText = "\(sentence(detail))\n\nThis is the part of macOS 27 that Apple does not "
            + "document, so an update can take it away. JustHide has an older method that works "
            + "without it, at the cost of a gap in the menu bar and icons that slide when they "
            + "hide."
        alert.addButton(withTitle: "Use the Older Method")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: use(.width)
        case .alertSecondButtonReturn: PreferencesWindow.shared.show()
        default: break
        }
    }
}
