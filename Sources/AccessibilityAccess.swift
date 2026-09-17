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
//  Both of those degrade rather than break, which is why this asks once and then
//  leaves a button in Settings instead of nagging at every launch.
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

    /// Asked on first launch, so the app appears in the Accessibility list with
    /// a switch to flick rather than the user having to know to add it. Once.
    static func requestOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: didAskKey) else { return }
        guard !isGranted else {
            UserDefaults.standard.set(true, forKey: didAskKey)
            return
        }
        Log.controller.log("asking for Accessibility for the first time")
        request()
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

    /// Starts JustHide again and quits this copy.
    ///
    /// A process is told its Accessibility state when it starts, and a grant made
    /// afterwards does not always reach it -- the usual "quit and reopen the app"
    /// that every Accessibility-using app asks for. The new copy is launched by a
    /// detached shell after a pause, so that it appears once this one has gone:
    /// started any sooner it would see this copy still running and simply hand
    /// over to it (see main.swift).
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundleURL.path)\""]
        do {
            try task.run()
        } catch {
            Log.controller.error("could not relaunch: \(error.localizedDescription)")
            return
        }
        Log.controller.log("restarting to pick up an Accessibility change")
        NSApp.terminate(nil)
    }

    /// What Settings should say about it, in one line.
    static var explanation: String {
        isGranted
            ? "Accessibility is allowed, so JustHide can tell which apps own menu bar icons."
            : "JustHide needs Accessibility to tell which apps own menu bar icons. Hiding works without it."
    }
}
