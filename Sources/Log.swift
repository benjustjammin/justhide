//
//  Log.swift
//  JustHide
//
//  Diagnostics that can actually be read back.
//
//  NSLog with interpolated values is redacted to "<private>" in the unified log,
//  which is very likely why dwarvesf/hidden#360 sat through 35 comments of user
//  captures without anyone being able to tell what the menu bar was doing. Every
//  line here is explicitly public.
//
//    log show --last 5m --predicate 'subsystem == "dev.justhide.app"'
//    log stream --predicate 'subsystem == "dev.justhide.app"'
//

import os

enum Log {
    private static let subsystem = "dev.justhide.app"

    static let mover = Logger(subsystem: subsystem, category: "mover")
    static let sections = Logger(subsystem: subsystem, category: "sections")
    static let controller = Logger(subsystem: subsystem, category: "controller")
}

extension Logger {
    /// Shorthand so callers do not have to remember the privacy annotation.
    func log(_ message: String) {
        self.log("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        self.error("\(message, privacy: .public)")
    }
}
