//
//  AccessibilityAccess.swift
//  JustHide
//
//  The one permission JustHide asks for, and why refusing it is not fatal.
//
//  Hiding itself needs nothing: the concealment assertion works unpermitted.
//  What needs Accessibility is READING which app owns which menu bar icon, for
//  which AXExtrasMenuBar is the only route left on macOS 27. Without it the
//  "add an app" list cannot say what is in the bar right now, and a newly
//  launched app's icon cannot be checked before the allowlist is refreshed.
//  Both of those degrade rather than break, which is why nothing is asked for at
//  launch. The ask is a button in the app picker, which is the list the
//  permission actually changes.
//
//  That reasoning stopped covering everything on 2026-09-21. The clock option
//  and the per-item shortcuts do NOT degrade without Accessibility -- they do
//  nothing at all -- and with no warning anywhere they simply looked broken
//  after a reinstall dropped the grant. So Settings now shows a notice, but only
//  when the permission is missing AND one of those is switched on: still no
//  standing nag for someone who only hides icons.
//
//  Worth knowing: TCC keys the grant on the code signature, and an ad-hoc build
//  gets a new one every time it is compiled, so a rebuilt JustHide loses the
//  grant silently. That is why re-requesting is a first-class path here and not
//  a one-off prompt. (A "JustHide Dev" signing identity, which build.sh looks
//  for, is what stops it happening.)
//

import Cocoa
import ApplicationServices

enum AccessibilityAccess {
    private static let didAskKey = "didAskForAccessibility"

    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Whether the user has been sent to the permission dialog at some point, so
    /// "it still is not allowed" can be phrased as the follow-up it really is.
    static var hasBeenAsked: Bool { UserDefaults.standard.bool(forKey: didAskKey) }

    /// Shows the system's permission dialog and adds JustHide to the list in
    /// System Settings. The returned value is the state right now, which is
    /// false even when the dialog is up -- granting it means the user walking
    /// over to System Settings, so there is nothing to await.
    @discardableResult
    static func request() -> Bool {
        UserDefaults.standard.set(true, forKey: didAskKey)
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// The Accessibility pane itself, for when the dialog has been dismissed
    /// once: the system shows it at most once per process, so a button that only
    /// called `request()` would look broken from then on.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Presses the clock, to replay a click that the concealment assertion
    /// swallowed. See AssertionController.clockClicked for why this is needed
    /// and what was measured.
    ///
    /// The element is found here, on each call, rather than cached: one looked
    /// up while a restriction was active does not respond to a press afterwards.
    @discardableResult
    static func pressClock() -> Bool {
        guard isGranted else { return false }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return false }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            else { return nil }
            return value
        }
        guard let extras = attribute(AXUIElementCreateApplication(agent.processIdentifier),
                                     "AXExtrasMenuBar"),
              CFGetTypeID(extras) == AXUIElementGetTypeID(),
              let groups = attribute(extras as! AXUIElement,
                                     kAXChildrenAttribute) as? [AXUIElement]
        else { return false }
        // The clock is a child of a hosting group, not a top-level item.
        for group in groups {
            let children = (attribute(group, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for child in children
            where attribute(child, "AXIdentifier") as? String == AXMenuBar.clockIdentifier {
                AXUIElementPerformAction(child, kAXPressAction as CFString)
                return true
            }
        }
        return false
    }

    /// Starts JustHide again and quits this copy.
    ///
    /// A process is told its Accessibility state when it starts, and a grant made
    /// afterwards does not always reach it -- the usual "quit and reopen the app"
    /// that every Accessibility-using app asks for.
    static func restart() {
        Log.controller.log("restarting to pick up an Accessibility change")
        Mechanism.relaunch()
    }

    /// What Settings should say about it, in one line.
    static var explanation: String {
        isGranted
            ? "Accessibility is allowed, so JustHide can tell which apps own menu bar icons."
            : "JustHide needs Accessibility to tell which apps own menu bar icons. Hiding works without it."
    }
}
