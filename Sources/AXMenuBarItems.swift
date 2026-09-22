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

    /// Whether one app owns any menu bar item. Asked of that app directly rather
    /// than through currentItems(), both to keep it cheap and to avoid querying AX
    /// about our own process, which makes our items vanish from the bar.
    ///
    /// A concealed item is still reported here -- measured: an app whose icon was
    /// concealed the moment it appeared still exposes it under AXExtrasMenuBar,
    /// with a nonsense frame -- which is what makes this usable for spotting an
    /// app whose icon macOS is currently hiding.
    static func hasItems(forPID pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let extrasRef = copy(AXUIElementCreateApplication(pid), "AXExtrasMenuBar"),
              CFGetTypeID(extrasRef) == AXUIElementGetTypeID(),
              let children = copy(extrasRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return false }
        return !children.isEmpty
    }

    /// Where the clock sits, so concealment can be lifted while the pointer is
    /// over it (see AssertionController.applyHoverMonitor).
    ///
    /// Two details, both measured on 27.0 (26A428). The clock is NOT a top-level
    /// child of MenuBarAgent's AXExtrasMenuBar: the children there are AXGroups
    /// with the AXHostingView subrole, and the real item is one level down --
    /// enumerating only the top level misses it. And it identifies itself, so
    /// this needs no guessing about which item is the widest or rightmost:
    /// AXIdentifier "com.apple.menuextra.clock", AXDescription "Clock", with the
    /// localised date string as its value.
    static func clockFrame() -> CGRect? {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return nil }
        guard let extrasRef = copy(AXUIElementCreateApplication(agent.processIdentifier),
                                   "AXExtrasMenuBar"),
              CFGetTypeID(extrasRef) == AXUIElementGetTypeID(),
              let groups = copy(extrasRef as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }

        for group in groups {
            guard let children = copy(group, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children where copy(child, "AXIdentifier") as? String == clockIdentifier {
                // The hosting group is what actually occupies the bar; the item
                // inside it is the thing that names itself. Prefer the item's own
                // frame and fall back to its group's.
                return frame(of: child) ?? frame(of: group)
            }
        }
        return nil
    }

    static let clockIdentifier = "com.apple.menuextra.clock"

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
