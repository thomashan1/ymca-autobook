#if os(macOS)
import SwiftUI

/// The same app on macOS 12, which has no MenuBarExtra, Window scene or
/// openWindow: AppKit draws the menu bar icon, the window and the menus, and
/// the views inside are the ones macOS 13 and later use.
@MainActor
final class LegacyMacApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = LegacyMacApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private let engine = Engine()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = mainMenu()
        if LoginItem.launchedAtLogin { MainWindow.showAtLaunch = false }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "figure.strengthtraining.traditional", accessibilityDescription: "YMCA Booker")
            ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: "YMCA Booker")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(engine: engine))

        Updates.shared.engine = engine   // starts the daily update check
        MainWindow.open = { [weak self] in self?.showWindow() }
        if MainWindow.showAtLaunch { showWindow() }
        if MacSample.active, let dir = UserDefaults.standard.string(forKey: "screenshotDir") {
            Task { await MacSample.captureAndQuit(to: dir) }
        }
    }

    /// A click on the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    /// Closing the window keeps the app (and booking) running, as on macOS 13+.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showWindow() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView:
                SettingsView(engine: engine).tint(Theme.accent)))
            w.title = "YMCA Booker"
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("main")
            if !w.setFrameUsingName("main") { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() { Updates.shared.checkForUpdates() }

    /// App, Edit and Window menus; Edit is what makes copy and paste work in
    /// the sign-in and token fields.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let updates = item("Check for Updates…", #selector(checkForUpdates))
        updates.target = self
        menu("YMCA Booker", [
            item("About YMCA Booker", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            updates,
            .separator(),
            item("Hide YMCA Booker", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit YMCA Booker", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }
}
#endif
