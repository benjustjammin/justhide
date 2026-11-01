//
//  ClockTap.swift
//  JustHide
//
//  Catches clicks on the clock before macOS sees them, for the clock option.
//
//  Until 1.7 a passive global monitor watched for the mouse-up and replayed the
//  click afterwards, on the reasoning that the real click had been swallowed by
//  the concealment assertion anyway. On 27.2 (26B118) it is not reliably
//  swallowed: measured with the window list at 50 ms, a click produced the
//  panel for ~0.3 s, gone for ~0.3 s, then up again -- the real click and the
//  replayed press each toggling it. Reported as issue #5.
//
//  So the click is taken out of the event stream instead, which is what Thaw
//  does too: an active tap consumes the clock's mouse-down and mouse-up while
//  icons are hidden, and the controller presses the clock exactly once. An
//  active tap needs Accessibility, which the clock option needed already.
//
//  The callback runs on the main run loop, so it may read controller state
//  directly -- but it must stay quick: macOS disables a tap that keeps the
//  event stream waiting. Hence no Accessibility lookups in here; the clock's
//  frame is a cached value the controller keeps fresh.
//

import Cocoa

final class ClockTap {
    /// Asked on mouse-down, with the location in global top-left coordinates
    /// (the same space Accessibility frames use). Returning true claims the
    /// click: its down, drags and up are all consumed.
    var shouldClaim: (CGPoint) -> Bool = { _ in false }
    /// Called on mouse-up of a claimed click.
    var claimedClickEnded: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var claiming = false

    var isRunning: Bool { tap != nil }

    /// False when macOS refused the tap, which means Accessibility is off.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<ClockTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.controller.log("clock tap refused; Accessibility is needed for the clock option")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        claiming = false
    }

    private static let replayMarker: Int64 = 0x4A48_434C  // "JHCL"

    /// A click of our own on the clock, marked so the tap lets it through.
    static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-arm. A click half-claimed when this happened has lost its
            // mouse-up; drop the claim rather than swallow the next click.
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if claiming {
                claiming = false
                claimedClickEnded()
            }
            return Unmanaged.passUnretained(event)
        case _ where event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker:
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            claiming = shouldClaim(event.location)
            return claiming ? nil : Unmanaged.passUnretained(event)
        case .leftMouseDragged:
            return claiming ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp:
            guard claiming else { return Unmanaged.passUnretained(event) }
            claiming = false
            claimedClickEnded()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
