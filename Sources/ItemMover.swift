//
//  ItemMover.swift
//  JustHide
//
//  Moving a menu bar item by synthesising the cmd-drag a user would do.
//
//  This is the whole load-bearing primitive. macOS exposes no way to set another
//  app's status item position, but it does honour a Command-held drag, and a
//  synthesised drag is indistinguishable from a real one. Requires Accessibility
//  (posting events to other processes); NOT Screen Recording.
//
//  Two behaviours make this harder than it sounds, both learned from Ice/Thaw's
//  scar tissue (dwarvesf/hidden#360, thaw-app/Thaw#923, #1035):
//
//    1. Dropping exactly on a target's own edge leaves AppKit free to pick either
//       side of it, and it picks wrong often enough to matter. So bias the drop
//       one point into the side we asked for.
//    2. A move can silently not happen. Never trust the request -- re-enumerate
//       afterwards and confirm the item actually landed on the requested side,
//       then retry.
//

import Cocoa

enum MoveDestination {
    case leftOf(AXMenuBarItem)
    case rightOf(AXMenuBarItem)

    var target: AXMenuBarItem {
        switch self {
        case let .leftOf(item), let .rightOf(item): return item
        }
    }

    /// One point INTO the requested side, so the drop is unambiguous.
    func dropPoint() -> CGPoint {
        // Re-read rather than trusting a captured frame: the target may have
        // shifted since enumeration, and a stale drop point lands nowhere useful.
        let bounds = AXMenuBar.currentFrame(of: target.element) ?? target.frame
        switch self {
        case .leftOf:  return CGPoint(x: bounds.minX - 1, y: bounds.midY)
        case .rightOf: return CGPoint(x: bounds.maxX + 1, y: bounds.midY)
        }
    }
}

enum ItemMover {
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Requests the permission prompt if it has not been granted yet.
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func move(_ item: AXMenuBarItem, to destination: MoveDestination, attempts: Int = 3) -> Bool {
        guard hasAccessibilityPermission else {
            Log.mover.error("no Accessibility permission; cannot move items")
            return false
        }
        for attempt in 1...attempts {
            guard let from = AXMenuBar.currentFrame(of: item.element) else {
                Log.mover.error("item \(item.ownerName) has no frame; cannot drag it")
                return false
            }
            let drop = destination.dropPoint()
            Log.mover.log("attempt \(attempt): dragging \(item.ownerName) from \(Int(from.midX)) to \(Int(drop.x))")
            performDrag(from: CGPoint(x: from.midX, y: from.midY), to: drop)

            // Settle, then check what actually happened rather than assuming.
            Thread.sleep(forTimeInterval: 0.35)
            guard let moved = AXMenuBar.currentFrame(of: item.element),
                  let target = AXMenuBar.currentFrame(of: destination.target.element) else {
                Log.mover.error("item or target vanished after the drag")
                return false
            }
            let landedCorrectly: Bool
            switch destination {
            case .leftOf:  landedCorrectly = moved.maxX <= target.minX + 2
            case .rightOf: landedCorrectly = moved.minX >= target.maxX - 2
            }
            if landedCorrectly {
                Log.mover.log("landed at \(Int(moved.minX)) (target \(Int(target.minX))) after \(attempt) attempt(s)")
                return true
            }
            Log.mover.log("wrong side: item at \(Int(moved.minX)), target at \(Int(target.minX)); retrying")
        }
        return false
    }

    /// How to deliver the gesture. macOS 26 moved status item hosting into
    /// Control Center, and 27 composites the whole bar in the Window Server, so
    /// "post to the icon's own app" no longer reaches the window under the
    /// cursor. Which target and shape actually works is measured, not assumed.
    struct Strategy: CustomStringConvertible {
        enum Target { case hidTap, sessionTap, pid(pid_t) }
        enum Shape { case faithfulDrag, teleport, warpDrag }
        let target: Target
        let shape: Shape
        /// Whether to hold Command as a REAL key press as well as setting the
        /// flag on the mouse events. Some consumers read the global modifier
        /// state rather than the event's own flags.
        var realCommandKey: Bool = false
        var description: String {
            let where_: String
            switch target {
            case .hidTap: where_ = "hidTap"
            case .sessionTap: where_ = "sessionTap"
            case let .pid(pid): where_ = "pid \(pid)"
            }
            let how: String
            switch shape {
            case .faithfulDrag: how = "drag"
            case .teleport: how = "teleport"
            case .warpDrag: how = "warpdrag"
            }
            return "\(where_)/\(how)\(realCommandKey ? "/cmdkey" : "")"
        }
    }

    static func hostingPID(named name: String) -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleURL?.lastPathComponent.hasPrefix(name) == true
                     || $0.localizedName == name }?
            .processIdentifier
    }

    /// Cursor is warped rather than nudged, and restored afterwards, so a move is
    /// invisible to the user beyond a flicker.
    static func performDrag(from start: CGPoint, to end: CGPoint,
                            strategy: Strategy = Strategy(target: .hidTap, shape: .faithfulDrag)) {
        let restore = CGPoint(x: NSEvent.mouseLocation.x,
                              y: (NSScreen.screens.first?.frame.height ?? 0) - NSEvent.mouseLocation.y)
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // Local events are explicitly PERMITTED, not suppressed. Suppressing them
        // was a guess, and Thaw goes out of its way to do the opposite
        // ("Prevents local events from being suppressed").
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateRemoteMouseDrag)

        // Command is held for the press and the drags, and released for the drop:
        // keeping it down through mouse-up changes how the drop is interpreted.
        func post(_ type: CGEventType, _ point: CGPoint, command: Bool) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = command ? .maskCommand : []
            switch strategy.target {
            case .hidTap: event.post(tap: .cghidEventTap)
            case .sessionTap: event.post(tap: .cgSessionEventTap)
            case let .pid(pid): event.postToPid(pid)
            }
        }

        // Command as a real key press, for consumers that read global modifier
        // state rather than the flags carried on the mouse event.
        let commandKeyCode: CGKeyCode = 55
        func postCommandKey(down: Bool) {
            guard strategy.realCommandKey,
                  let event = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: down)
            else { return }
            event.flags = down ? .maskCommand : []
            switch strategy.target {
            case .hidTap: event.post(tap: .cghidEventTap)
            case .sessionTap: event.post(tap: .cgSessionEventTap)
            case let .pid(pid): event.postToPid(pid)
            }
            Thread.sleep(forTimeInterval: 0.03)
        }

        CGWarpMouseCursorPosition(start)
        // Let the warp register before pressing: posting immediately can leave
        // the press associated with wherever the cursor used to be.
        Thread.sleep(forTimeInterval: 0.06)
        post(.mouseMoved, start, command: false)
        Thread.sleep(forTimeInterval: 0.03)
        postCommandKey(down: true)

        switch strategy.shape {
        case .teleport:
            // No travel: the press is stamped straight at the destination. This is
            // what Thaw uses for its own control items.
            post(.leftMouseDown, end, command: true)
            Thread.sleep(forTimeInterval: 0.05)
            post(.leftMouseUp, end, command: false)
        case .faithfulDrag:
            post(.leftMouseDown, start, command: true)
            let steps = 8
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
                post(.leftMouseDragged, point, command: true)
                Thread.sleep(forTimeInterval: 0.012)
            }
            post(.leftMouseUp, end, command: false)

        case .warpDrag:
            // Warps the REAL cursor at every step, not just at the start. The bar
            // appears to track the actual pointer: a cmd-click is seen (it
            // suppresses the item's action) but a drag whose coordinates only
            // live in the posted events moves nothing.
            post(.leftMouseDown, start, command: true)
            Thread.sleep(forTimeInterval: 0.15)
            let steps = 12
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y)
                CGWarpMouseCursorPosition(point)
                post(.leftMouseDragged, point, command: true)
                Thread.sleep(forTimeInterval: 0.03)
            }
            CGWarpMouseCursorPosition(end)
            Thread.sleep(forTimeInterval: 0.15)
            post(.leftMouseUp, end, command: false)
        }
        postCommandKey(down: false)
        CGWarpMouseCursorPosition(restore)
    }
}
