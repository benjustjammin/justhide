//
//  JustHide.swift
//  JustHide
//
//  Constants and the two bits of artwork, kept in one place.
//

import Cocoa

enum JustHide {
    /// The divider's width while the bar is open: wide enough to grab and
    /// cmd-drag, narrow enough to read as a separator.
    static let dividerExpandedLength: CGFloat = 20

    /// Width a spacer is created at, purely so AppKit materialises a window for
    /// it and macOS gives it a slot. It is shrunk to 1pt immediately afterwards.
    static let spacerSeedLength: CGFloat = 24

    /// What a spacer shrinks to when it is not carrying push. Measured: at 1pt a
    /// status item still occupies ~17pt of the bar, so four of them leave a
    /// visible gap between the divider and the chevron.
    static let spacerIdleLength: CGFloat = 0


    /// Set as a TITLE, not an image. macOS flips a status item's image when it
    /// renders the mirrored menu bar on a secondary display -- measured with both
    /// an SF Symbol and a hand-drawn image: the same item showed "<" on the
    /// built-in and ">" on the external at the same instant, in the same state.
    /// Text is not flipped (the clock and battery read correctly over there), so
    /// the glyph goes in as text.
    static func applyGlyph(to item: NSStatusItem, concealed: Bool) {
        guard let button = item.button else { return }
        button.image = nil
        // ONE glyph for both states, deliberately. A mirrored second display
        // renders this item one state behind (see below), so a chevron that flips
        // direction is shown backwards over there about half the time -- which is
        // worse than no direction cue at all. Whether items are hidden is already
        // obvious from whether they are on the bar.
        button.title = Settings.glyph.symbol(concealed: concealed)
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.setAccessibilityLabel("Show or hide menu bar icons")

        // Why the glyph is fixed: a mirrored second display renders this item one
        // state behind. With the built-in correctly showing the current glyph,
        // the external showed the previous one. Proved it is staleness and not a
        // horizontal flip by using "F" and "L" as the two glyphs -- the external
        // showed "L" while the built-in showed "F", and "L" is not a mirrored
        // "F". "<" and ">" being mirror images of each other is what disguised
        // this as a reversed arrow.
        //
        // Neither changing the content nor nudging the width invalidates the
        // mirror's copy. Toggling isVisible does force a redraw, but it also lost
        // the item from the bar entirely, so it is not worth the risk for a
        // cosmetic cue.
    }

    /// Drawn rather than an SF Symbol. On a mirrored second display macOS renders
    /// the symbol FLIPPED -- measured: the same item showing "<" on the built-in
    /// and ">" on the external at the same instant, in the same state -- which
    /// reads as a backwards chevron. A hand-drawn image carries no direction or
    /// mirroring metadata for anything to reinterpret.
    static func chevronImage(collapsed: Bool) -> NSImage {
        let size = NSSize(width: 9, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let inset: CGFloat = 1.5
            let midY = rect.midY
            if collapsed {
                // "<" : points left, meaning "reveal what is hidden over there".
                path.move(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                path.line(to: NSPoint(x: rect.minX + inset, y: midY))
                path.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
            } else {
                // ">" : points right, meaning "put them away again".
                path.move(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
                path.line(to: NSPoint(x: rect.maxX - inset, y: midY))
                path.line(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = collapsed
            ? "Show hidden menu bar icons" : "Hide menu bar icons"
        return image
    }

    /// Drawn rather than an SF Symbol: a plain vertical hairline is exactly what
    /// a divider should look like, and no symbol is quite that.
    static func dividerImage() -> NSImage {
        let size = NSSize(width: 2, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
