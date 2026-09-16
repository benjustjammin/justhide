//
//  LaunchAtLogin.swift
//  JustHide
//
//  Registers the app itself as a login item through SMAppService, which is the
//  supported route since macOS 13 and needs no helper bundle and no permission.
//  The user can also revoke it in System Settings > General > Login Items, so
//  isEnabled reads the live status rather than a preference of our own.
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True if the user has been asked to approve it in System Settings and has
    /// not yet done so, which is worth saying out loud in the UI.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.controller.log("launch at login \(enabled ? "enabled" : "disabled")")
            return true
        } catch {
            Log.controller.error("could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            return false
        }
    }
}
