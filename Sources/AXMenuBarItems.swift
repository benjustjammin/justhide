//
//  AXMenuBarItems.swift
//  JustHide
//
//  Enumerating menu bar items on macOS 27, where the window list cannot.
//
//  Measured on 27.0 (26A428): CGWindowListCopyWindowInfo reports NO per-app
//  status item windows at all. The only menu-bar windows are owned by "Window
//  Server" at layer 24, one per display (0..1800 and 1800..3720 here). macOS 27
//  composites the whole bar in the Window Server, so the approach every
//  window-list-based menu bar utility used is simply gone.
//
//  What remains is the Accessibility API. Each app that owns a status item
//  exposes it under the app element's AXExtrasMenuBar, with usable AXPosition and
//  AXSize. That needs Accessibility permission to READ, not just to act -- so on
//  27 there is no permission-free way to even see the icons.
//

import Cocoa
import ApplicationServices

struct AXMenuBarItem {
    let element: AXUIElement
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
    let frame: CGRect

    /// Stable across launches: window IDs are recycled, titles often absent.
    var persistentKey: String {
        let bundle = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier ?? ownerName
        return title.map { "\(bundle)#\($0)" } ?? bundle
    }
}

enum AXMenuBar {
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Re-read an element's frame. Used to verify a move actually happened
    /// rather than trusting the request.
    static func currentFrame(of element: AXUIElement) -> CGRect? {
        frame(of: element)
    }

    /// Our own items, for placing spacers.
    static func items(forPID pid: pid_t) -> [AXMenuBarItem] {
        currentItems().filter { $0.ownerPID == pid }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = copy(element, kAXPositionAttribute),
              let sizeRef = copy(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Every status item every running app exposes, ordered left to right.
    static func currentItems() -> [AXMenuBarItem] {
        var found: [AXMenuBarItem] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            // AXExtrasMenuBar is the status-item area; AXMenuBar is the app's own
            // menus, which are not what we want.
            guard let extrasRef = copy(appElement, "AXExtrasMenuBar"),
                  CFGetTypeID(extrasRef) == AXUIElementGetTypeID() else { continue }
            let extras = extrasRef as! AXUIElement
            guard let children = copy(extras, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            let name = app.localizedName ?? "pid \(pid)"
            for child in children {
                guard let frame = frame(of: child) else { continue }
                let title = copy(child, kAXTitleAttribute) as? String
                found.append(AXMenuBarItem(element: child, ownerPID: pid, ownerName: name,
                                           title: (title?.isEmpty == false) ? title : nil,
                                           frame: frame))
            }
        }
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }
}
