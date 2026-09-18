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

    /// A menu item title with a symbol in front of it.
    ///
    /// NOT `NSMenuItem.image`, which macOS 27 does not draw -- measured twice
    /// now, most recently with a probe whose menu had the same symbol set as an
    /// image (nothing), inside an attributed title (drawn), and in a custom view
    /// (drawn). The cog macOS puts on a standard "Settings..." item is its own
    /// doing, not an image we set, and it is what made the other rows look
    /// unfinished next to it.
    ///
    /// Returns nil for a symbol this system does not have, leaving the caller's
    /// plain title in place rather than an empty row.
    static func menuTitle(_ text: String, symbol name: String) -> NSAttributedString? {
        guard let image = menuSymbol(name) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // y nudges the glyph down onto the text baseline, and width is the advance
        // that sets where the text starts. x does nothing here -- measured with
        // x: -10, which moved the glyph not at all -- so our column cannot be
        // slid the point or two left it would take to sit exactly under the cog
        // macOS draws on "Settings...". Close enough to read as one column.
        attachment.bounds = NSRect(x: 0, y: -3, width: 17, height: 14)
        let title = NSMutableAttributedString(attachment: attachment)
        // No colour attribute on purpose: AppKit inverts the text itself when the
        // row is highlighted, and a colour set here would survive the inversion.
        title.append(NSAttributedString(string: " " + text,
                                        attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }

    /// The symbol itself, sized for a menu row.
    static func menuSymbol(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        else { return nil }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? symbol
        configured.isTemplate = true
        return configured
    }

    /// The chevron while hiding is not working. The glyph above would claim the
    /// icons are showing because they were asked to hide and did not, which is
    /// indistinguishable from nothing being hidden in the first place -- so the
    /// item says so instead, and the right-click menu offers the way out.
    static func applyWarningGlyph(to item: NSStatusItem) {
        guard let button = item.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                               accessibilityDescription: "JustHide cannot hide menu bar icons")
        button.setAccessibilityLabel("JustHide cannot hide menu bar icons")
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
